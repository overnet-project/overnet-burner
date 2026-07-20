use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use JSON ();
use Symbol qw(gensym);
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Generator;
use Overnet::Burner::Plan;

my $repo     = "$FindBin::Bin/..";
my $bin      = "$repo/bin/overnet-burner";
my $scenario = "$repo/scenarios/single-relay-baseline.yml";

my $usage = `$^X $bin 2>&1`;
is $? >> 8, 2, 'invoking with no command prints usage and exits nonzero';
like $usage, qr/--runner\ .*rex-local-workers/mx, 'usage lists the rex-local-workers runner needed for a real run';
like $usage, qr/overnet-burner\ worker/mx,        'usage lists the worker subcommand';

my $worker_no_input = `$^X $bin worker 2>&1`;
is $? >> 8, 2, 'worker command exits nonzero without input';
like $worker_no_input, qr/OVERNET_BURNER_WORKER_INPUT/mx, 'worker command reports the missing input document';

my $validate = `$^X $bin validate --scenario $scenario 2>&1`;
is $?, 0, 'validate command exits successfully';
like $validate, qr/\Avalid\ scenario:\ single-relay-baseline\n?\z/xm, 'validate command reports scenario name';

my $plan = `$^X $bin plan --scenario $scenario 2>&1`;
is $?, 0, 'plan command exits successfully';
my $expected_plan =
  Overnet::Burner::Plan->canonical_json(Overnet::Burner::Plan->build(Overnet::Burner::Config->load_file($scenario)),);
is $plan, $expected_plan, 'plan command prints canonical plan JSON';
my $decoded_plan = JSON::decode_json($plan);
is $decoded_plan->{run}{name},               'single-relay-baseline', 'plan command output records run name';
is $decoded_plan->{relays}[0]{id},           'relay-001',             'plan command output records relay actor';
is $decoded_plan->{topology_provider}{name}, 'generic-relay',         'plan command output records topology provider';
ok !exists $decoded_plan->{provider}, 'plan command output does not use ambiguous provider field';

my $tmp    = tempdir(CLEANUP => 1);
my $run_id = 'cli-run-001';
my $init   = `$^X $bin init-run --scenario $scenario --runs-dir $tmp --run-id $run_id 2>&1`;
is $?, 0, 'init-run command exits successfully';
like $init, qr{\Acreated\ run:\ \Q$tmp/$run_id\E\n?\z}xm, 'init-run command reports run directory';

my $manifest_path = File::Spec->catfile($tmp, $run_id, 'manifest.json');
ok -e $manifest_path, 'init-run writes manifest';

my $manifest = _read_json($manifest_path);

is $manifest->{run_id},                  $run_id,                 'CLI manifest records run id';
is $manifest->{scenario}{name},          'single-relay-baseline', 'CLI manifest records scenario name';
is $manifest->{topology_provider}{name}, 'generic-relay',         'CLI init-run manifest records topology provider';
ok !defined $manifest->{runner}{name},      'CLI init-run manifest leaves runner unset';
ok !exists $manifest->{provider},           'CLI init-run manifest does not use ambiguous provider field';
ok !exists $manifest->{execution_provider}, 'CLI init-run manifest does not use execution provider field';

my $render_tmp = tempdir(CLEANUP => 1);
my $render_id  = 'cli-rex-render-001';
my $render     = `$^X $bin render-rex --scenario $scenario --runs-dir $render_tmp --run-id $render_id 2>&1`;
is $?, 0, 'render-rex command exits successfully';
like $render, qr{\Arendered\ Rex\ bundle:\ \Q$render_tmp/$render_id/artifacts/rex\E\n?\z}xm,
  'render-rex command reports bundle directory';

my $render_run_dir = File::Spec->catdir($render_tmp, $render_id);
ok -e File::Spec->catfile($render_run_dir, 'plan.json'), 'render-rex creates a deterministic plan first';
ok -e File::Spec->catfile($render_run_dir, 'artifacts', 'rex', 'Rexfile'), 'render-rex writes Rexfile artifact';
ok -e File::Spec->catfile($render_run_dir, 'artifacts', 'rex', 'inventory', 'hosts.json'),
  'render-rex writes inventory artifact';

