use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Runner;
use Overnet::Burner::RunLedger;

my $repo              = "$FindBin::Bin/..";
my $bin               = "$repo/bin/overnet-burner";
my $baseline_scenario = "$repo/scenarios/single-relay-baseline.yml";
my @rex_tasks         = qw(bootstrap deploy start warmup run chaos collect cleanup);

my $success_tmp         = tempdir(CLEANUP => 1);
my $success_rex_log     = File::Spec->catfile($success_tmp, 'fake-rex.log');
my $success_fake_rex    = _write_fake_rex($success_tmp);
my $success_marker      = File::Spec->catfile($success_tmp, 'relay.started');
my $success_stop_marker = File::Spec->catfile($success_tmp, 'relay.stopped');
my $success_commands    = {
  start  => "printf start > '$success_marker'; echo start-out",
  health => "test -f '$success_marker' && echo health-out",
  stop   => "printf stop > '$success_stop_marker'; echo stop-out",
};
my $success_scenario = File::Spec->catfile($success_tmp, 'external.yml');
_write_yaml($success_scenario, _external_scenario_yaml($success_commands));

local $ENV{OVERNET_BURNER_REX}          = $success_fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $success_rex_log;

my $success_summary = _run_runner(
  runner_name   => 'rex-local-provider',
  scenario_path => $success_scenario,
  runs_dir      => File::Spec->catdir($success_tmp, 'runs'),
  run_id        => 'success',
);

is $success_summary->{runner},           'rex-local-provider', 'summary records opt-in provider runner';
is $success_summary->{rex_bundle}{path}, 'artifacts/rex',      'provider runner keeps rex-local bundle rendering';
is [map { $_->{task} } @{$success_summary->{rex_tasks}}], \@rex_tasks,
  'provider runner keeps rex-local Rex task execution';
is [map { $_->{command_kind} } @{$success_summary->{topology_provider_commands}}],
  [qw(start health stop)],
  'provider runner records start, health, and stop command results';
is [map { $_->{status} } @{$success_summary->{topology_provider_commands}}],
  [qw(completed completed completed)],
  'provider command results record completion';
is [map { $_->{exit_code} } @{$success_summary->{topology_provider_commands}}],
  [0, 0, 0],
  'provider command results record exit codes';
is [map { $_->{actor_id} } @{$success_summary->{topology_provider_commands}}],
  [qw(relay-001 relay-001 relay-001)],
  'provider command results record actor ids';
is $success_summary->{topology_provider_commands}[0]{command},
  $success_commands->{start},
  'provider command result records command string from rendered artifact';
is $success_summary->{topology_provider_commands}[0]{stdout_path},
  'logs/provider/relay-001-start.stdout',
  'provider command result records deterministic stdout path';
is $success_summary->{topology_provider_commands}[0]{stderr_path},
  'logs/provider/relay-001-start.stderr',
  'provider command result records deterministic stderr path';
ok -e $success_marker,      'start provider command ran';
ok -e $success_stop_marker, 'stop provider command ran';

my $success_run_dir = File::Spec->catdir($success_tmp, 'runs', 'success');
for my $kind (qw(start health stop)) {
  ok -e File::Spec->catfile($success_run_dir, 'logs', 'provider', "relay-001-$kind.stdout",),
    "$kind stdout artifact exists";
  ok -e File::Spec->catfile($success_run_dir, 'logs', 'provider', "relay-001-$kind.stderr",),
    "$kind stderr artifact exists";
}
is _read_file(File::Spec->catfile($success_run_dir, 'logs', 'provider', 'relay-001-start.stdout')),
  "start-out\n",
  'start stdout artifact captures command output';
is _read_file(File::Spec->catfile($success_run_dir, 'logs', 'provider', 'relay-001-health.stdout')),
  "health-out\n",
  'health stdout artifact captures command output';
is _read_file(File::Spec->catfile($success_run_dir, 'logs', 'provider', 'relay-001-stop.stdout')),
  "stop-out\n",
  'stop stdout artifact captures command output';
is _read_file(File::Spec->catfile($success_run_dir, 'logs', 'provider', 'relay-001-start.stderr')), '',
  'start stderr artifact captures empty stderr';

