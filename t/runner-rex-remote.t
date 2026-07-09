use strictures 2;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Runner;
use Overnet::Burner::RunLedger;
use YAML::PP;

# rex-remote genuinely invokes the rex binary, so the tests need it. It ships as
# a dependency and lives beside this perl; fall back to PATH, and skip only if
# neither resolves.
my $rex = _resolve_rex();
if (!$rex) {
  plan skip_all => 'the rex executable is not available';
}
local $ENV{OVERNET_BURNER_REX} = $rex;

subtest 'rex-remote performs the provider lifecycle locally through real Rex' => sub {
  my $tmp           = tempdir(CLEANUP => 1);
  my $start_marker  = File::Spec->catfile($tmp, 'start-ran');
  my $health_marker = File::Spec->catfile($tmp, 'health-ran');
  my $stop_marker   = File::Spec->catfile($tmp, 'stop-ran');
  my $commands      = {
    start  => "touch '$start_marker'",
    health => "touch '$health_marker'; test -e '$start_marker'",
    stop   => "touch '$stop_marker'",
  };

  my $scenario_path = File::Spec->catfile($tmp, 'external.yml');
  _write($scenario_path, _external_scenario_yaml($commands));
  my $runs_dir = File::Spec->catdir($tmp, 'runs');

  my $summary = _run_runner(scenario_path => $scenario_path, runs_dir => $runs_dir, run_id => 'local');

  is $summary->{runner},                       'rex-remote', 'summary names the rex-remote runner';
  is $summary->{rex_bundle}{remote_execution}, 'local',      'a controller-local run reports local execution';
  is [map { $_->{command_kind} } @{$summary->{topology_provider_commands}}], [qw(start health stop)],
    'runs start, health, and stop';
  is [map { $_->{status} } @{$summary->{topology_provider_commands}}], [qw(completed completed completed)],
    'each provider command completes';
  is [map { $_->{guest} } @{$summary->{topology_provider_commands}}], [('rex:local') x 3],
    'rex is recorded as the executor';

  ok -e $start_marker,  'real Rex executed the start command on the host';
  ok -e $health_marker, 'real Rex executed the health command on the host';
  ok -e $stop_marker,   'real Rex executed the stop command on the host';

  my $rexfile = _slurp(File::Spec->catfile($runs_dir, 'local', 'artifacts', 'rex', 'Rexfile'));
  like $rexfile,   qr/task\ 'provider_command'/mx, 'the run rendered a performed Rexfile';
  unlike $rexfile, qr/planned\ overnet-burner\ phase/mx, 'the performed Rexfile has no placeholder tasks';
};

subtest 'rex-remote performs the lifecycle over ssh and reports remote execution' => sub {
  if (!$ENV{OVERNET_BURNER_TEST_SSH_HOST}) {
    plan skip_all => 'set OVERNET_BURNER_TEST_SSH_HOST to run against a real sshd';
  }

  my $tmp          = tempdir(CLEANUP => 1);
  my $start_marker = File::Spec->catfile($tmp, 'ssh-start-ran');
  my $stop_marker  = File::Spec->catfile($tmp, 'ssh-stop-ran');
  my $commands     = {
    start  => "touch '$start_marker'",
    health => "test -e '$start_marker'",
    stop   => "touch '$stop_marker'",
  };

  my $scenario_path = File::Spec->catfile($tmp, 'connect.yml');
  _write(
    $scenario_path,
    _connect_scenario_yaml(
      $commands,
      host => $ENV{OVERNET_BURNER_TEST_SSH_HOST},
      user => $ENV{OVERNET_BURNER_TEST_SSH_USER},
      key  => $ENV{OVERNET_BURNER_TEST_SSH_KEY},
    ),
  );

  my $summary = _run_runner(
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => 'ssh',
  );

  is $summary->{rex_bundle}{remote_execution}, 'remote', 'an ssh run reports remote execution';
  is [map { $_->{status} } @{$summary->{topology_provider_commands}}], [qw(completed completed completed)],
    'each provider command completes over ssh';
  ok -e $start_marker, 'real Rex executed the start command over ssh';
  ok -e $stop_marker,  'real Rex executed the stop command over ssh';
};

