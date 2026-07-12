use strictures 2;

use AnyEvent;
use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Net::Nostr::Client;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Publisher;
use Overnet::Burner::Worker::Subscriber;

# In-process coverage for the subscriber: role, the missing-filter fatal
# path, and a full run driven by a helper child that stores replay events,
# publishes live stamped/unstamped/future events, and restarts the relay to
# force a reconnect. A second run covers the TERM stop.

subtest 'role and missing filters' => sub {
  is(Overnet::Burner::Worker::Subscriber->expected_role, 'subscriber', 'declares the subscriber role');
  my $run_dir = _layout('sub-empty');
  my $sub     = Overnet::Burner::Worker::Subscriber->new(input => _input($run_dir, 'sub-empty', undef));
  like dies { $sub->run }, qr/subscription_filters/mx, 'a run without filters is fatal';
};

subtest 'a full run measures live fanout across a reconnect' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  # Replay events stored before the subscriber connects: these arrive during
  # replay and must not be measured.
  _publish($port, {seq => 100, stamp => 'now'}, {seq => 101, stamp => 'now'});

  my $run_dir    = _layout('sub-run');
  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'sub-run', 'ready');
  my $sub        = Overnet::Burner::Worker::Subscriber->new(
    input => _input($run_dir, 'sub-run', [{kinds => [7800]}], "ws://127.0.0.1:$port", 6),
  );

  my $driver = fork;
  die "fork: $!" if !defined $driver;
  if (!$driver) {
    _await_file($ready_path, 15);
    # Live events on the first relay: a stamped one (measured), an unstamped
    # one (observed but not measured), and a future-stamped one (clamped).
    _publish($port, {seq => 1, stamp => 'now'});
    _publish($port, {seq => 2, stamp => 'none'});
    _publish($port, {seq => 3, stamp => 'future'});
    sleep 0.4;
    kill 'TERM', $relay_pid;
    waitpid $relay_pid, 0;
    my $restarted = _spawn_relay($port);
    sleep 0.6;    # let the watchdog reconnect and resubscribe
    _publish($port, {seq => 4, stamp => 'now'});
    _publish($port, {seq => 5, stamp => 'now'});
    sleep 0.3;
    kill 'TERM', $restarted;
    waitpid $restarted, 0;
    exit 0;
  }

  $sub->run;
  waitpid $driver, 0;

  ok -e $ready_path, 'the subscriber wrote its ready file at the replay boundary';
  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'sub-run.jsonl'));
  my @bad = grep { $_->{operation} ne 'subscription_fanout' || $_->{status} ne 'success' } @{$stream};
  is \@bad, [], 'every measured event is a successful fanout';
  ok @{$stream} >= 1, 'at least one live event was measured' or diag scalar @{$stream};
  my @negative = grep { $_->{duration_ms} < 0 } @{$stream};
  is \@negative, [], 'no fanout carries a negative duration';
};

subtest 'a TERM signal stops the subscriber' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _layout('sub-term');
  my $sub     = Overnet::Burner::Worker::Subscriber->new(
    input => _input($run_dir, 'sub-term', [{kinds => [7800]}], "ws://127.0.0.1:$port", 30),
  );
  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'sub-term', 'ready');

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { _await_file($ready_path, 15); sleep 0.3; kill 'TERM', $parent; exit 0 }

  my $started = time;
  $sub->run;
  waitpid $killer, 0;
  ok time - $started < 25, 'the subscriber stopped on the signal rather than running its full duration';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

done_testing;

sub _layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _input {
  my ($run_dir, $worker_id, $filters, $relay, $duration) = @_;
  $relay    //= 'ws://127.0.0.1:1';
  $duration //= 2;
  my %workload = defined $filters ? (subscription_filters => $filters) : ();
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'subscriber',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => [$relay]},
    workload         => \%workload,
  };
}

sub _await_file {
  my ($path, $timeout) = @_;
  my $deadline = time + $timeout;
  while (time < $deadline) {
    return 1 if -e $path;
    sleep 0.05;
  }
  return 0;
}

sub _publish {
  my ($port, @specs) = @_;
  my $key    = Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-001');
  my $client = Net::Nostr::Client->new;
  my %pending;
  $client->on(
    ok => sub {
      my ($event_id, $accepted) = @_;
      my $waiter = delete $pending{$event_id};
      $waiter->send($accepted) if $waiter;
    }
  );
  $client->connect("ws://127.0.0.1:$port");
  for my $spec (@specs) {
    my %body = (sequence => $spec->{seq});
    if ($spec->{stamp} eq 'now') {
      $body{sent_at} = time * 1000;
    } elsif ($spec->{stamp} eq 'future') {
      $body{sent_at} = (time + 30) * 1000;
    }
    my $event = $key->create_event(
      kind    => 7800,
      content => JSON->new->canonical(1)->encode({provenance => {type => 'native'}, body => \%body}),
      tags    => [['overnet_v', '0.1.0']],
    );
    my $waiter = AnyEvent->condvar;
    $pending{$event->id} = $waiter;
    $client->publish($event);
    $waiter->recv;
    sleep 0.05;
  }
  $client->disconnect;
  return;
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _spawn_relay {
  my ($port) = @_;
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    exec $^X, '-MNet::Nostr::Relay', '-e',
      'Net::Nostr::Relay->new->run($ARGV[0], $ARGV[1])', '127.0.0.1', $port
      or die "exec: $!";
  }
  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) { close $probe or die "close: $!"; return $pid }
    if (waitpid($pid, WNOHANG) != 0) { die "relay exited before listening\n" }
    sleep 0.1;
  }
  die "relay never listened on port $port\n";
}
