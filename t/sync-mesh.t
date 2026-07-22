use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use AnyEvent;
use FindBin;
use IO::Socket::INET;
use JSON  ();
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Net::Nostr::Client;
use Net::Nostr::Filter;
use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::Worker;
use Overnet::Burner::Worker::SyncBridge;

# sync-mesh converges a set of relays larger than a pair over a configurable
# topology. Two checks: the shipped scenario is a well-formed, plannable
# multi-relay + sync_bridge composition (runnable here on the generic-relay
# provider), and the mechanism it relies on -- one sync_bridge folding an
# accumulating local copy across every relay -- actually converges three
# asymmetrically written relays to their global union against real relays.

subtest 'the scenario is a well-formed multi-relay + sync_bridge composition' => sub {
  my $config = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/sync-mesh.yml");

  ok lives { Overnet::Burner::Config->validate($config) }, 'the sync-mesh scenario validates';

  is $config->{topology}{relays}{count}, 3, 'the mesh is larger than a pair';

  my $plan = Overnet::Burner::Plan->build($config);

  is scalar @{$plan->{relays}}, 3, 'the run plans every relay in the mesh';
  is [map { $_->{id} } @{$plan->{sync_bridges}}], ['sync-bridge-001'],
    'the run plans a single sync_bridge to converge the mesh';
};

subtest 'a sync_bridge converges three asymmetrically written relays to their union' => sub {
  my @ports  = (_free_port(), _free_port(), _free_port());
  my @pids    = map { _spawn_relay($_) } @ports;
  my @relays  = map { "ws://127.0.0.1:$_" } @ports;
  my ($a, $b, $c) = @relays;

  # Staggered writes with a one-event overlap between neighbours:
  # A={1,2,3}, B={3,4,5}, C={5,6,7}. No relay holds the whole union; each shares
  # exactly one object with the next, so convergence must pull from all three.
  _seed_events($a, 1, 2, 3);
  _seed_events($b, 3, 4, 5);
  _seed_events($c, 5, 6, 7);

  my $run_dir = _layout('sm-run');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input($run_dir, 'sm-run', [@relays], {sync_bridge => {interval_seconds => 0.25}}, 0.9),);
  $bridge->run;

  my @final = map { _dump_relay($_) } @relays;

  kill 'TERM', @pids;
  waitpid $_, 0 for @pids;

  is [sort keys %{$final[0]}], [sort keys %{$final[1]}], 'the first and second relay hold the same set';
  is [sort keys %{$final[1]}], [sort keys %{$final[2]}], 'the second and third relay hold the same set';
  is scalar(keys %{$final[0]}), 7, 'every relay converged to the seven-event global union';

  my ($first) = @{_metric_events($run_dir, 'sm-run')};
  is $first->{operation},    'sync_converge', 'the metric is a sync_converge';
  is $first->{status},       'success',       'a converging mesh session succeeds';
  is $first->{relay_count},  3,               'the metric records how many relays were converged';
  is $first->{rounds},       5,               'convergence across three relays takes 2n-1 negentropy passes';
  is $first->{fetched_count}, 7,              'the bridge fetches the whole union exactly once';
  is $first->{pushed_count},  12,             'the bridge pushes every relay the union members it lacked';
  is $first->{left_url},      $a,             'the metric records the first relay of the set';
  is $first->{right_url},     $c,             'the metric records the last relay of the set';
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
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'sync_bridge',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => $relays},
    workload         => $workload,
  };
}

sub _metric_events {
  my ($run_dir, $worker_id) = @_;
  my $path = File::Spec->catfile($run_dir, 'metrics', "$worker_id.jsonl");
  return [] unless -f $path;
  open my $fh, '<', $path or die "open $path: $!";
  my @events;
  while (my $line = <$fh>) {
    next unless $line =~ /\S/mx;
    push @events, JSON::decode_json($line);
  }
  close $fh or die "close $path: $!";
  return \@events;
}

sub _seed_events {
  my ($url, @specs) = @_;
  my $key    = Overnet::Burner::Worker->derive_key('seed', 'sync-mesh-seed');
  my $client = Net::Nostr::Client->new;
  my %ok;
  my $cv = AnyEvent->condvar;
  $client->on(ok => sub { my ($id, $accepted) = @_; $ok{$id} = $accepted; $cv->send if keys %ok == @specs; });
  $client->connect($url);
  for my $spec (@specs) {

    # Pin created_at deterministically per spec so an object shared by two relays
    # carries the same event id regardless of when it is seeded. Defaulting to the
    # wall clock makes a shared object's id depend on whether the two seed calls
    # land in the same unix second, which inflates the convergence union past the
    # expected count when instrumentation slows seeding across a second boundary.
    $client->publish(
      $key->create_event(
        kind       => 7800,
        created_at => 1_700_000_000 + $spec,
        content    => "e-$spec",
        tags       => [['d', "obj-$spec"]],
      )
    );
  }
  my $timeout = AnyEvent->timer(after => 8, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;
  return;
}

sub _dump_relay {
  my ($url) = @_;
  my $client = Net::Nostr::Client->new;
  my %events;
  my $cv = AnyEvent->condvar;
  $client->on(event => sub { my ($sid, $ev) = @_; $events{$ev->id} = 1; });
  $client->on(eose  => sub { $cv->send });
  $client->connect($url);
  $client->subscribe('dump', Net::Nostr::Filter->new(kinds => [7800]));
  my $timeout = AnyEvent->timer(after => 5, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;
  return \%events;
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
    exec $^X, '-MNet::Nostr::Relay', '-e', 'Net::Nostr::Relay->new->run($ARGV[0], $ARGV[1])', '127.0.0.1', $port
      or die "exec: $!";
  }
  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe)                      { close $probe or die "close: $!"; return $pid }
    if (waitpid($pid, WNOHANG) != 0) { die "relay exited before listening\n" }
    sleep 0.1;
  }
  die "relay never listened on port $port\n";
}
