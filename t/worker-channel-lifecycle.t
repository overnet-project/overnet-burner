use strictures 2;

use AnyEvent;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Net::Nostr::Client;
use Net::Nostr::Filter;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../relay-perl/lib";
use lib "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::ChannelLifecycle;

# ---------------------------------------------------------------------------
# In-process coverage with a fake relay client. The fake acknowledges each
# publish synchronously (accepting, or rejecting by event kind), so every
# lifecycle branch is exercised without a live relay.
# ---------------------------------------------------------------------------

subtest 'role and identities' => sub {
  is(Overnet::Burner::Worker::ChannelLifecycle->expected_role, 'channel_lifecycle', 'declares its role');

  my $authority = Overnet::Burner::Worker::ChannelLifecycle->derive_key(12345, 'cl-001/authority');
  my $again     = Overnet::Burner::Worker::ChannelLifecycle->derive_key(12345, 'cl-001/authority');
  my $session   = Overnet::Burner::Worker::ChannelLifecycle->derive_key(12345, 'cl-001/session');

  is $authority->pubkey_hex, $again->pubkey_hex, 'the authority identity is reproducible';
  isnt $authority->pubkey_hex, $session->pubkey_hex,
    'the authority actor and delegated session are distinct keys, as the relay requires';
};

subtest 'the lifecycle script is ordered: create, admit, speak, ban, then settings' => sub {
  my $worker = _primed_worker(_input(_layout('cl-order'), 'cl-order'));
  my $steps  = [map { $_->{step} } @{$worker->_steps_for_cycle}];

  is $steps->[0],         'create_channel',                     'the channel is created before anything else';
  is [@{$steps}[1 .. 3]], ['add_user', 'add_user', 'add_user'], 'members are admitted next';
  is [@{$steps}[4 .. 6]], ['chat', 'chat', 'chat'],             'admitted members speak before any ban';
  is $steps->[7],         'ban',                                'a ban follows the chat traffic';
  is $steps->[-1],        'edit_settings',                      'settings change last in the cycle';

  $worker->{cycle} = 1;
  my $later = [map { $_->{step} } @{$worker->_steps_for_cycle}];
  is scalar(grep { $_ eq 'create_channel' } @{$later}), 0, 'the channel is created once, not on every cycle';
};

subtest 'each lifecycle step publishes the NIP-29 kind the relay gates for it' => sub {
  my $worker = _primed_worker(_input(_layout('cl-kinds'), 'cl-kinds'));

  is $worker->_event_for_step('create_channel')->kind, 39000, 'channel creation is group metadata';
  is $worker->_event_for_step('add_user')->kind,       9000,  'admitting a member is put-user';
  is $worker->_event_for_step('chat')->kind,           9,     'chat is an ordinary group message';
  is $worker->_event_for_step('ban')->kind,            9001,  'a ban is a pubkey removal';
  is $worker->_event_for_step('edit_settings')->kind,  9002,  'a settings change is edit-metadata';

  like dies { $worker->_event_for_step('nonsense') }, qr/unknown\ lifecycle\ step/x,
    'an unknown step is a programming error, not a silent no-op';
};

subtest 'control events carry the delegation tags the relay authorizes against' => sub {
  my $worker = _primed_worker(_input(_layout('cl-tags'), 'cl-tags'));
  my %tag    = map { $_->[0] => $_->[1] } @{$worker->_event_for_step('add_user')->to_hash->{tags}};

  is $tag{h},                 'burner-lifecycle-test',              'the event is bound to the group';
  is $tag{overnet_actor},     $worker->{authority_key}->pubkey_hex, 'it names the authority actor';
  is $tag{overnet_authority}, $worker->{grant_id},                  'it references the delegation grant';
  ok exists $tag{overnet_sequence}, 'it carries a sequence';

  my %create = map { $_->[0] => $_->[1] } @{$worker->_event_for_step('create_channel')->to_hash->{tags}};
  is $create{d}, 'burner-lifecycle-test', 'group metadata binds the group by its d tag';
};