my $success_events  = _read_jsonl(File::Spec->catfile($success_run_dir, 'logs', 'runner.jsonl'),);
my @provider_events = grep { exists $_->{command_kind} } @{$success_events};
is [map {"$_->{command_kind}:$_->{status}"} @provider_events],
  ['start:started', 'start:completed', 'health:started', 'health:completed', 'stop:started', 'stop:completed',],
  'runner log records provider command event order';
is $provider_events[0]{runner},      'rex-local-provider', 'provider event records runner name';
is $provider_events[0]{actor_id},    'relay-001',          'provider event records actor id';
is $provider_events[1]{exit_code},   0,                    'provider completion event records exit code';
is $provider_events[1]{stdout_path}, 'logs/provider/relay-001-start.stdout', 'provider event records stdout path';
is $provider_events[1]{stderr_path}, 'logs/provider/relay-001-start.stderr', 'provider event records stderr path';
is $provider_events[1]{command},     $success_commands->{start},             'provider event records command string';

my @rex_invocations = _read_lines($success_rex_log);
is scalar @rex_invocations, scalar @rex_tasks, 'provider runner invokes rendered Rex tasks';

my $summary_artifact =
  _read_json(File::Spec->catfile($success_run_dir, 'artifacts', 'rex-local-provider-runner.json'),);
is $summary_artifact, $success_summary, 'provider runner writes summary artifact with command results';

my $failure_tmp         = tempdir(CLEANUP => 1);
my $failure_fake_rex    = _write_fake_rex($failure_tmp);
my $failure_rex_log     = File::Spec->catfile($failure_tmp, 'fake-rex.log');
my $failure_marker      = File::Spec->catfile($failure_tmp, 'relay.started');
my $failure_stop_marker = File::Spec->catfile($failure_tmp, 'relay.stopped');
my $failure_commands    = {
  start  => "printf start > '$failure_marker'",
  health => "echo health failed >&2; exit 42",
  stop   => "printf stop > '$failure_stop_marker'",
};
my $failure_scenario = File::Spec->catfile($failure_tmp, 'external.yml');
_write_yaml($failure_scenario, _external_scenario_yaml($failure_commands));

{
  local $ENV{OVERNET_BURNER_REX}          = $failure_fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $failure_rex_log;
  my $failed =
`$^X $bin run --scenario $failure_scenario --runs-dir $failure_tmp/runs --run-id failure --runner rex-local-provider 2>&1`;
  is $? >> 8, 2, 'CLI provider runner fails when health fails';
  like $failed, qr/provider\ command\ failed:\ relay-001\ health/mx, 'health failure is reported';
}
ok -e $failure_stop_marker, 'stop is attempted after successful start and failed health';

my $failure_events = _read_jsonl(File::Spec->catfile($failure_tmp, 'runs', 'failure', 'logs', 'runner.jsonl'),);
my @failure_provider_events = grep { exists $_->{command_kind} } @{$failure_events};
is [map {"$_->{command_kind}:$_->{status}"} @failure_provider_events],
  ['start:started', 'start:completed', 'health:started', 'health:failed', 'stop:started', 'stop:completed',],
  'provider runner records stop after health failure';
is $failure_provider_events[3]{exit_code}, 42, 'failed health event records exit code';

my $rex_failure_tmp         = tempdir(CLEANUP => 1);
my $rex_failure_fake_rex    = _write_fake_rex($rex_failure_tmp);
my $rex_failure_rex_log     = File::Spec->catfile($rex_failure_tmp, 'fake-rex.log');
my $rex_failure_marker      = File::Spec->catfile($rex_failure_tmp, 'relay.started');
my $rex_failure_stop_marker = File::Spec->catfile($rex_failure_tmp, 'relay.stopped');
my $rex_failure_commands    = {
  start  => "printf start > '$rex_failure_marker'",
  health => "test -f '$rex_failure_marker'",
  stop   => "printf stop > '$rex_failure_stop_marker'",
};
my $rex_failure_scenario = File::Spec->catfile($rex_failure_tmp, 'external.yml');
_write_yaml($rex_failure_scenario, _external_scenario_yaml($rex_failure_commands));
{
  local $ENV{OVERNET_BURNER_REX}                = $rex_failure_fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG}       = $rex_failure_rex_log;
  local $ENV{OVERNET_BURNER_TEST_REX_FAIL_TASK} = 'warmup';
  my $failed =