my $render_manifest = _read_json(File::Spec->catfile($render_run_dir, 'manifest.json'));
is $render_manifest->{topology_provider}{name}, 'generic-relay', 'render-rex manifest keeps topology provider';
ok !defined $render_manifest->{runner}{name}, 'render-rex does not select or run a runner';
ok !exists $render_manifest->{status},        'render-rex does not mark lifecycle execution status';
is $render_manifest->{rex_bundle}{path},     'artifacts/rex', 'render-rex manifest records bundle path';
is $render_manifest->{rex_bundle}{rendered}, 1,               'render-rex manifest records rendered bundle';
is $render_manifest->{rex_bundle}{remote_execution}, 'not_performed',
  'render-rex manifest does not imply remote execution';
ok $render_manifest->{rex_bundle}{rendered_at},    'render-rex manifest records render timestamp';
ok !exists $render_manifest->{provider},           'render-rex manifest does not use ambiguous provider field';
ok !exists $render_manifest->{execution_provider}, 'render-rex manifest does not use execution provider field';
ok !-e File::Spec->catfile($render_run_dir, 'logs', 'runner.jsonl'), 'render-rex does not write runner lifecycle logs';

my $render_missing = `$^X $bin render-rex --runs-dir $render_tmp --run-id missing-scenario 2>&1`;
is $? >> 8, 2, 'render-rex rejects missing scenario';
like $render_missing, qr/--scenario\ is\ required/mx, 'render-rex reports missing scenario';
ok !-d File::Spec->catdir($render_tmp, 'missing-scenario'), 'render-rex missing scenario does not create run directory';

my $bad_tmp  = tempdir(CLEANUP => 1);
my $bad_init = `$^X $bin init-run --scenario $scenario --runs-dir $bad_tmp/runs --run-id ../escape 2>&1`;
is $? >> 8, 2, 'init-run rejects invalid run id';
like $bad_init, qr/\binvalid\ run_id\b/mx, 'init-run reports invalid run id';
ok !-d File::Spec->catdir($bad_tmp, 'escape'), 'init-run does not write outside runs dir for invalid run id';

my $run_tmp        = tempdir(CLEANUP => 1);
my $run_command_id = 'cli-run-002';
my $run = `$^X $bin run --scenario $scenario --runs-dir $run_tmp --run-id $run_command_id --runner noop 2>&1`;
is $?, 0, 'run command exits successfully';
like $run,
  qr{\Acompleted\ run:\ \Q$run_tmp/$run_command_id\E\nwrote\ report:\ \Q$run_tmp/$run_command_id/report.json\E\n?\z}xm,
  'run command reports completed run directory and generated report';

my $run_manifest_path = File::Spec->catfile($run_tmp, $run_command_id, 'manifest.json');
my $run_manifest      = _read_json($run_manifest_path);
my $run_report_path   = File::Spec->catfile($run_tmp, $run_command_id, 'report.json');

is $run_manifest->{status},                  'completed',     'run manifest records completion';
is $run_manifest->{topology_provider}{name}, 'generic-relay', 'run manifest keeps topology provider';
is $run_manifest->{runner}{name},            'noop',          'run manifest records selected runner';
ok !exists $run_manifest->{provider},           'run manifest does not use ambiguous provider field';
ok !exists $run_manifest->{execution_provider}, 'run manifest does not use execution provider field';
ok $run_manifest->{timestamps}{started_at},     'run manifest records start time';
ok $run_manifest->{timestamps}{finished_at},    'run manifest records finish time';
is $run_manifest->{lifecycle}{runner}, 'noop', 'run manifest records lifecycle summary';
is $run_manifest->{lifecycle}{phases},
  {
  prepare => 'completed',
  start   => 'completed',
  observe => 'completed',
  stop    => 'completed',
  collect => 'completed',
  },
  'run manifest records lifecycle phases';
is $run_manifest->{lifecycle}{actor_counts}{total}, 5, 'run manifest records deterministic actor total';
ok -e $run_report_path, 'run command writes report.json automatically';
my $run_report = _read_json($run_report_path);
is $run_report->{run}{status},  'completed',    'automatic report records completed status';
is $run_report->{run}{verdict}, 'smoke_passed', 'automatic report records the run verdict';

my $run_log_path = File::Spec->catfile($run_tmp, $run_command_id, 'logs', 'runner.jsonl');
open my $run_log_fh, '<', $run_log_path or die "open $run_log_path: $!";
my @run_events = map { JSON::decode_json($_) } <$run_log_fh>;
is scalar @run_events, 10, 'run command records runner lifecycle events';
is [map { $_->{phase} } grep { $_->{status} eq 'started' } @run_events],
  [qw(prepare start observe stop collect)],
  'run command records all lifecycle phases';