# Regression: the member ordinal must advance monotonically. Deriving it from
# the current member count recycles identities once bans start shrinking the
# list, so "add N distinct members" silently became "re-add the same pubkey",
# and the relay's derived membership no longer matched the load the worker
# claimed to have generated.
subtest 'admitted members are always distinct identities, even after bans' => sub {
  my $worker = _primed_worker(_input(_layout('cl-distinct'), 'cl-distinct'));

  my %seen;
  for my $cycle (1 .. 12) {
    for (1 .. 3) {
      my %tag = map { $_->[0] => [@{$_}[1 .. $#{$_}]] } @{$worker->_event_for_step('add_user')->to_hash->{tags}};
      $seen{$tag{p}[0]}++;
    }
    $worker->_event_for_step('ban');
  }

  is scalar(keys %seen),                  36, 'every admission is a fresh identity';
  is [grep { $seen{$_} > 1 } keys %seen], [], 'no identity is ever re-admitted';
};

subtest 'a ban with no admitted member left is skipped, not published' => sub {
  my $worker = _primed_worker(_input(_layout('cl-noban'), 'cl-noban'));
  is $worker->_event_for_step('ban'), undef, 'an empty channel has nobody to ban';
};

subtest 'an accepted lifecycle step is a success metric naming the step' => sub {
  my $run_dir = _layout('cl-ok');
  my $worker  = _primed_worker(_input($run_dir, 'cl-ok'));
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 1);
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-ok');
  is $stream->[0]{status},         'success',               'an accepted step is a success';
  is $stream->[0]{operation},      'channel_lifecycle',     'the operation names the role';
  is $stream->[0]{lifecycle_step}, 'create_channel',        'the metric records which step ran';
  is $stream->[0]{control_kind},   39000,                   'the metric records the kind published';
  is $stream->[0]{group},          'burner-lifecycle-test', 'the metric records the group';
  ok $stream->[0]{event_id}, 'the metric records the event id';
};

subtest 'a rejected lifecycle step is an error metric carrying the relay reason' => sub {
  my $run_dir = _layout('cl-reject');
  my $worker  = _primed_worker(_input($run_dir, 'cl-reject'));
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(
    connected      => 1,
    reject_kinds   => {39000 => 1},
    reject_message => 'unauthorized: not a channel operator',
  );
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-reject');
  is $stream->[0]{status}, 'error',                                'a rejected step is an error';
  is $stream->[0]{error},  'unauthorized: not a channel operator', 'the relay reason is preserved';
};

subtest 'an idle phase paces nothing but completes' => sub {
  my $worker = _primed_worker(_input(_layout('cl-idle'), 'cl-idle'));
  my $stop   = 0;
  my $done   = $worker->_run_phase(
    client  => scalar _fake_client_and_pending(connected => 1),
    pending => {},
    phase   => {name => 'idle', start_seconds => 0, duration_seconds => 0, publish_rate_per_second => 0},
    started => time,
    stop    => \$stop,
  );
  is $done, 1, 'the idle phase returns cleanly';
};

subtest 'a failed reconnect records the loss and stops the step' => sub {
  my $run_dir = _layout('cl-lost');
  my $worker  = _primed_worker(_input($run_dir, 'cl-lost'));
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 0, connect_ok => 0);
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-lost');
  is $stream->[0]{status},         'error',     'the lost connection is an error metric';
  is $stream->[0]{lifecycle_step}, 'reconnect', 'the metric marks it as a reconnect failure';
  like $stream->[0]{error}, qr/reconnect\ failed/x, 'it explains the reconnect failed';
};

subtest 'a refused delegation grant fails the authority bootstrap' => sub {
  my $worker = _primed_worker(_input(_layout('cl-nogrant'), 'cl-nogrant'));

  my ($client, $pending) = _fake_client_and_pending(
    connected      => 1,
    reject_kinds   => {14142 => 1},
    reject_message => 'unauthorized: grant is bound to a different relay',
  );
  my ($ok, $reason) = $worker->_establish_authority($client, $pending);

  is $ok, 0, 'a refused grant is not an established authority';
  like $reason, qr/delegation\ grant\ rejected/x,    'the failure names the refused grant';
  like $reason, qr/bound\ to\ a\ different\ relay/x, 'it surfaces the relay reason';
};

subtest 'a refused operator bootstrap fails the authority bootstrap' => sub {
  my $worker = _primed_worker(_input(_layout('cl-noop'), 'cl-noop'));

  my ($client, $pending) = _fake_client_and_pending(
    connected      => 1,
    reject_kinds   => {9000 => 1},
    reject_message => 'unauthorized: group already claimed',
  );
  my ($ok, $reason) = $worker->_establish_authority($client, $pending);

  is $ok, 0, 'a refused operator self-grant is not an established authority';
  like $reason, qr/operator\ bootstrap\ rejected/x, 'the failure names the refused bootstrap';
};

subtest 'an empty channel is spoken for by the session key' => sub {
  my $worker = _primed_worker(_input(_layout('cl-chat0'), 'cl-chat0'));
  my $event  = $worker->_event_for_step('chat');

  is $event->to_hash->{pubkey}, $worker->{session_key}->pubkey_hex,
    'with no admitted member yet, the session key speaks';
};

subtest 'a step with nothing to do publishes nothing at all' => sub {
  my $run_dir = _layout('cl-skip');
  my $worker  = _primed_worker(_input($run_dir, 'cl-skip'));
  $worker->open_metric_stream;

  # A ban is the one step that can have nothing to do: an empty channel has
  # nobody to remove. It must not publish, and must not emit a metric.
  $worker->{queue} = [{step => 'ban'}];
  my ($client, $pending) = _fake_client_and_pending(connected => 1);
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  is _stream($run_dir, 'cl-skip'), [], 'a skipped step is not a metric event';
};

subtest 'a reconnect that re-establishes authority resumes the lifecycle' => sub {
  my $run_dir = _layout('cl-recon');
  my $worker  = _primed_worker(_input($run_dir, 'cl-recon'));
  $worker->open_metric_stream;

  # Disconnected, but the relay is reachable again: the worker must re-publish
  # its grant and operator role (a restarted relay's fresh store no longer
  # holds them) and then carry on with the step it was about to run.
  my ($client, $pending) = _fake_client_and_pending(connected => 0, connect_ok => 1);
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-recon');
  is scalar @{$stream},    1,         'the step ran after the reconnect';
  is $stream->[0]{status}, 'success', 'and it succeeded against the reconnected relay';
};

subtest 'a publish that cannot be sent is a lost-connection error' => sub {
  my $run_dir = _layout('cl-send');
  my $worker  = _primed_worker(_input($run_dir, 'cl-send'));
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 1, publish_dies => 1);
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-send');
  is $stream->[0]{status}, 'error',                 'a failed send is an error metric';
  is $stream->[0]{error},  'relay connection lost', 'it names the lost connection';
};