`$^X $bin run --scenario $rex_failure_scenario --runs-dir $rex_failure_tmp/runs --run-id rex-failure --runner rex-local-provider 2>&1`;
  is $? >> 8, 2, 'CLI provider runner fails when a Rex task fails';
  like $failed, qr/Rex\ task\ command\ failed:/mx, 'Rex failure is reported';
}
ok -e $rex_failure_stop_marker, 'stop is attempted after provider start and Rex task failure';
my $rex_failure_events =
  _read_jsonl(File::Spec->catfile($rex_failure_tmp, 'runs', 'rex-failure', 'logs', 'runner.jsonl'),);
my @rex_failure_provider_events = grep { exists $_->{command_kind} } @{$rex_failure_events};
is [map {"$_->{command_kind}:$_->{status}"} @rex_failure_provider_events],
  ['start:started', 'start:completed', 'health:started', 'health:completed', 'stop:started', 'stop:completed',],
  'provider runner records stop after Rex task failure';

my $stop_failure_tmp      = tempdir(CLEANUP => 1);
my $stop_failure_fake_rex = _write_fake_rex($stop_failure_tmp);
my $stop_failure_rex_log  = File::Spec->catfile($stop_failure_tmp, 'fake-rex.log');
my $stop_failure_marker   = File::Spec->catfile($stop_failure_tmp, 'relay.started');
my $stop_failure_commands = {
  start  => "printf start > '$stop_failure_marker'",
  health => "test -f '$stop_failure_marker'",
  stop   => "echo stop failed >&2; exit 43",
};
my $stop_failure_scenario = File::Spec->catfile($stop_failure_tmp, 'external.yml');
_write_yaml($stop_failure_scenario, _external_scenario_yaml($stop_failure_commands));
{
  local $ENV{OVERNET_BURNER_REX}          = $stop_failure_fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $stop_failure_rex_log;
  my $failed =
`$^X $bin run --scenario $stop_failure_scenario --runs-dir $stop_failure_tmp/runs --run-id stop-failure --runner rex-local-provider 2>&1`;
  is $? >> 8, 2, 'CLI provider runner fails when stop fails';
  like $failed, qr/provider\ command\ failed:\ relay-001\ stop/mx, 'stop failure is reported';
}
my $stop_failure_manifest =
  _read_json(File::Spec->catfile($stop_failure_tmp, 'runs', 'stop-failure', 'manifest.json'),);
is $stop_failure_manifest->{status}, 'failed', 'stop failure manifest records failed status';
like $stop_failure_manifest->{error}, qr/provider\ command\ failed:\ relay-001\ stop/mx,
  'stop failure manifest records provider stop error';
my $stop_failure_events =
  _read_jsonl(File::Spec->catfile($stop_failure_tmp, 'runs', 'stop-failure', 'logs', 'runner.jsonl'),);
my @stop_failure_provider_events = grep { exists $_->{command_kind} } @{$stop_failure_events};
is [map {"$_->{command_kind}:$_->{status}"} @stop_failure_provider_events],
  ['start:started', 'start:completed', 'health:started', 'health:completed', 'stop:started', 'stop:failed',],
  'provider runner records failed stop command';
is $stop_failure_provider_events[-1]{exit_code}, 43, 'failed stop event records exit code';

