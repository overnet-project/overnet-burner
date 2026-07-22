use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Metrics;
use Overnet::Burner::Plan;
use Overnet::Burner::Worker::Publisher;

# chaos-restart-under-load runs steady publish/subscribe load against a single
# relay and restarts that relay mid-run. Two checks: the shipped scenario is a
# well-formed, plannable restart-under-load composition whose chaos hook can
# actually execute (a relay lifecycle restart needs a provider with lifecycle
# commands), and the recovery mechanism it relies on -- the reference publisher
# reconnecting across the outage under the worker contract's Connection Loss
# rules -- actually works against a real relay, keeping the run within the
# scenario's recovery-tolerant error-rate ceiling.

subtest 'the scenario is a well-formed restart-under-load composition' => sub {
  my $config = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/chaos-restart-under-load.yml");

  ok lives { Overnet::Burner::Config->validate($config) }, 'the chaos-restart-under-load scenario validates';

  # A relay lifecycle restart requires a topology provider with lifecycle
  # commands; the scenario drives the reference relay through external-command.
  is $config->{topology}{relays}{provider}, 'external-command', 'the relay uses a lifecycle-capable provider';
  for my $step (qw(start stop health)) {
    ok((defined $config->{topology}{relays}{command}{$step} && length $config->{topology}{relays}{command}{$step}),
      "the provider defines a $step lifecycle command");
  }

  is $config->{thresholds}{error_rate_max}, 0.5, 'the error-rate ceiling is loosened for recovery';

  my $plan = Overnet::Burner::Plan->build($config);

  is scalar @{$plan->{relays}},             1,                  'the run plans the single relay under load';
  is scalar @{$plan->{publishers}},         2,                  'the run plans the publisher load';
  is scalar @{$plan->{subscribers} || []},  1,                  'the run plans the subscriber load';
  is $plan->{relays}[0]{topology_provider}, 'external-command', 'the planned relay keeps its lifecycle provider';
  ok(
    (
           defined $plan->{relays}[0]{topology_provider_descriptor}{command}{stop}
        && defined $plan->{relays}[0]{topology_provider_descriptor}{command}{start}
    ),
    'the planned relay carries the stop/start commands the restart hook runs'
  );

  my @hooks = @{$plan->{chaos_hooks}};
  is scalar @hooks,         1,         'the run plans exactly the restart hook';
  is $hooks[0]{action},     'restart', 'the hook is a relay restart';
  is $hooks[0]{target},     'relay:1', 'the hook targets the relay under load';
  is $hooks[0]{at_seconds}, 30,        'the restart fires mid-run';
};

subtest 'a publisher under load recovers across a relay restart' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _run_layout('publisher-001');
  my $input   = _worker_input($run_dir, 'publisher-001', $port, duration_seconds => 8, publish_rate_per_second => 5);

  # The publisher runs its full duration in a child; the parent injects the
  # restart (stop then start, as the chaos hook would) partway through.
  my $pub_pid = fork;
  die "fork: $!" if !defined $pub_pid;
  if (!$pub_pid) {
    Overnet::Burner::Worker::Publisher->new(input => $input)->run;
    exit 0;
  }

  my $ready    = File::Spec->catfile($run_dir, 'workers', 'publisher-001', 'ready');
  my $deadline = time + 10;
  while (time < $deadline && !-e $ready) {
    if (waitpid($pub_pid, WNOHANG) == $pub_pid) {
      die "publisher exited before becoming ready\n";
    }
    sleep 0.05;
  }
  ok -e $ready, 'the publisher is under load against the original relay';

  sleep 1;
  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
  my $restarted_pid = _spawn_relay($port);

  waitpid $pub_pid, 0;
  is $? >> 8, 0, 'the publisher survived the restart without dying';

  my $events = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  my @errors = grep { $_->{status} eq 'error' } @{$events};
  ok scalar(@errors) >= 1, 'the outage produced error metrics, not worker death' or diag scalar @{$events};

  my ($last_error_index) = grep { $events->[$_]{status} eq 'error' } reverse 0 .. $#{$events};
  my @after_recovery = grep { $_->{status} eq 'success' } @{$events}[$last_error_index .. $#{$events}];
  ok scalar(@after_recovery) >= 1, 'the publisher reconnected and published successfully after the restart';

  # The recovered run stays within the scenario's recovery-tolerant ceiling,
  # while still having recorded the outage a pristine run would not tolerate.
  my $summary = Overnet::Burner::Metrics->summarize($events);
  ok $summary->{overall}{error_rate} <= 0.5, 'the recovered run passes the scenario error-rate ceiling';
  ok $summary->{overall}{error_count} >= 1,  'the outage was real: a zero-error run would not have exercised recovery';

  kill 'TERM', $restarted_pid;
  waitpid $restarted_pid, 0;
};

done_testing;

sub _worker_input {
  my ($run_dir, $worker_id, $port, %workload) = @_;
  return {
    input_version    => 1,
    run_id           => 'chaos-restart-001',
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'publisher',
    seed             => 12345,
    duration_seconds => delete $workload{duration_seconds},
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {%workload},
  };
}

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
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