subtest 'a relay that never acknowledges times the operation out' => sub {
  my $run_dir = _layout('cl-timeout');
  my $worker  = _primed_worker(_input($run_dir, 'cl-timeout'));
  $worker->open_metric_stream;

  # The relay takes the event but never sends OK: the worker must not wait
  # forever, and the timeout must be reported as the operation's outcome.
  my ($client, $pending) = _fake_client_and_pending(connected => 1, no_ack => 1);
  $worker->_run_step(client => $client, pending => $pending, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-timeout');
  is $stream->[0]{status}, 'error',                     'an unacknowledged publish is an error';
  is $stream->[0]{error},  'lifecycle event timed out', 'the timeout is the reported reason';
};

subtest 'a stop raised mid-phase ends the phase immediately' => sub {
  my $run_dir = _layout('cl-stop');
  my $worker  = _primed_worker(_input($run_dir, 'cl-stop'));
  $worker->open_metric_stream;

  my $stop = 0;
  my ($client, $pending) = _fake_client_and_pending(connected => 1);
  $client->{on_publish} = sub { $stop = 1 };

  $worker->_run_phase(
    client  => $client,
    pending => $pending,
    phase   => {name => 'main', start_seconds => 0, duration_seconds => 30, publish_rate_per_second => 50},
    started => time,
    stop    => \$stop,
  );
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cl-stop');
  ok scalar @{$stream} <= 2, 'the phase stopped as soon as the stop was raised'
    or diag(scalar @{$stream});
};

# ---------------------------------------------------------------------------
# Integration against the real authority relay: the lifecycle script has to be
# accepted by the relay's actual delegation-authorization path, and the derived
# membership has to match what the script did.
# ---------------------------------------------------------------------------

SKIP: {
  eval { require Overnet::Authority::HostedChannel::Relay; 1 }
    or skip 'Overnet::Authority::HostedChannel::Relay not available', 1;

  subtest 'a real authority relay accepts the whole lifecycle script' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('channel-lifecycle-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 3, publish_rate_per_second => 10);

    Overnet::Burner::Worker::ChannelLifecycle->new(input => $input)->run;

    ok -e File::Spec->catfile($run_dir, 'workers', 'channel-lifecycle-001', 'ready'),
      'the worker declared readiness only after establishing authority';

    my $events = _stream($run_dir, 'channel-lifecycle-001');
    ok @{$events} >= 5, 'a plausible number of lifecycle operations ran' or diag(scalar @{$events});

    my @failures = grep { $_->{status} ne 'success' } @{$events};
    is \@failures, [], 'the authority relay accepted every lifecycle operation'
      or diag(JSON->new->canonical(1)->encode(\@failures));

    my %kind_for = (
      create_channel => 39000,
      add_user       => 9000,
      chat           => 9,
      ban            => 9001,
      edit_settings  => 9002,
    );
    my @bad_shape = grep {
           $_->{operation} ne 'channel_lifecycle'
        || $_->{role} ne 'channel_lifecycle'
        || ($kind_for{$_->{lifecycle_step}} // -1) !=
        ($_->{control_kind} // 0)
    } @{$events};
    is \@bad_shape, [], 'every metric names its step and the kind that step publishes';

    my %ran = map { $_->{lifecycle_step} => 1 } @{$events};
    ok $ran{create_channel}, 'the channel was created against the real relay';
    ok $ran{add_user},       'members were admitted against the real relay';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };

  subtest 'a grant bound to a different relay fails the worker before readiness' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('channel-lifecycle-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 2, publish_rate_per_second => 5);
    $input->{workload}{control} = {relay_url => 'ws://127.0.0.1:1'};

    my $error;
    eval { Overnet::Burner::Worker::ChannelLifecycle->new(input => $input)->run; 1 } or $error = $@;
    like $error, qr/could\ not\ establish\ its\ delegated\ authority/x, 'the bootstrap failure is fatal';
    ok !-e File::Spec->catfile($run_dir, 'workers', 'channel-lifecycle-001', 'ready'),
      'a worker that never established authority is not marked ready';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };

  subtest 'a TERM signal stops the lifecycle worker between phases' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('channel-lifecycle-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 10, publish_rate_per_second => 10);
    $input->{phases} = [
      {name => 'p1', start_seconds => 0, duration_seconds => 5, publish_rate_per_second => 10},
      {name => 'p2', start_seconds => 5, duration_seconds => 5, publish_rate_per_second => 10},
    ];

    my $parent = $$;
    my $killer = fork // die "fork: $!";
    if (!$killer) { sleep 0.8; kill 'TERM', $parent; exit 0 }

    Overnet::Burner::Worker::ChannelLifecycle->new(input => $input)->run;
    waitpid $killer, 0;

    my @phase2 = grep { ($_->{phase} // q{}) eq 'p2' } @{_stream($run_dir, 'channel-lifecycle-001')};
    is \@phase2, [], 'the worker stopped before the second phase';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };

  subtest 'the relay derives exactly the membership the lifecycle produced' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('channel-lifecycle-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 4, publish_rate_per_second => 12);
    $input->{workload}{control}   = {group => 'lifecycle-group'};
    $input->{workload}{lifecycle} = {
      channel_name       => '#lifecycle',
      members_per_cycle  => 2,
      messages_per_cycle => 1,
      bans_per_cycle     => 1,
    };

    Overnet::Burner::Worker::ChannelLifecycle->new(input => $input)->run;

    my $events  = _stream($run_dir, 'channel-lifecycle-001');
    my %step_ct = ();
    for my $event (@{$events}) {
      next if $event->{status} ne 'success';
      $step_ct{$event->{lifecycle_step}}++;
    }

    my $session =
      Overnet::Burner::Worker::ChannelLifecycle->derive_key(12345, 'channel-lifecycle-001/session')->pubkey_hex;

    # The relay stored one put-user per admission plus the operator bootstrap,
    # and one removal per ban: the control plane the relay authorized matches
    # the lifecycle the worker reported running.
    is scalar @{_stored_events($port, authors => [$session], kinds => [9000])},
      ($step_ct{add_user} // 0) + 1,
      'the relay stored the operator bootstrap plus one put-user per admission';
    is scalar @{_stored_events($port, authors => [$session], kinds => [9001])}, ($step_ct{ban} // 0),
      'the relay stored exactly one removal per ban';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };
}

done_testing;

sub _worker_input {
  my ($run_dir, $port, %workload) = @_;
  return {
    input_version    => 1,
    run_id           => 'lifecycle-test-001',
    run_dir          => $run_dir,
    worker_id        => 'channel-lifecycle-001',
    role             => 'channel_lifecycle',
    seed             => 12345,
    duration_seconds => delete $workload{duration_seconds},
    metric_stream    => 'metrics/channel-lifecycle-001.jsonl',
    ready_file       => 'workers/channel-lifecycle-001/ready',
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {%workload},
  };
}

sub _spawn_authority_relay {
  my ($port) = @_;
  my $pid = fork // die "fork: $!";
  if (!$pid) {
    my $code = <<'PERL';
my $port = $ARGV[0];
Overnet::Authority::HostedChannel::Relay::build_authoritative_relay(
  relay_url => "ws://127.0.0.1:$port", grant_kind => 14142,
)->run('127.0.0.1', $port);
PERL
    exec $^X,
      "-I$FindBin::Bin/../lib",
      "-I$FindBin::Bin/../../relay-perl/lib",
      "-I$FindBin::Bin/../../core-perl/lib", '-MOvernet::Authority::HostedChannel::Relay', '-e', $code, $port
      or die "exec: $!";
  }

  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) {
      close $probe or die "close: $!";
      return $pid;
    }
    if (waitpid($pid, WNOHANG) != 0) {
      die "authority relay child exited before listening\n";
    }
    sleep 0.1;
  }
  die "authority relay never listened on port $port\n";
}

sub _stored_events {
  my ($port, %filter) = @_;

  my $client = Net::Nostr::Client->new;
  my @stored;
  my $cv = AnyEvent->condvar;
  $client->on(event => sub { my (undef, $event) = @_; push @stored, $event });
  $client->on(eose  => sub { $cv->send });
  $client->connect("ws://127.0.0.1:$port");
  $client->subscribe('verify', Net::Nostr::Filter->new(%filter));
  my $timeout = AnyEvent->timer(after => 10, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;

  return \@stored;
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _primed_worker {
  my ($input) = @_;
  my $worker = Overnet::Burner::Worker::ChannelLifecycle->new(input => $input);
  $worker->{authority_key}      = $worker->derive_key($input->{seed}, "$input->{worker_id}/authority");
  $worker->{session_key}        = $worker->derive_key($input->{seed}, "$input->{worker_id}/session");
  $worker->{relay_url}          = 'ws://127.0.0.1:1';
  $worker->{grant_kind}         = 14142;
  $worker->{group}              = 'burner-lifecycle-test';
  $worker->{scope}              = 'overnet-burner://lifecycle-test';
  $worker->{session_id}         = "$input->{worker_id}-session";
  $worker->{sequence}           = 0;
  $worker->{grant_id}           = '0' x 64;
  $worker->{members}            = [];
  $worker->{cycle}              = 0;
  $worker->{channel_name}       = '#burner';
  $worker->{members_per_cycle}  = 3;
  $worker->{messages_per_cycle} = 3;
  $worker->{bans_per_cycle}     = 1;
  return $worker;
}

sub _fake_client_and_pending {
  my (%opt) = @_;
  my %pending;
  my $client = _FakeLifecycleClient->new(%opt);
  $client->on(
    ok => sub {
      my ($event_id, $accepted, $message) = @_;
      my $waiter = delete $pending{$event_id};
      if ($waiter) {
        $waiter->send([$accepted ? 1 : 0, $message]);
      }
    }
  );
  return wantarray ? ($client, \%pending) : $client;
}

sub _stream {
  my ($run_dir, $worker_id) = @_;
  return Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', "$worker_id.jsonl"));
}

sub _input {
  my ($run_dir, $worker_id) = @_;
  return {
    input_version    => 1,
    run_id           => 'lifecycle-test-001',
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'channel_lifecycle',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays                  => ['ws://127.0.0.1:1']},
    workload         => {publish_rate_per_second => 1},
  };
}

sub _layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

package _FakeLifecycleClient;

sub new {
  my ($class, %opt) = @_;
  return bless {%opt}, $class;
}

sub is_connected { return $_[0]->{connected} }

sub connect {
  my ($self) = @_;
  die "connection refused\n" if !$self->{connect_ok};
  $self->{connected} = 1;
  return 1;
}

sub on {
  my ($self, $event, $callback) = @_;
  $self->{handlers}{$event} = $callback;
  return 1;
}

sub publish {
  my ($self, $event) = @_;
  die "publish failed\n" if $self->{publish_dies};
  if ($self->{on_publish}) {
    $self->{on_publish}->($event);
  }
  return 1 if $self->{no_ack};

  my $ok = $self->{handlers}{ok};
  return 1 if !$ok;

  my $accepted = ($self->{reject_kinds} && $self->{reject_kinds}{$event->kind}) ? 0 : 1;
  my $message  = $accepted ? q{} : ($self->{reject_message} // 'unauthorized: rejected by policy');
  $ok->($event->id, $accepted, $message);
  return 1;
}

sub disconnect { $_[0]->{connected} = 0; return 1 }

1;