my $rex_local_tmp      = tempdir(CLEANUP => 1);
my $rex_local_fake_rex = _write_fake_rex($rex_local_tmp);
my $rex_local_rex_log  = File::Spec->catfile($rex_local_tmp, 'fake-rex.log');
my $rex_local_marker   = File::Spec->catfile($rex_local_tmp, 'relay.started');
my $rex_local_commands = {
  start  => "printf start > '$rex_local_marker'",
  health => 'echo health',
  stop   => 'echo stop',
};
my $rex_local_scenario = File::Spec->catfile($rex_local_tmp, 'external.yml');
_write_yaml($rex_local_scenario, _external_scenario_yaml($rex_local_commands));
{
  local $ENV{OVERNET_BURNER_REX}          = $rex_local_fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $rex_local_rex_log;
  _run_runner(
    runner_name   => 'rex-local',
    scenario_path => $rex_local_scenario,
    runs_dir      => File::Spec->catdir($rex_local_tmp, 'runs'),
    run_id        => 'rex-local',
  );
}
ok !-e $rex_local_marker, 'rex-local still does not execute provider commands';

my $generic_tmp      = tempdir(CLEANUP => 1);
my $generic_fake_rex = _write_fake_rex($generic_tmp);
my $generic_rex_log  = File::Spec->catfile($generic_tmp, 'fake-rex.log');
{
  local $ENV{OVERNET_BURNER_REX}          = $generic_fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $generic_rex_log;
  my $generic_summary = _run_runner(
    runner_name   => 'rex-local-provider',
    scenario_path => $baseline_scenario,
    runs_dir      => File::Spec->catdir($generic_tmp, 'runs'),
    run_id        => 'generic',
  );
  is $generic_summary->{topology_provider_commands}, [],
    'generic-relay provider runner records no provider command results';
  ok !-d File::Spec->catdir($generic_tmp, 'runs', 'generic', 'logs', 'provider',),
    'generic-relay provider runner does not create provider logs';
}

my $cli_tmp         = tempdir(CLEANUP => 1);
my $cli_fake_rex    = _write_fake_rex($cli_tmp);
my $cli_rex_log     = File::Spec->catfile($cli_tmp, 'fake-rex.log');
my $cli_marker      = File::Spec->catfile($cli_tmp, 'relay.started');
my $cli_stop_marker = File::Spec->catfile($cli_tmp, 'relay.stopped');
my $cli_commands    = {
  start  => "printf start > '$cli_marker'",
  health => "test -f '$cli_marker'",
  stop   => "printf stop > '$cli_stop_marker'",
};
my $cli_scenario = File::Spec->catfile($cli_tmp, 'external.yml');
_write_yaml($cli_scenario, _external_scenario_yaml($cli_commands));
{
  local $ENV{OVERNET_BURNER_REX}          = $cli_fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $cli_rex_log;
  my $cli =
    `$^X $bin run --scenario $cli_scenario --runs-dir $cli_tmp/runs --run-id cli --runner rex-local-provider 2>&1`;
  is $?, 0, 'CLI run --runner rex-local-provider exits successfully';
  like $cli,
    qr{\Acompleted\ run:\ \Q$cli_tmp/runs/cli\E\nwrote\ report:\ \Q$cli_tmp/runs/cli/report.json\E\n?\z}xm,
    'CLI provider runner reports completed run directory and generated report';
}
my $cli_manifest = _read_json(File::Spec->catfile($cli_tmp, 'runs', 'cli', 'manifest.json'),);
is $cli_manifest->{runner}{name},      'rex-local-provider', 'CLI manifest records provider runner';
is $cli_manifest->{rex_bundle}{path},  'artifacts/rex',      'CLI manifest records Rex bundle';
is $cli_manifest->{lifecycle}{runner}, 'rex-local-provider', 'CLI manifest lifecycle records provider runner';
is [map { $_->{command_kind} } @{$cli_manifest->{lifecycle}{topology_provider_commands}}],
  [qw(start health stop)],
  'CLI manifest lifecycle records provider command results';
ok !exists $cli_manifest->{provider},           'CLI provider run avoids ambiguous provider field';
ok !exists $cli_manifest->{execution_provider}, 'CLI provider run avoids execution provider field';

