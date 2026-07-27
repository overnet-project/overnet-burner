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
use Overnet::Burner::Worker::ControlPublisher;

# ---------------------------------------------------------------------------
# In-process branch coverage with a fake relay client. The fake acknowledges
# each publish synchronously (accepting, or rejecting by event kind), so the
# authorization-flow branches are covered without a live relay.
# ---------------------------------------------------------------------------

subtest 'authority and session identities derive deterministically and differ' => sub {
  my $authority = Overnet::Burner::Worker::ControlPublisher->derive_key(12345, 'control-publisher-001/authority');
  my $again     = Overnet::Burner::Worker::ControlPublisher->derive_key(12345, 'control-publisher-001/authority');
  my $session   = Overnet::Burner::Worker::ControlPublisher->derive_key(12345, 'control-publisher-001/session');

  is $authority->pubkey_hex, $again->pubkey_hex, 'the authority identity is reproducible';
  isnt $authority->pubkey_hex, $session->pubkey_hex,
    'the authority actor and delegated session are distinct keys, as the relay requires';
  is(Overnet::Burner::Worker::ControlPublisher->expected_role, 'control_publisher', 'declares its role');
};

subtest 'an idle phase paces nothing but completes' => sub {
  my $worker = _primed_worker(_input(_layout('cp-idle'), 'cp-idle'), 1);
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

subtest 'an accepted control operation is a success metric' => sub {
  my $run_dir = _layout('cp-ok');
  my $worker  = _primed_worker(_input($run_dir, 'cp-ok'), 1);
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 1);
  $worker->_publish_control_once(client => $client, pending => $pending, sequence => 1, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cp-ok');
  is $stream->[0]{status},       'success',         'an accepted put-user is a success';
  is $stream->[0]{operation},    'control_publish', 'the operation is control_publish';
  is $stream->[0]{control_kind}, 9000,              'the metric records the control kind';
  ok $stream->[0]{event_id}, 'the metric records the control event id';
};

subtest 'a rejected control operation is an error metric carrying the reason' => sub {
  my $run_dir = _layout('cp-reject');
  my $worker  = _primed_worker(_input($run_dir, 'cp-reject'), 1);
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(
    connected      => 1,
    reject_kinds   => {9000 => 1},
    reject_message => 'unauthorized: actor is not a channel operator',
  );
  $worker->_publish_control_once(client => $client, pending => $pending, sequence => 1, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cp-reject');
  is $stream->[0]{status}, 'error', 'a refused control event is an error, not a worker failure';
  is $stream->[0]{error}, 'unauthorized: actor is not a channel operator', 'the relay reason is preserved';
};

subtest 'a lost connection on send is a structured error' => sub {
  my $run_dir = _layout('cp-lost');
  my $worker  = _primed_worker(_input($run_dir, 'cp-lost'), 1);
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 1, publish_dies => 1);
  $worker->_publish_control_once(client => $client, pending => $pending, sequence => 1, phase => 'main');
  $worker->close_metric_stream;

  is _stream($run_dir, 'cp-lost')->[0]{error}, 'relay connection lost', 'a failed send names the lost connection';
};

subtest 'an unacknowledged control event times out' => sub {
  my $run_dir = _layout('cp-timeout');
  my $worker  = _primed_worker(_input($run_dir, 'cp-timeout'), 1);
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 1, no_ack => 1);
  $worker->_publish_control_once(client => $client, pending => $pending, sequence => 1, phase => 'main');
  $worker->close_metric_stream;

  is _stream($run_dir, 'cp-timeout')->[0]{error}, 'control event timed out', 'the timeout timer supplies the reason';
};

