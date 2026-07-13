use strictures 2;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
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

subtest 'rex-remote deploys to every relay and fails a deploy that cannot complete' => sub {
  my $tmp    = tempdir(CLEANUP => 1);
  my $source = File::Spec->catfile($tmp, 'relay.conf');
  my $extra  = File::Spec->catfile($tmp, 'extra.conf');
  _write($source, "relay-config-body\n");
  _write($extra,  "extra-config-body\n");

  my $multi_scenario_path = File::Spec->catfile($tmp, 'multi.yml');
  _write(
    $multi_scenario_path,
    _deploy_scenario_yaml(
      source   => $source,
      dest     => File::Spec->catfile($tmp, 'deployed-relay.conf'),
      extra    => {source => $extra, dest => File::Spec->catfile($tmp, 'deployed-extra.conf')},
      relays   => 2,
      commands => {start => 'true', health => 'true', stop => 'true'},
    ),
  );

  my $summary = _run_runner(
    scenario_path => $multi_scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => 'multi-deploy',
  );

  my @deploys = grep { $_->{command_kind} eq 'deploy' } @{$summary->{topology_provider_commands}};
  is scalar @deploys, 2, 'each relay gets its own deploy command';
  is [map { $_->{status} } @deploys], [qw(completed completed)], 'both deploys complete';
  is $deploys[0]{command}, 'deploy 2 files', 'the deploy command counts its files';

  my $fail_scenario_path = File::Spec->catfile($tmp, 'fail.yml');
  _write(
    $fail_scenario_path,
    _deploy_scenario_yaml(
      source   => File::Spec->catfile($tmp, 'missing-source.conf'),
      dest     => File::Spec->catfile($tmp, 'never-written.conf'),
      commands => {start => 'true', health => 'true', stop => 'true'},
    ),
  );

  my $completed = eval {
    _run_runner(
      scenario_path => $fail_scenario_path,
      runs_dir      => File::Spec->catdir($tmp, 'runs'),
      run_id        => 'failed-deploy',
    );
    1;
  };
  my $error = $@;
  ok !$completed, 'a deploy that cannot complete fails the run';
  like $error, qr/deploy\ failed:\ relay-001\ exited\ with\ status/mx, 'the deploy failure names the relay and status';
};

subtest 'rex-remote maps provisioning to a Rex inventory and executor' => sub {
  my $tmp    = tempdir(CLEANUP => 1);
  my $runner = _load_runner($tmp, 'inventory');

  is $runner->_relay_inventory, {transport => 'local'}, 'non-connect provisioning keeps the relay local';

  _write_normalized_config($runner, {});
  is $runner->_relay_inventory, {transport => 'local'},
    'a config without provisioning defaults to the controller host';

  _write_normalized_config($runner, {provision => {relays => {how => 'connect', guests => [{}]}}});
  my $built = eval { $runner->_relay_inventory; 1 };
  my $error = $@;
  ok !$built, 'connect provisioning without a guest address is rejected';
  like $error, qr/requires\ a\ relay\ guest\ with\ an\ address/mx, 'the missing address is reported';

  _write_normalized_config($runner,
    {provision => {relays => {how => 'connect', guests => [{address => 'relay.example'}]}}});
  is $runner->_relay_inventory, {transport => 'ssh', host => 'relay.example'},
    'a bare connect guest maps to an ssh inventory without credentials';

  _write_normalized_config(
    $runner,
    {
      provision => {
        relays => {
          how    => 'connect',
          guests => [{address => 'relay.example', user => 'burner', key => '/keys/id_ed25519', port => 2222}],
        },
      },
    },
  );
  is $runner->_relay_inventory,
    {
    transport => 'ssh',
    host      => 'relay.example',
    user      => 'burner',
    key       => '/keys/id_ed25519',
    port      => 2222,
    },
    'guest credentials carry into the ssh inventory';

  is $runner->_remote_execution_mode,      'local',     'no inventory reports local execution';
  is $runner->_provider_command_executor,  'rex:local', 'no inventory names the local executor';

  $runner->{rex_inventory} = {transport => 'local'};
  is $runner->_remote_execution_mode, 'local', 'a local inventory reports local execution';

  $runner->{rex_inventory} = {transport => 'ssh', host => 'relay.example'};
  is($runner->_remote_execution_mode,     'remote',            'an ssh inventory reports remote execution');
  is($runner->_provider_command_executor, 'rex:relay.example', 'an ssh inventory names the target host');
};