# compare command: diff two run reports for regressions.
my ($same_exit, $same_out) = _capture_command($^X, $bin, 'compare', $run_report_path, $run_report_path);
is $same_exit, 0, 'comparing a report against itself exits zero';
like $same_out, qr/comparing\ /mx,   'the comparison names the runs';
like $same_out, qr/no\ regression/mx, 'an identical comparison reports no regression';

my $candidate_report = File::Spec->catfile($run_tmp, 'candidate.json');
open my $candidate_fh, '>', $candidate_report or die "open $candidate_report: $!";
print {$candidate_fh}
  '{"run":{"id":"cand","verdict":"performance_failed","result_class":"performance"},"thresholds":[],"metrics":{"operations":{}}}'
  or die "print: $!";
close $candidate_fh or die "close: $!";

my ($regress_exit, $regress_out) = _capture_command($^X, $bin, 'compare', $run_report_path, $candidate_report);
is $regress_exit, 1, 'a regression makes the compare command exit nonzero';
like $regress_out, qr/verdict:\ smoke_passed\ ->\ performance_failed/mx, 'the verdict change is shown';
like $regress_out, qr/result:\ REGRESSED/mx, 'the regression is reported';

my ($allow_exit) = _capture_command($^X, $bin, 'compare', '--allow-regression', $run_report_path, $candidate_report);
is $allow_exit, 0, '--allow-regression tolerates a regression';

my ($json_exit, $json_out) = _capture_command($^X, $bin, 'compare', '--json', $run_report_path, $run_report_path);
is $json_exit, 0, 'a json comparison of identical reports exits zero';
is JSON::decode_json($json_out)->{compare_version}, 1, 'the json comparison is versioned';

my ($compare_bad_exit, undef, $compare_bad_err) = _capture_command($^X, $bin, 'compare', $run_report_path);
isnt $compare_bad_exit, 0, 'compare requires both a baseline and a candidate';
like $compare_bad_err, qr/requires\ a\ baseline\ and\ a\ candidate/mx, 'the missing-operand error explains itself';

# A failed run must present a clean, operator-facing error: the useful message
# without the Carp "at bin/overnet-burner line N" developer noise, and that
# noise must not leak into the persisted report either.
my $fail_tmp      = tempdir(CLEANUP => 1);
my $fail_scenario = File::Spec->catfile($fail_tmp, 'fail-health.yml');
open my $fail_fh, '>', $fail_scenario or die "open $fail_scenario: $!";
print {$fail_fh} <<'YAML' or die "print: $!";
run:
  name: fail-health
  duration: 2
  seed: 1
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "true"
      health: "exit 1"
      stop: "true"
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 1
provision:
  workers:
    how: local
YAML
close $fail_fh or die "close: $!";

my ($fail_exit, undef, $fail_err) = _capture_command(
  $^X, $bin, 'run',
  '--scenario', $fail_scenario,
  '--runs-dir', File::Spec->catdir($fail_tmp, 'runs'),
  '--run-id',   'fail-run',
  '--runner',   'rex-local-workers',
);
isnt $fail_exit, 0, 'a run whose relay never becomes healthy fails';
like $fail_err, qr/provider\ command\ failed:\ relay-001\ health/mx, 'the failure names the failing provider command';
unlike $fail_err, qr/at\ \S*bin\S*overnet-burner\ line\ \d+/mx, 'the operator error omits Carp source-line noise';

my $fail_report = _read_json(File::Spec->catfile($fail_tmp, 'runs', 'fail-run', 'report.json'));
unlike $fail_report->{human_summary}{important_notes}[0], qr/\ line\ \d+/mx,
  'the persisted report summary is free of source-line noise';

my $verbose_tmp = tempdir(CLEANUP => 1);
my $verbose_id  = 'cli-run-verbose';
my ($verbose_exit, $verbose_stdout, $verbose_stderr) = _capture_command(
  $^X, $bin, 'run',
  '--scenario', $scenario,
  '--runs-dir', $verbose_tmp,
  '--run-id',   $verbose_id,
  '--runner',   'noop',
  '--verbose',
);
is $verbose_exit, 0, 'run --verbose exits successfully' or diag($verbose_stderr);
is $verbose_stdout,
  "completed run: $verbose_tmp/$verbose_id\nwrote report: $verbose_tmp/$verbose_id/report.json\n",
  'run --verbose keeps normal completion output on stdout';