subtest 'rex-remote deploys files to the host with real Rex before starting' => sub {
  my $tmp    = tempdir(CLEANUP => 1);
  my $source = File::Spec->catfile($tmp, 'relay.conf');
  my $dest   = File::Spec->catfile($tmp, 'deployed-relay.conf');
  _write($source, "relay-config-body\n");

  my $start_marker  = File::Spec->catfile($tmp, 'start-ran');
  my $scenario_path = File::Spec->catfile($tmp, 'deploy.yml');
  _write(
    $scenario_path,
    _deploy_scenario_yaml(
      source   => $source,
      dest     => $dest,
      commands => {
        start  => "touch '$start_marker'",
        health => "test -e '$start_marker'",
        stop   => "true",
      },
    ),
  );

  my $summary = _run_runner(
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => 'deploy',
  );

  ok -e $dest, 'real Rex deployed the file to the destination';
  is _slurp($dest), "relay-config-body\n", 'the deployed file has the source content';

  my @kinds = map { $_->{command_kind} } @{$summary->{topology_provider_commands}};
  is \@kinds, [qw(deploy start health stop)], 'deploy runs before start, then the lifecycle';
  my ($deploy) = grep { $_->{command_kind} eq 'deploy' } @{$summary->{topology_provider_commands}};
  is $deploy->{status}, 'completed', 'the deploy command completes';
  is $deploy->{guest},  'rex:local', 'rex is recorded as the deploy executor';
};

done_testing;

sub _deploy_scenario_yaml {
  my (%args) = @_;
  my $scenario = {
    run      => {name => 'rex-remote-deploy', duration => 60, seed => 24680},
    topology => {
      relays => {
        count    => 1,
        provider => 'external-command',
        command  => $args{commands},
        deploy   => {files => [{source => $args{source}, dest => $args{dest}}]},
      },
      publishers     => {count => 0},
      subscribers    => {count => 0},
      query_readers  => {count => 0},
      object_readers => {count => 0},
    },
    workload => {publish_rate_per_second => 0},
  };
  return YAML::PP->new(boolean => 'perl', schema => ['Core'])->dump_string($scenario);
}

sub _run_runner {
  my (%args) = @_;

  my $scenario = Overnet::Burner::Config->load_file($args{scenario_path});
  my $ledger   = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $args{scenario_path},
    runs_dir      => $args{runs_dir},
    run_id        => $args{run_id},
    now           => sub {'2026-07-09T14:00:00Z'},
    host_facts    => {hostname => 'builder', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  my $plan   = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});
  my $runner = Overnet::Burner::Runner->load(
    name    => 'rex-remote',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );

  return $runner->run_lifecycle;
}

sub _external_scenario_yaml {
  my ($command) = @_;

  return <<"YAML";
run:
  name: rex-remote-local
  duration: 60
  seed: 24680

topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: $command->{start}
      stop: $command->{stop}
      health: $command->{health}
  publishers:
    count: 0
  subscribers:
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0

workload:
  publish_rate_per_second: 0
YAML
}

sub _connect_scenario_yaml {
  my ($command, %target) = @_;

  return <<"YAML";
run:
  name: rex-remote-ssh
  duration: 60
  seed: 24680

topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: $command->{start}
      stop: $command->{stop}
      health: $command->{health}
  publishers:
    count: 0
  subscribers:
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0

workload:
  publish_rate_per_second: 0

provision:
  relays:
    how: connect
    guests:
      - address: $target{host}
        user: $target{user}
        key: $target{key}
YAML
}

sub _resolve_rex {
  my $beside = File::Spec->catfile(dirname($^X), 'rex');
  if (-x $beside) {
    return $beside;
  }
  for my $dir (File::Spec->path) {
    my $candidate = File::Spec->catfile($dir, 'rex');
    if (-x $candidate) {
      return $candidate;
    }
  }
  return;
}

sub _write {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content;
  close $fh or die "close $path: $!";
  return;
}

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  my $content = <$fh>;
  close $fh or die "close $path: $!";
  return $content;
}
