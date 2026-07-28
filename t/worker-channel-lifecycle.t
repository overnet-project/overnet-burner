use strictures 2;

use AnyEvent;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;
use Time::HiRes qw(time);

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

  is $steps->[0], 'create_channel', 'the channel is created before anything else';
  is [@{$steps}[1 .. 3]], ['add_user', 'add_user', 'add_user'], 'members are admitted next';
  is [@{$steps}[4 .. 6]], ['chat', 'chat', 'chat'], 'admitted members speak before any ban';
  is $steps->[7],  'ban',           'a ban follows the chat traffic';
  is $steps->[-1], 'edit_settings', 'settings change last in the cycle';

  $worker->{cycle} = 1;
  my $later = [map { $_->{step} } @{$worker->_steps_for_cycle}];
  is scalar(grep { $_ eq 'create_channel' } @{$later}), 0,
    'the channel is created once, not on every cycle';
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

  is $tag{h}, 'burner-lifecycle-test', 'the event is bound to the group';
  is $tag{overnet_actor}, $worker->{authority_key}->pubkey_hex, 'it names the authority actor';
  is $tag{overnet_authority}, $worker->{grant_id}, 'it references the delegation grant';
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

  is scalar(keys %seen), 36, 'every admission is a fresh identity';
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
  is $stream->[0]{status},         'success',           'an accepted step is a success';
  is $stream->[0]{operation},      'channel_lifecycle', 'the operation names the role';
  is $stream->[0]{lifecycle_step}, 'create_channel',    'the metric records which step ran';
  is $stream->[0]{control_kind},   39000,               'the metric records the kind published';
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
  is $stream->[0]{status}, 'error', 'a rejected step is an error';
  is $stream->[0]{error}, 'unauthorized: not a channel operator', 'the relay reason is preserved';
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

done_testing;

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
    endpoints        => {relays => ['ws://127.0.0.1:1']},
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
