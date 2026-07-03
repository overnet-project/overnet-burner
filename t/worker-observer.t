use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON  ();
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo   = "$FindBin::Bin/..";
my $worker = "$repo/bin/overnet-burner-worker";

subtest 'observer probes every relay endpoint on its interval' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _run_layout('observer-001');
  my $input   = {
    input_version    => 1,
    run_id           => 'observer-test-001',
    run_dir          => $run_dir,
    worker_id        => 'observer-001',
    role             => 'observer',
    seed             => 12345,
    duration_seconds => 2,
    metric_stream    => 'metrics/observer-001.jsonl',
    ready_file       => 'workers/observer-001/ready',
    endpoints        => {relays   => ["ws://127.0.0.1:$port", 'ws://127.0.0.1:1']},
    workload         => {observer => {probe_interval_seconds => 0.5}},
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'observer-001', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
    exec $^X, "-I$repo/lib", $worker or die "exec: $!";
  }

  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'observer-001', 'ready');
  my $deadline   = time + 10;
  while (time < $deadline && !-e $ready_path) {
    if (waitpid($pid, WNOHANG) == $pid) {
      die "observer exited before becoming ready\n";
    }
    sleep 0.05;
  }
  ok -e $ready_path, 'observer declared readiness immediately';

  waitpid $pid, 0;
  is $? >> 8, 0, 'observer exited cleanly after its duration';

  my $stream = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'observer-001.jsonl'));

  my @bad_shape = grep { $_->{operation} ne 'relay_ping' || !$_->{relay_url} || !$_->{phase} } @{$stream};
  is \@bad_shape, [], 'every probe is a relay_ping event naming its endpoint and phase';

  my @live = grep { $_->{relay_url} eq "ws://127.0.0.1:$port" } @{$stream};
  my @dead = grep { $_->{relay_url} eq 'ws://127.0.0.1:1' } @{$stream};
  ok @live >= 2, 'the live relay was probed on the interval' or diag(scalar @live);
  ok @dead >= 2, 'the dead relay was probed on the interval' or diag(scalar @dead);

  my @live_failures = grep { $_->{status} ne 'success' } @live;
  is \@live_failures, [], 'probes against the live relay succeed';

  my @dead_successes = grep { $_->{status} ne 'error' || !$_->{error} } @dead;
  is \@dead_successes, [], 'probes against the dead relay are error metrics with a reason';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'an unreachable relay never kills the observer' => sub {
  my $run_dir = _run_layout('observer-002');
  my $input   = {
    input_version    => 1,
    run_id           => 'observer-test-002',
    run_dir          => $run_dir,
    worker_id        => 'observer-002',
    role             => 'observer',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => 'metrics/observer-002.jsonl',
    ready_file       => 'workers/observer-002/ready',
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    workload         => {},
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'observer-002', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
  my $output = `$^X -I$repo/lib $worker 2>&1`;
  is $? >> 8, 0, 'observer exits zero with only dead relays' or diag($output);

  my $stream = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'observer-002.jsonl'));
  ok @{$stream} >= 1, 'the dead relay was still observed';
  my @bad = grep { $_->{status} ne 'error' } @{$stream};
  is \@bad, [], 'observations of a dead relay are error metrics';
};

done_testing;

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _spawn_relay {
  my ($port) = @_;
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    exec $^X, '-MNet::Nostr::Relay', '-e', 'Net::Nostr::Relay->new->run($ARGV[0], $ARGV[1])', '127.0.0.1', $port
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
      die "relay child exited before listening\n";
    }
    sleep 0.1;
  }
  die "relay child never listened on port $port\n";
}

sub _free_port {
  my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
  ) or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