subtest 'a health failure in process stops started relays and skips unstarted ones' => sub {
  my $tmp         = tempdir(CLEANUP => 1);
  my $fake_rex    = _write_fake_rex($tmp);
  my $stop_marker = File::Spec->catfile($tmp, 'relay.stopped');
  local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

  my $scenario_path = File::Spec->catfile($tmp, 'external.yml');
  _write_yaml(
    $scenario_path,
    _external_scenario_yaml(
      {
        start  => 'exit 0',
        health => 'echo health failed >&2; exit 42',
        stop   => "printf stop >> '$stop_marker'",
      },
      count => 2,
    ),
  );

  my $runner    = _load_provider_runner(scenario_path => $scenario_path, tmp => $tmp, run_id => 'health-fail');
  my $completed = eval { $runner->run_lifecycle; 1 };
  my $error     = $@;
  ok !$completed, 'the lifecycle fails when health fails';
  like $error, qr/provider\ command\ failed:\ relay-001\ health\ exited\ with\ status\ 42/mx,
    'the health failure reports the exit status';
  unlike $error, qr/cleanup\ failed/mx, 'the cleanup stop completes';

  is _read_file($stop_marker), 'stop', 'only the started relay is stopped during cleanup';

  my %fields = $runner->summary_fields;
  is [map {"$_->{actor_id}:$_->{command_kind}:$_->{status}"} @{$fields{topology_provider_commands}}],
    ['relay-001:start:completed', 'relay-001:health:failed', 'relay-001:stop:completed'],
    'the command results record the failed health and the cleanup stop';

  ok $runner->stop, 'a second stop after the attempted cleanup is a no-op';
  is scalar @{$fields{topology_provider_commands}}, 3, 'the repeated stop runs no further commands';

  ok $runner->cleanup_after_lifecycle_failure(failed_phase => 'start'),
    'cleanup after the stop has already run has nothing to do';
  $runner->{topology_provider_needs_stop} = 1;
  ok $runner->cleanup_after_lifecycle_failure(failed_phase => 'start'),
    'cleanup is not repeated once a stop was attempted';
};

subtest 'a failing cleanup stop is appended to the phase error in process' => sub {
  my $tmp      = tempdir(CLEANUP => 1);
  my $fake_rex = _write_fake_rex($tmp);
  local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

  my $scenario_path = File::Spec->catfile($tmp, 'external.yml');
  _write_yaml(
    $scenario_path,
    _external_scenario_yaml(
      {
        start  => 'exit 0',
        health => 'exit 42',
        stop   => 'echo stop failed >&2; exit 43',
      },
    ),
  );

  my $runner    = _load_provider_runner(scenario_path => $scenario_path, tmp => $tmp, run_id => 'cleanup-fail');
  my $completed = eval { $runner->run_lifecycle; 1 };
  my $error     = $@;
  ok !$completed, 'the lifecycle fails when health and cleanup stop both fail';
  like $error,
    qr/provider\ command\ failed:\ relay-001\ health.*;\ cleanup\ failed:
       .*provider\ command\ failed:\ relay-001\ stop\ exited\ with\ status\ 43/mxs,
    'the cleanup stop failure is appended to the health failure';

  my $fresh_runner =
    _load_provider_runner(scenario_path => $scenario_path, tmp => $tmp, run_id => 'nothing-started');
  $fresh_runner->prepare;
  ok $fresh_runner->cleanup_after_lifecycle_failure(failed_phase => 'start'),
    'cleanup before any relay started has nothing to stop';
  ok $fresh_runner->cleanup_after_lifecycle_failure(failed_phase => 'stop'),
    'cleanup after a failed stop phase does not stop again';

  $fresh_runner->{topology_provider_needs_stop} = 1;
  ok $fresh_runner->cleanup_after_lifecycle_failure(failed_phase => 'start'),
    'cleanup without a phase map still stops started relays';

  my $bare_runner =
    _load_provider_runner(scenario_path => $scenario_path, tmp => $tmp, run_id => 'bare-cleanup-fail');
  $bare_runner->prepare;
  $bare_runner->{topology_provider_started}{'relay-001'} = 1;
  $bare_runner->{topology_provider_needs_stop} = 1;
  my $cleaned = eval { $bare_runner->cleanup_after_lifecycle_failure(failed_phase => 'start'); 1 };
  my $bare_error = $@;
  ok !$cleaned, 'a cleanup without a phase map still reports a failed stop';
  like $bare_error, qr/provider\ command\ failed:\ relay-001\ stop/mx,
    'the phase-map-less cleanup failure names the stop command';
};