like $verbose_stderr, qr{^overnet-burner:\ created\ run:\ \Q$verbose_tmp/$verbose_id\E$}m,
  'run --verbose reports the run directory on stderr';
like $verbose_stderr, qr/^overnet-burner:\ runner\ noop\ phase\ prepare\ started\ \(actors=5\)$/m,
  'run --verbose reports lifecycle phase start on stderr';
like $verbose_stderr, qr/^overnet-burner:\ runner\ noop\ phase\ collect\ completed\ \(actors=5\)$/m,
  'run --verbose reports lifecycle phase completion on stderr';
like $verbose_stderr, qr{^overnet-burner:\ writing\ report:\ \Q$verbose_tmp/$verbose_id/report.json\E$}m,
  'run --verbose reports report generation on stderr';

my $failed_tmp = tempdir(CLEANUP => 1);
my $failed_id  = 'cli-run-failed';
my $failed     = `$^X $bin run --scenario $scenario --runs-dir $failed_tmp --run-id $failed_id --runner missing 2>&1`;
is $? >> 8, 2, 'run command fails for unknown runner';
like $failed, qr/unknown\ runner:\ missing/mx, 'run command reports runner error';

my $failed_manifest_path = File::Spec->catfile($failed_tmp, $failed_id, 'manifest.json');
my $failed_manifest      = _read_json($failed_manifest_path);

is $failed_manifest->{status},                  'failed',        'failed run manifest records failed status';
is $failed_manifest->{topology_provider}{name}, 'generic-relay', 'failed run manifest keeps topology provider';
is $failed_manifest->{runner}{name},            'missing',       'failed run manifest records selected runner';
ok !exists $failed_manifest->{provider},           'failed run manifest does not use ambiguous provider field';
ok !exists $failed_manifest->{execution_provider}, 'failed run manifest does not use execution provider field';
like $failed_manifest->{error}, qr/unknown\ runner:\ missing/mx, 'failed run manifest records error';
ok $failed_manifest->{timestamps}{finished_at}, 'failed run manifest records finish time';
my $failed_report = _read_json(File::Spec->catfile($failed_tmp, $failed_id, 'report.json'));
is $failed_report->{run}{status},       'failed',               'failed run writes report.json automatically';
is $failed_report->{run}{verdict},      'orchestration_failed', 'failed automatic report records failure verdict';
is $failed_report->{execution}{runner}, 'missing',              'failed automatic report records requested runner';

subtest 'generate emits a deterministic, valid scenario' => sub {
  my $first = `$^X $bin generate --seed 42 2>&1`;
  is $?, 0, 'generate exits successfully';
  my $second = `$^X $bin generate --seed 42 2>&1`;
  is $first, $second, 'generate is deterministic for a fixed seed';
  like $first, qr/^\ \ seed:\ 42$/mx,          'generated scenario carries the seed';
  like $first, qr/provider:\ generic-relay/mx, 'generated scenario names the topology provider';

  my $managed_profile = "$repo/profiles/local-containers-smoke.yml";
  my $managed         = `$^X $bin generate --seed 42 --profile $managed_profile 2>&1`;
  is $?, 0, 'generate with the managed local-containers profile exits successfully' or diag($managed);
  like $managed,   qr/kind:\ local-containers/mx, 'generated managed scenario carries the managed environment';
  unlike $managed, qr/127[.]0[.]0[.]1/mx, 'generated managed scenario does not point at a pre-existing local relay';

  my $gen_tmp = tempdir(CLEANUP => 1);
  my $out     = File::Spec->catfile($gen_tmp, 'scenario.yml');
  my $written = `$^X $bin generate --seed 42 --out $out 2>&1`;
  is $?, 0, 'generate --out exits successfully';
  like $written, qr{\Agenerated\ scenario:\ \Q$out\E\n?\z}xm, 'generate --out reports the file';
  my $loaded = Overnet::Burner::Config->load_file($out);
  is $loaded->{run}{seed}, 42, 'the written scenario loads and validates';

  my $no_seed = `$^X $bin generate 2>&1`;
  is $? >> 8, 2, 'generate without a seed exits nonzero';
  like $no_seed, qr/--seed\ is\ required/mx, 'generate reports the missing seed';
};