subtest 'a disconnected client reconnects and re-establishes authority before publishing' => sub {
  my $run_dir = _layout('cp-recon');
  my $worker  = _primed_worker(_input($run_dir, 'cp-recon'), 1);
  $worker->open_metric_stream;

  # Not connected, but reconnect and the authority bootstrap both succeed, so
  # the control event that follows is accepted.
  my ($client, $pending) = _fake_client_and_pending(connected => 0, connect_ok => 1);
  $worker->_publish_control_once(client => $client, pending => $pending, sequence => 1, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cp-recon');
  is scalar @{$stream}, 1, 'one control operation ran after the reconnect';
  is $stream->[0]{status}, 'success', 'the re-established authority accepted the control event';
};

subtest 'a failed reconnect is an error metric and the operation is skipped' => sub {
  my $run_dir = _layout('cp-reconfail');
  my $worker  = _primed_worker(_input($run_dir, 'cp-reconfail'), 1);
  $worker->open_metric_stream;

  my ($client, $pending) = _fake_client_and_pending(connected => 0, connect_ok => 0);
  $worker->_publish_control_once(client => $client, pending => $pending, sequence => 1, phase => 'main');
  $worker->close_metric_stream;

  my $stream = _stream($run_dir, 'cp-reconfail');
  is scalar @{$stream}, 1, 'exactly one error was recorded for the failed reconnect';
  like $stream->[0]{error}, qr/reconnect failed/, 'the failed reconnect is the reported error';
};

subtest 'a grant the relay refuses fails the authority bootstrap' => sub {
  my $worker = _primed_worker(_input(_layout('cp-grant'), 'cp-grant'), 1);
  my ($client, $pending) = _fake_client_and_pending(connected => 1, reject_kinds => {14142 => 1});
  my ($ok, $reason) = $worker->_establish_authority($client, $pending);
  is $ok, 0, 'a rejected grant fails the bootstrap';
  like $reason, qr/grant rejected/, 'the failure names the grant';
};

subtest 'an operator bootstrap the relay refuses fails the authority bootstrap' => sub {
  my $worker = _primed_worker(_input(_layout('cp-op'), 'cp-op'), 1);
  my ($client, $pending) = _fake_client_and_pending(connected => 1, reject_kinds => {9000 => 1});
  my ($ok, $reason) = $worker->_establish_authority($client, $pending);
  is $ok, 0, 'a rejected operator put-user fails the bootstrap';
  like $reason, qr/operator bootstrap rejected/, 'the failure names the operator bootstrap';
};

# ---------------------------------------------------------------------------
# Integration against the real authority relay.
# ---------------------------------------------------------------------------

SKIP: {
  eval { require Overnet::Authority::HostedChannel::Relay; 1 }
    or skip 'Overnet::Authority::HostedChannel::Relay not available', 1;

  subtest 'control publisher generates authorized control load a real authority relay accepts' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('control-publisher-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 2, publish_rate_per_second => 5);

    Overnet::Burner::Worker::ControlPublisher->new(input => $input)->run;

    ok -e File::Spec->catfile($run_dir, 'workers', 'control-publisher-001', 'ready'),
      'the worker declared readiness only after establishing authority';

    my $events = _stream($run_dir, 'control-publisher-001');
    ok @{$events} >= 5,  'a plausible number of control operations ran' or diag(scalar @{$events});
    ok @{$events} <= 15, 'the configured rate was respected'           or diag(scalar @{$events});

    my @bad_shape = grep {
           $_->{operation} ne 'control_publish'
        || $_->{role} ne 'control_publisher'
        || ($_->{control_kind} // 0) != 9000
    } @{$events};
    is \@bad_shape, [], 'every metric is an authorized control_publish carrying its kind';

    my @failures = grep { $_->{status} ne 'success' } @{$events};
    is \@failures, [], 'the authority relay accepted every authorized control event'
      or diag(JSON->new->canonical(1)->encode(\@failures));

    my $authority =
      Overnet::Burner::Worker::ControlPublisher->derive_key(12345, 'control-publisher-001/authority')->pubkey_hex;
    my $session =
      Overnet::Burner::Worker::ControlPublisher->derive_key(12345, 'control-publisher-001/session')->pubkey_hex;

    is scalar @{_stored_events($port, authors => [$authority], kinds => [14142])}, 1,
      'exactly one delegation grant was published, by the authority key';
    ok scalar @{_stored_events($port, authors => [$session], kinds => [9000])} >= @{$events} + 1,
      'the relay stored the operator bootstrap plus every load control event, signed by the session key';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };

  subtest 'a relay-url mismatch fails the worker before readiness' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('control-publisher-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 2, publish_rate_per_second => 5);
    $input->{workload}{control} = {relay_url => 'ws://127.0.0.1:1'};

    my $error;
    eval { Overnet::Burner::Worker::ControlPublisher->new(input => $input)->run; 1 } or $error = $@;
    like $error, qr/could not establish its delegated authority/, 'the bootstrap failure is fatal';
    like $error, qr/bound to a different relay/,                  'the relay rejection reason is surfaced';
    ok !-e File::Spec->catfile($run_dir, 'workers', 'control-publisher-001', 'ready'),
      'a worker that never established authority is not marked ready';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };

  subtest 'a TERM signal stops the control publisher between phases' => sub {
    my $port      = _free_port();
    my $relay_pid = _spawn_authority_relay($port);

    my $run_dir = _layout('control-publisher-001');
    my $input   = _worker_input($run_dir, $port, duration_seconds => 10, publish_rate_per_second => 10);
    $input->{phases} = [
      {name => 'p1', start_seconds => 0, duration_seconds => 5, publish_rate_per_second => 10},
      {name => 'p2', start_seconds => 5, duration_seconds => 5, publish_rate_per_second => 10},
    ];

    my $parent = $$;
    my $killer = fork // die "fork: $!";
    if (!$killer) { sleep 0.8; kill 'TERM', $parent; exit 0 }

    Overnet::Burner::Worker::ControlPublisher->new(input => $input)->run;
    waitpid $killer, 0;

    my @phase2 = grep { ($_->{phase} // q{}) eq 'p2' } @{_stream($run_dir, 'control-publisher-001')};
    is \@phase2, [], 'the worker stopped before the second phase';

    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
  };
}

done_testing;

# --- helpers ----------------------------------------------------------------

sub _primed_worker {
  my ($input, $port) = @_;
  my $worker = Overnet::Burner::Worker::ControlPublisher->new(input => $input);
  $worker->{authority_key} = $worker->derive_key($input->{seed}, "$input->{worker_id}/authority");
  $worker->{session_key}   = $worker->derive_key($input->{seed}, "$input->{worker_id}/session");
  $worker->{relay_url}     = "ws://127.0.0.1:$port";
  $worker->{grant_kind}    = 14142;
  $worker->{group}         = 'burner-control-test';
  $worker->{scope}         = 'overnet-burner://control-test';
  $worker->{session_id}    = "$input->{worker_id}-session";
  $worker->{sequence}      = 0;
  $worker->{grant_id}      = '0' x 64;
  return $worker;
}

sub _fake_client_and_pending {
  my (%opt) = @_;
  my %pending;
  my $client = _FakeControlClient->new(%opt);
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
    run_id           => 'control-test-001',
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'control_publisher',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    workload         => {publish_rate_per_second => 1},
  };
}

sub _worker_input {
  my ($run_dir, $port, %workload) = @_;
  return {
    input_version    => 1,
    run_id           => 'control-test-001',
    run_dir          => $run_dir,
    worker_id        => 'control-publisher-001',
    role             => 'control_publisher',
    seed             => 12345,
    duration_seconds => delete $workload{duration_seconds},
    metric_stream    => 'metrics/control-publisher-001.jsonl',
    ready_file       => 'workers/control-publisher-001/ready',
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {%workload},
  };
}

sub _layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

# Run the relay in a freshly exec'd perl (never a bare fork), so the child does
# not inherit this process's already-initialized AnyEvent loop.
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
      "-I$FindBin::Bin/../../core-perl/lib",
      '-MOvernet::Authority::HostedChannel::Relay',
      '-e', $code, $port
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

# A fake relay client that acknowledges each publish synchronously: accepting,
# or rejecting an event by its kind, so the worker's authorization-flow branches
# can be exercised without a live relay.
package _FakeControlClient;

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