subtest 'provider start and stop skip incomplete relay descriptors' => sub {
  my $tmp      = tempdir(CLEANUP => 1);
  my $fake_rex = _write_fake_rex($tmp);
  local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

  my $scenario_path = File::Spec->catfile($tmp, 'external.yml');
  _write_yaml(
    $scenario_path,
    _external_scenario_yaml({start => 'exit 0', health => 'exit 0', stop => 'exit 0'}),
  );

  my $runner = _load_provider_runner(scenario_path => $scenario_path, tmp => $tmp, run_id => 'doctored');
  $runner->prepare;

  my $descriptor_path =
    File::Spec->catfile($runner->{run_dir}, 'artifacts', 'rex', 'topology-provider.json');
  my $full_lifecycle = {
    start  => {command => 'exit 0'},
    health => {command => 'exit 0'},
    stop   => {command => 'exit 0'},
  };
  _write_yaml(
    $descriptor_path,
    JSON->new->canonical(1)->encode(
      {
        relays => [
          {lifecycle => $full_lifecycle},
          {actor_id  => 'relay-partial', lifecycle => {start => {command => 'exit 0'}, stop => {command => 'exit 0'}}},
          {actor_id  => 'relay-001',     lifecycle => $full_lifecycle},
        ],
      },
    ),
  );

  ok $runner->start, 'start runs with incomplete descriptors present';
  ok $runner->stop,  'stop runs with incomplete descriptors present';

  my %fields = $runner->summary_fields;
  is [map {"$_->{actor_id}:$_->{command_kind}"} @{$fields{topology_provider_commands}}],
    ['relay-001:start', 'relay-001:health', 'relay-001:stop'],
    'only complete descriptors with actor ids run provider commands';

  _write_yaml($descriptor_path, '{}');
  is [$runner->_topology_provider_command_relays], [], 'a descriptor without relays yields no command relays';
};

subtest 'direct provider command edges' => sub {
  my $tmp      = tempdir(CLEANUP => 1);
  my $fake_rex = _write_fake_rex($tmp);
  local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

  my $scenario_path = File::Spec->catfile($tmp, 'external.yml');
  _write_yaml(
    $scenario_path,
    _external_scenario_yaml({start => 'exit 0', health => 'exit 0', stop => 'exit 0'}),
  );
  my $runner = _load_provider_runner(scenario_path => $scenario_path, tmp => $tmp, run_id => 'direct');

  for my $case (
    [{kind     => 'start', command => 'exit 0'},      'actor_id',              'requires an actor id'],
    [{actor_id => 'relay-001', command => 'exit 0'},  'provider command kind', 'requires a command kind'],
    [{actor_id => 'relay-001', kind    => 'start'},   'provider command',      'requires a command'],
  ) {
    my ($bad_args, $field, $label) = @{$case};
    my $ran       = eval { $runner->_run_topology_provider_command(%{$bad_args}); 1 };
    my $bad_error = $@;
    ok !$ran, "a provider command $label";
    like $bad_error, qr/\Q$field\E\ is\ required/mx, "a provider command $label with a diagnostic";
  }

  ok(
    $runner->_run_topology_provider_command(
      actor_id  => 'relay-001',
      kind      => 'health',
      command   => 'exit 0',
      phase     => 'observe',
      log_label => 'custom-health',
    ),
    'a provider command accepts an explicit phase and log label',
  );
  ok -e File::Spec->catfile($runner->{run_dir}, 'logs', 'provider', 'custom-health.stdout'),
    'the log label names the captured output';
  my $events = _read_jsonl(File::Spec->catfile($runner->{run_dir}, 'logs', 'runner.jsonl'));
  is $events->[-1]{phase}, 'observe', 'the explicit phase is recorded on the event';

  my $signaled = eval {
    $runner->_run_topology_provider_command(
      actor_id => 'relay-001',
      kind     => 'health',
      command  => 'kill -TERM $$',
    );
    1;
  };
  my $signal_error = $@;
  ok !$signaled, 'a signal-ended provider command fails';
  like $signal_error, qr/relay-001\ health\ ended\ by\ a\ signal\ or\ transport\ failure/mx,
    'the signal outcome is reported without an exit status';

  ok !exists $runner->{topology_provider_commands}[-1]{exit_code},
    'a signal-ended provider command records no exit code';

  {
    # A lifecycle command that never returns must not hang the run: the bounded
    # wait kills it and the command is reported as a timeout.
    local $ENV{OVERNET_BURNER_LIFECYCLE_TIMEOUT} = 1;
    my $start = time;
    my $hung  = eval {
      $runner->_run_topology_provider_command(actor_id => 'relay-001', kind => 'start', command => 'sleep 30');
      1;
    };
    my $timeout_error = $@;
    my $elapsed       = time - $start;
    ok !$hung, 'a hung provider command fails instead of hanging the run';
    like $timeout_error, qr/relay-001\ start\ timed\ out\ after\ 1s/mx,
      'a timed-out provider command is reported as a timeout';
    ok $elapsed < 15, "the hung command is killed near its timeout (took ${elapsed}s)";
  }
};

