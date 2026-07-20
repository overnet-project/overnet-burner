use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use AnyEvent;
use FindBin;
use IO::Socket::INET;
use JSON ();
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

# partition-and-recover composes managed container provisioning, network chaos,
# and the sync_bridge. Two checks: the shipped scenario is a well-formed,
# plannable partition/heal + bridge composition (runnable here), and the
# recovery mechanism it relies on -- a sync_bridge reconverging a pair that
# diverged while the sync path was down -- actually works against real relays.
# The container partition/heal execution itself needs Docker and is covered by
# t/runner-provision-container.t.

subtest 'the scenario is a well-formed partition/heal + sync_bridge composition' => sub {
  my $config = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/partition-and-recover.yml");

  ok lives { Overnet::Burner::Config->validate($config) },
    'the partition-and-recover scenario validates (container workers + network chaos)';

  is $config->{provision}{workers}{how}, 'container',
    'the managed environment provisions workers as containers';
  is $config->{provision}{workers}{network}, 'bridge',
    'workers run on a bridge network, which network chaos requires';

  my $plan = Overnet::Burner::Plan->build($config);

  is [map { $_->{id} } @{$plan->{sync_bridges}}], ['sync-bridge-001'],
    'the run plans a sync_bridge as the convergence verifier';
  is scalar @{$plan->{relays}}, 2, 'the run plans the two relays a bridge needs';

  my @hooks = @{$plan->{chaos_hooks}};
  is scalar @hooks, 2, 'the run plans the partition and the heal';
  is [map { $_->{action} } @hooks], ['partition', 'heal'], 'a partition is followed by a heal';
  is $hooks[0]{at_seconds}, 20, 'the partition fires mid-run';
  is $hooks[1]{at_seconds}, 40, 'the heal restores connectivity later in the run';
  is [map { $_->{target} } @hooks], ['worker-guest:1', 'worker-guest:1'],
    'the heal reconnects the guest the partition cut off';
};

subtest 'a sync_bridge reconverges a pair that diverged while the sync path was down' => sub {
  my $port_a = _free_port();
  my $pid_a  = _spawn_relay($port_a);
  my $port_b = _free_port();
  my $pid_b  = _spawn_relay($port_b);
  my $a      = "ws://127.0.0.1:$port_a";
  my $b      = "ws://127.0.0.1:$port_b";

  # Before the partition both relays share a baseline; while the sync path is
  # down, writes land on A only, so B falls behind.
  _seed_events($a, 1, 2, 3);
  _seed_events($b, 1, 2, 3);
  _seed_events($a, 4, 5);

  ok scalar(keys %{_dump_relay($a)}) > scalar(keys %{_dump_relay($b)}),
    'the relays have diverged: A holds writes B missed during the outage';

  my $run_dir = _layout('par-run');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input($run_dir, 'par-run', [$a, $b], {sync_bridge => {interval_seconds => 0.25}}, 0.8),
  );
  $bridge->run;

  my $final_a = _dump_relay($a);
  my $final_b = _dump_relay($b);

  kill 'TERM', $pid_a, $pid_b;
  waitpid $pid_a, 0;
  waitpid $pid_b, 0;

  is [sort keys %{$final_a}], [sort keys %{$final_b}], 'after recovery both relays hold the same set';
  is scalar(keys %{$final_b}), 5, 'the lagging relay caught up to the full union';

  my ($first) = @{_metric_events($run_dir, 'par-run')};
  is $first->{status}, 'success', 'the recovery session converges';
  ok $first->{fetched_count} >= 2 && $first->{pushed_count} >= 2,
    'the bridge fetched the missed writes and pushed them to the lagging relay';
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
  my $key    = Overnet::Burner::Worker->derive_key('seed', 'partition-seed');
  my $client = Net::Nostr::Client->new;
  my %ok;
  my $cv = AnyEvent->condvar;
  $client->on(ok => sub { my ($id, $accepted) = @_; $ok{$id} = $accepted; $cv->send if keys %ok == @specs; });
  $client->connect($url);
  for my $spec (@specs) {
    $client->publish($key->create_event(kind => 7800, content => "e-$spec", tags => [['d', "obj-$spec"]]));
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
  $client->on(eose => sub { $cv->send });
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