subtest 'generate-profile emits a deterministic, valid profile' => sub {
  my $template = "$repo/profile-templates/local-containers.yml";
  my $first    = `$^X $bin generate-profile --profile-seed 1001 --profile-template $template 2>&1`;
  is $?, 0, 'generate-profile exits successfully' or diag($first);
  my $second = `$^X $bin generate-profile --profile-seed 1001 --profile-template $template 2>&1`;
  is $first, $second, 'generate-profile is deterministic for a fixed profile seed';
  like $first, qr/kind:\ local-containers/mx, 'generated profile carries the managed environment';

  my $tmp = tempdir(CLEANUP => 1);
  my $out = File::Spec->catfile($tmp, 'profile.yml');
  my $written =
    `$^X $bin generate-profile --profile-seed 1001 --profile-template $template --out $out 2>&1`;
  is $?, 0, 'generate-profile --out exits successfully' or diag($written);
  like $written, qr{\Agenerated\ profile:\ \Q$out\E\n?\z}xm, 'generate-profile --out reports the file';
  my $loaded = Overnet::Burner::Generator->load_profile($out);
  is $loaded->{environment}{kind}, 'local-containers', 'the written generated profile loads and validates';

  my $no_seed = `$^X $bin generate-profile --profile-template $template 2>&1`;
  is $? >> 8, 2, 'generate-profile rejects missing profile seed';
  like $no_seed, qr/--profile-seed\ is\ required/mx, 'generate-profile reports the missing profile seed';

  my $no_template = `$^X $bin generate-profile --profile-seed 1001 2>&1`;
  is $? >> 8, 2, 'generate-profile rejects missing profile template';
  like $no_template, qr/--profile-template\ is\ required/mx, 'generate-profile reports the missing template';
};

subtest 'run --random generates, records, and runs a scenario' => sub {
  my $random_tmp = tempdir(CLEANUP => 1);
  my $run_output = `$^X $bin run --random --seed 7 --runs-dir $random_tmp --run-id random-001 --runner noop 2>&1`;
  is $?, 0, 'run --random exits successfully' or diag($run_output);
  like $run_output, qr{wrote\ report:\ \Q$random_tmp/random-001/report.json\E}mx,
    'run --random reports automatic report generation';

  my $manifest = _read_json(File::Spec->catfile($random_tmp, 'random-001', 'manifest.json'));
  is $manifest->{status},         'completed', 'random run completes';
  is $manifest->{scenario}{name}, 'random-7',  'the ledger records the generated scenario by seed';
  is $manifest->{seed},           7,           'the manifest records the generation seed';

  ok -e File::Spec->catfile($random_tmp, 'random-001', 'scenario.yml'),
    'the generated scenario is recorded in the run ledger for repro';
  ok -e File::Spec->catfile($random_tmp, 'random-001', 'report.json'), 'run --random writes report.json automatically';

  my $managed_tmp = tempdir(CLEANUP => 1);
  my $managed_output =
`$^X $bin run --random --seed 7 --profile $repo/profiles/local-containers-smoke.yml --runs-dir $managed_tmp --run-id random-managed-001 --runner noop 2>&1`;
  is $?, 0, 'run --random works with the managed local-containers profile' or diag($managed_output);
  my $managed_manifest = _read_json(File::Spec->catfile($managed_tmp, 'random-managed-001', 'manifest.json'));
  is $managed_manifest->{topology_provider}{name}, 'external-command',
    'the managed random run records the synthesized relay provider';
  is $managed_manifest->{seed}, 7, 'the managed random run records the generation seed';

  my $missing_seed = `$^X $bin run --random --runs-dir $random_tmp --run-id random-noseed --runner noop 2>&1`;
  is $? >> 8, 2, 'run --random without a seed exits nonzero';
  like $missing_seed, qr/--seed\ is\ required\ with\ --random/mx, 'run --random reports the missing seed';

  my $both = `$^X $bin run --random --seed 7 --scenario $scenario --runner noop 2>&1`;
  is $? >> 8, 2, 'run rejects --random combined with --scenario';
  like $both, qr/--scenario\ cannot\ be\ combined\ with\ --random/mx, 'run reports the conflicting flags';
};