done_testing;

sub _load_provider_runner {
  my (%args) = @_;

  my $scenario = Overnet::Burner::Config->load_file($args{scenario_path});
  my $ledger   = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $args{scenario_path},
    runs_dir      => File::Spec->catdir($args{tmp}, 'runs'),
    run_id        => $args{run_id},
    now           => sub {'2026-06-27T14:00:00Z'},
    host_facts    => {hostname => 'builder-host', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  my $plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});

  return Overnet::Burner::Runner->load(
    name    => 'rex-local-provider',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );
}

sub _run_runner {
  my (%args) = @_;

  my $scenario = Overnet::Burner::Config->load_file($args{scenario_path});
  my $ledger   = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $args{scenario_path},
    runs_dir      => $args{runs_dir},
    run_id        => $args{run_id},
    now           => sub {'2026-06-27T14:00:00Z'},
    host_facts    => {
      hostname => 'builder-host',
      os       => 'linux',
      arch     => 'x86_64',
    },
    repo_sha    => 'abc123',
    rex_version => undef,
  );
  my $plan   = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});
  my $runner = Overnet::Burner::Runner->load(
    name    => $args{runner_name},
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );

  return $runner->run_lifecycle;
}

sub _external_scenario_yaml {
  my ($command, %options) = @_;

  my $count = $options{count} || 1;

  return <<"YAML";
run:
  name: external-command-relay
  duration: 60
  seed: 24680

topology:
  relays:
    count: $count
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

sub _write_fake_rex {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-rex');

  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} <<'PERL';
#!/usr/bin/env perl
use strictures 2;

my $log = $ENV{OVERNET_BURNER_TEST_REX_LOG}
    or die "OVERNET_BURNER_TEST_REX_LOG is required\n";
open my $fh, '>>', $log or die "open $log: $!";
print {$fh} join("\0", @ARGV), "\n";
close $fh or die "close $log: $!";
my $fail_task = $ENV{OVERNET_BURNER_TEST_REX_FAIL_TASK};
if (defined $fail_task && @ARGV && $ARGV[-1] eq $fail_task) {
    print STDERR "fake rex failed task: $fail_task\n";
    exit 42;
}
print "fake rex: @ARGV\n";
exit 0;
PERL
  close $fh or die "close $path: $!";
  chmod 0755, $path or die "chmod $path: $!";

  return $path;
}

sub _write_yaml {
  my ($path, $yaml) = @_;

  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $yaml;
  close $fh or die "close $path: $!";
  return;
}

sub _read_json {
  my ($path) = @_;

  return JSON::decode_json(_read_file($path));
}

sub _read_jsonl {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  my @records = map { JSON::decode_json($_) } <$fh>;
  close $fh or die "close $path: $!";
  return \@records;
}

sub _read_lines {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  chomp(my @lines = <$fh>);
  close $fh or die "close $path: $!";
  return @lines;
}

sub _read_file {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  return <$fh>;
}