subtest 'rex-remote skips empty deploys and requires a rendered bundle to deploy' => sub {
  my $tmp    = tempdir(CLEANUP => 1);
  my $runner = _load_runner($tmp, 'deploy-edges');

  ok($runner->_before_relay_start({actor_id => 'relay-001'}), 'a relay without a deploy is skipped');
  ok(
    $runner->_before_relay_start({actor_id => 'relay-001', deploy => {files => []}}),
    'a deploy without files is skipped',
  );
  ok(
    $runner->_before_relay_start({actor_id => 'relay-001', deploy => {}}),
    'a deploy without a file list is skipped',
  );

  my $deployed = eval { $runner->_run_deploy(actor_id => 'relay-001', deploy => {}); 1 };
  my $error    = $@;
  ok !$deployed, 'a deploy cannot run before the bundle is rendered';
  like $error, qr/Rex\ bundle\ has\ not\ been\ rendered/mx, 'the missing bundle is reported';
};

subtest 'rex-remote captures command output, exit codes, and signals' => sub {
  my $tmp    = tempdir(CLEANUP => 1);
  my $runner = _load_runner($tmp, 'capture');

  for my $case (
    [{command => ['true']}, 'cwd',     'capture requires a working directory'],
    [{cwd     => $tmp},     'command', 'capture requires a command'],
  ) {
    my ($bad_args, $field, $label) = @{$case};
    my $captured = eval { $runner->_capture_rex(%{$bad_args}); 1 };
    my $error    = $@;
    ok !$captured, $label;
    like $error, qr/\b$field\ is\ required\b/mx, "$label with a diagnostic";
  }

  my ($quiet_output, $quiet_exit) = $runner->_capture_rex(cwd => $tmp, command => ['true']);
  is $quiet_output, '', 'a silent command captures empty output';
  is $quiet_exit,   0,  'a successful command reports exit code zero';

  my ($output, $exit) = $runner->_capture_rex(
    cwd     => $tmp,
    command => ['/bin/sh', '-c', 'echo to-stdout; echo to-stderr >&2; exit 3'],
  );
  like $output, qr/to-stdout/mx, 'captures standard output';
  like $output, qr/to-stderr/mx, 'captures standard error merged into the output';
  is $exit, 3, 'reports the command exit code';

  my (undef, $signal_exit) = $runner->_capture_rex(
    cwd     => $tmp,
    command => ['/bin/sh', '-c', 'kill -TERM $$'],
  );
  is $signal_exit, 143, 'a signal-terminated command reports 128 plus the signal';

  my (undef, $chdir_exit) = $runner->_capture_rex(
    cwd     => File::Spec->catdir($tmp, 'missing-dir'),
    command => ['true'],
  );
  is $chdir_exit, 127, 'a working directory that cannot be entered reports exit code 127';
};

done_testing;

sub _load_runner {
  my ($tmp, $run_id) = @_;

  my $scenario_path = File::Spec->catfile($tmp, "$run_id.yml");
  _write($scenario_path, _external_scenario_yaml({start => 'exit 0', health => 'exit 0', stop => 'exit 0'}));

  my $scenario = Overnet::Burner::Config->load_file($scenario_path);
  my $ledger   = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => $run_id,
    now           => sub {'2026-07-09T14:00:00Z'},
    host_facts    => {hostname => 'builder', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  my $plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});

  return Overnet::Burner::Runner->load(
    name    => 'rex-remote',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );
}

sub _write_normalized_config {
  my ($runner, $config) = @_;

  _write(
    File::Spec->catfile($runner->{run_dir}, 'config.normalized.json'),
    JSON->new->canonical(1)->encode($config),
  );
  return;
}

sub _deploy_scenario_yaml {
  my (%args) = @_;
  my $files = [{source => $args{source}, dest => $args{dest}}];
  if ($args{extra}) {
    push @{$files}, $args{extra};
  }
  my $scenario = {
    run      => {name => 'rex-remote-deploy', duration => 60, seed => 24680},
    topology => {
      relays => {
        count    => $args{relays} || 1,
        provider => 'external-command',
        command  => $args{commands},
        deploy   => {files => $files},
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
