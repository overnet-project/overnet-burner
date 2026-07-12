use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Observer;

# In-process coverage for the observer: role, probe-interval derivation, a
# full localhost run that probes a live relay, an unreachable-relay ping
# that becomes an error metric, and a TERM stop.

subtest 'role and probe interval derivation' => sub {
  is(Overnet::Burner::Worker::Observer->expected_role, 'observer', 'declares the observer role');

  my $default = Overnet::Burner::Worker::Observer->new(input => _input(_layout('ob-def'), 'ob-def'));
  is $default->_probe_interval, 1, 'a missing probe interval defaults to one second';

  my $configured = Overnet::Burner::Worker::Observer->new(
    input => _input(_layout('ob-cfg'), 'ob-cfg', undef, {observer => {probe_interval_seconds => 0.2}}),
  );
  is $configured->_probe_interval, 0.2, 'a configured probe interval is honored';
};

subtest 'a full localhost run probes the relay every tick' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir  = _layout('ob-run');
  my $observer = Overnet::Burner::Worker::Observer->new(
    input => _input(
      $run_dir, 'ob-run',
      ["ws://127.0.0.1:$port", "ws://127.0.0.1:$port"],
      {observer => {probe_interval_seconds => 0.2}},
      0.7,
    ),
  );
  $observer->run;

  ok -e File::Spec->catfile($run_dir, 'workers', 'ob-run', 'ready'),
    'the observer declared readiness immediately';

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'ob-run.jsonl'));
  ok @{$stream} >= 2, 'the observer probed more than once' or diag scalar @{$stream};
  my @bad = grep { $_->{operation} ne 'relay_ping' } @{$stream};
  is \@bad, [], 'every event is a relay_ping';
  my @ok = grep { $_->{status} eq 'success' } @{$stream};
  ok @ok >= 1, 'a reachable relay produces success pings';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'a relay that never reaches the boundary yields a timeout error' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_silent_relay($port);

  # Two endpoints, a short duration: the first probe blocks on the probe
  # timeout, so by the time it returns the run deadline has passed and the
  # second endpoint is skipped.
  my $run_dir  = _layout('ob-silent');
  my $observer = Overnet::Burner::Worker::Observer->new(
    input => _input(
      $run_dir, 'ob-silent',
      ["ws://127.0.0.1:$port", "ws://127.0.0.1:$port"],
      {observer => {probe_interval_seconds => 0.2}},
      0.3,
    ),
  );
  $observer->run;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'ob-silent.jsonl'));
  is scalar @{$stream}, 1, 'only the first endpoint was probed before the deadline passed';
  is $stream->[0]{status}, 'error',              'a relay that never sends EOSE is an error';
  is $stream->[0]{error},  'relay ping timed out', 'the error names the probe timeout';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'a TERM signal stops the observer' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _layout('ob-term');
  my $input   = _input($run_dir, 'ob-term', ["ws://127.0.0.1:$port"],
    {observer => {probe_interval_seconds => 0.2}}, 10);
  my $observer = Overnet::Burner::Worker::Observer->new(input => $input);

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { sleep 0.6; kill 'TERM', $parent; exit 0 }

  $observer->run;
  waitpid $killer, 0;

  ok -e File::Spec->catfile($run_dir, 'workers', 'ob-term', 'ready'),
    'the observer stopped after the signal without hanging for its full duration';

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
  my ($run_dir, $worker_id, $relays, $workload, $duration) = @_;
  $relays   //= ['ws://127.0.0.1:1'];
  $duration //= 1;
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'observer',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => $relays},
    workload         => $workload // {},
  };
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _spawn_silent_relay {
  my ($port) = @_;
  my $script = File::Spec->catfile(tempdir(CLEANUP => 1), 'silent-relay');
  open my $fh, '>', $script or die "open $script: $!";
  print {$fh} <<'PERL' or die "print: $!";
use strict;
use warnings;
use Net::Nostr::Relay;
package SilentRelay;
our @ISA = ('Net::Nostr::Relay');
sub _handle_req { return }    # accept the subscription but never send EOSE
package main;
SilentRelay->new->run($ARGV[0], $ARGV[1]);
PERL
  close $fh or die "close: $!";

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) { exec $^X, $script, '127.0.0.1', $port or die "exec: $!" }
  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) { close $probe or die "close: $!"; return $pid }
    if (waitpid($pid, WNOHANG) != 0) { die "silent relay exited before listening\n" }
    sleep 0.1;
  }
  die "silent relay never listened on port $port\n";
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
