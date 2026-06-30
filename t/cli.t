use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;

my $repo     = "$FindBin::Bin/..";
my $bin      = "$repo/bin/overnet-burner";
my $scenario = "$repo/scenarios/single-relay-baseline.yml";

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
like $run, qr{\Acompleted\ run:\ \Q$run_tmp/$run_command_id\E\n?\z}xm, 'run command reports completed run directory';

my $run_manifest_path = File::Spec->catfile($run_tmp, $run_command_id, 'manifest.json');
my $run_manifest      = _read_json($run_manifest_path);

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

my $run_log_path = File::Spec->catfile($run_tmp, $run_command_id, 'logs', 'runner.jsonl');
open my $run_log_fh, '<', $run_log_path or die "open $run_log_path: $!";
my @run_events = map { JSON::decode_json($_) } <$run_log_fh>;
is scalar @run_events, 10, 'run command records runner lifecycle events';
is [map { $_->{phase} } grep { $_->{status} eq 'started' } @run_events],
  [qw(prepare start observe stop collect)],
  'run command records all lifecycle phases';

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

done_testing;

sub _read_json {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  return JSON::decode_json(<$fh>);
}