subtest 'run supports explicit random scenario and profile layers' => sub {
  my $profile = "$repo/profiles/local-containers-smoke.yml";
  my $template = "$repo/profile-templates/local-containers.yml";

  my $scenario_tmp = tempdir(CLEANUP => 1);
  my $scenario_output =
`$^X $bin run --random-scenario --scenario-seed 7 --profile $profile --runs-dir $scenario_tmp --run-id random-scenario-001 --runner noop 2>&1`;
  is $?, 0, 'run --random-scenario exits successfully' or diag($scenario_output);
  my $scenario_manifest = _read_json(File::Spec->catfile($scenario_tmp, 'random-scenario-001', 'manifest.json'));
  is $scenario_manifest->{scenario}{name}, 'random-7', 'explicit random scenario run records the generated scenario';
  is $scenario_manifest->{seed}, 7, 'explicit random scenario run records the scenario seed';
  ok -e File::Spec->catfile($scenario_tmp, 'random-scenario-001', 'scenario.yml'),
    'explicit random scenario run records scenario.yml';

  my $profile_tmp = tempdir(CLEANUP => 1);
  my $profile_output =
`$^X $bin run --random-profile --profile-seed 1001 --profile-template $template --random-scenario --scenario-seed 7 --runs-dir $profile_tmp --run-id random-profile-001 --runner noop 2>&1`;
  is $?, 0, 'run can generate a profile and then a scenario' or diag($profile_output);
  my $run_dir = File::Spec->catdir($profile_tmp, 'random-profile-001');
  ok -e File::Spec->catfile($run_dir, 'profile-template.yml'), 'random-profile run records the template';
  ok -e File::Spec->catfile($run_dir, 'profile.generated.yml'), 'random-profile run records the generated profile';
  ok -e File::Spec->catfile($run_dir, 'scenario.yml'), 'random-profile run records the generated scenario';
  my $generated_profile = Overnet::Burner::Generator->load_profile(File::Spec->catfile($run_dir, 'profile.generated.yml'));
  is $generated_profile->{environment}{kind}, 'local-containers', 'ledger generated profile is loadable';
  my $report      = _read_json(File::Spec->catfile($run_dir, 'report.json'));
  my %artifact_id = map { $_->{id} => $_ } @{$report->{artifacts}};
  ok $artifact_id{profile_template}, 'random-profile report records the profile template artifact';
  ok $artifact_id{generated_profile}, 'random-profile report records the generated profile artifact';

  my $missing_scenario_seed =
    `$^X $bin run --random-scenario --profile $profile --runs-dir $scenario_tmp --run-id missing-scenario-seed --runner noop 2>&1`;
  is $? >> 8, 2, 'run --random-scenario rejects missing scenario seed';
  like $missing_scenario_seed, qr/--scenario-seed\ is\ required/mx,
    'run --random-scenario reports the missing scenario seed';

  my $profile_conflict =
`$^X $bin run --random-profile --profile-seed 1 --profile-template $template --profile $profile --random-scenario --scenario-seed 7 --runner noop 2>&1`;
  is $? >> 8, 2, 'run rejects --profile with --random-profile';
  like $profile_conflict, qr/--profile\ cannot\ be\ combined\ with\ --random-profile/mx,
    'run reports profile conflict';

  my $template_without_random_profile =
    `$^X $bin run --random-scenario --scenario-seed 7 --profile-template $template --runner noop 2>&1`;
  is $? >> 8, 2, 'run rejects profile template without random profile';
  like $template_without_random_profile, qr/--profile-template\ requires\ --random-profile/mx,
    'run reports stray profile template';

  my $random_profile_without_scenario =
    `$^X $bin run --random-profile --profile-seed 1 --profile-template $template --runner noop 2>&1`;
  is $? >> 8, 2, 'run rejects random profile without random scenario';
  like $random_profile_without_scenario, qr/--random-profile\ requires\ --random-scenario/mx,
    'run reports missing random scenario layer';
};

done_testing;

sub _read_json {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  return JSON::decode_json(<$fh>);
}

sub _capture_command {
  my @command = @_;

  my $stderr = gensym();
  my $pid    = open3(my $stdin, my $stdout, $stderr, @command);
  close $stdin or die "close stdin: $!";

  local $/ = undef;
  my $stdout_text = <$stdout>;
  my $stderr_text = <$stderr>;

  close $stdout or die "close stdout: $!";
  close $stderr or die "close stderr: $!";
  waitpid $pid, 0;

  return ($? >> 8, $stdout_text // q{}, $stderr_text // q{});
}
