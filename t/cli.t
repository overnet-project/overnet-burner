use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP qw(decode_json);
use Test::More;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;

my $repo = "$FindBin::Bin/..";
my $bin = "$repo/bin/overnet-burner";
my $scenario = "$repo/scenarios/single-relay-baseline.yml";

my $validate = `$^X $bin validate --scenario $scenario 2>&1`;
is $?, 0, 'validate command exits successfully';
like $validate, qr/^valid scenario: single-relay-baseline$/m,
    'validate command reports scenario name';

my $plan = `$^X $bin plan --scenario $scenario 2>&1`;
is $?, 0, 'plan command exits successfully';
my $expected_plan = Overnet::Burner::Plan->canonical_json(
    Overnet::Burner::Plan->build(Overnet::Burner::Config->load_file($scenario)),
);
is $plan, $expected_plan, 'plan command prints canonical plan JSON';
my $decoded_plan = decode_json($plan);
is $decoded_plan->{run}{name}, 'single-relay-baseline',
    'plan command output records run name';
is $decoded_plan->{relays}[0]{id}, 'relay-001',
    'plan command output records relay actor';

my $tmp = tempdir(CLEANUP => 1);
my $run_id = 'cli-run-001';
my $init = `$^X $bin init-run --scenario $scenario --runs-dir $tmp --run-id $run_id 2>&1`;
is $?, 0, 'init-run command exits successfully';
like $init, qr{^created run: \Q$tmp/$run_id\E$}m,
    'init-run command reports run directory';

my $manifest_path = File::Spec->catfile($tmp, $run_id, 'manifest.json');
ok -e $manifest_path, 'init-run writes manifest';

my $manifest = _read_json($manifest_path);

is $manifest->{run_id}, $run_id, 'CLI manifest records run id';
is $manifest->{scenario}{name}, 'single-relay-baseline',
    'CLI manifest records scenario name';
is $manifest->{topology_provider}{name}, 'generic-relay',
    'CLI init-run manifest records topology provider';
ok !defined $manifest->{execution_provider}{name},
    'CLI init-run manifest leaves execution provider unset';
ok !exists $manifest->{provider},
    'CLI init-run manifest does not use ambiguous provider field';

my $bad_tmp = tempdir(CLEANUP => 1);
my $bad_init = `$^X $bin init-run --scenario $scenario --runs-dir $bad_tmp/runs --run-id ../escape 2>&1`;
is $? >> 8, 2, 'init-run rejects invalid run id';
like $bad_init, qr/\binvalid run_id\b/, 'init-run reports invalid run id';
ok !-d File::Spec->catdir($bad_tmp, 'escape'),
    'init-run does not write outside runs dir for invalid run id';

my $run_tmp = tempdir(CLEANUP => 1);
my $run_command_id = 'cli-run-002';
my $run = `$^X $bin run --scenario $scenario --runs-dir $run_tmp --run-id $run_command_id --provider noop 2>&1`;
is $?, 0, 'run command exits successfully';
like $run, qr{^completed run: \Q$run_tmp/$run_command_id\E$}m,
    'run command reports completed run directory';

my $run_manifest_path = File::Spec->catfile($run_tmp, $run_command_id, 'manifest.json');
my $run_manifest = _read_json($run_manifest_path);

is $run_manifest->{status}, 'completed', 'run manifest records completion';
is $run_manifest->{topology_provider}{name}, 'generic-relay',
    'run manifest keeps topology provider';
is $run_manifest->{execution_provider}{name}, 'noop',
    'run manifest records selected execution provider';
ok !exists $run_manifest->{provider},
    'run manifest does not use ambiguous provider field';
ok $run_manifest->{timestamps}{started_at}, 'run manifest records start time';
ok $run_manifest->{timestamps}{finished_at}, 'run manifest records finish time';
is $run_manifest->{lifecycle}{provider}, 'noop',
    'run manifest records lifecycle summary';
is_deeply $run_manifest->{lifecycle}{phases},
    {
    prepare => 'completed',
    start   => 'completed',
    observe => 'completed',
    stop    => 'completed',
    collect => 'completed',
    },
    'run manifest records lifecycle phases';
is $run_manifest->{lifecycle}{actor_counts}{total}, 5,
    'run manifest records deterministic actor total';

my $run_log_path = File::Spec->catfile($run_tmp, $run_command_id, 'logs', 'provider.jsonl');
open my $run_log_fh, '<', $run_log_path or die "open $run_log_path: $!";
my @run_events = map { decode_json($_) } <$run_log_fh>;
is scalar @run_events, 10, 'run command records provider lifecycle events';
is_deeply [map { $_->{phase} } grep { $_->{status} eq 'started' } @run_events],
    [qw(prepare start observe stop collect)],
    'run command records all lifecycle phases';

my $failed_tmp = tempdir(CLEANUP => 1);
my $failed_id = 'cli-run-failed';
my $failed = `$^X $bin run --scenario $scenario --runs-dir $failed_tmp --run-id $failed_id --provider missing 2>&1`;
is $? >> 8, 2, 'run command fails for unknown provider';
like $failed, qr/unknown provider: missing/, 'run command reports provider error';

my $failed_manifest_path = File::Spec->catfile($failed_tmp, $failed_id, 'manifest.json');
my $failed_manifest = _read_json($failed_manifest_path);

is $failed_manifest->{status}, 'failed',
    'failed run manifest records failed status';
is $failed_manifest->{topology_provider}{name}, 'generic-relay',
    'failed run manifest keeps topology provider';
is $failed_manifest->{execution_provider}{name}, 'missing',
    'failed run manifest records selected execution provider';
ok !exists $failed_manifest->{provider},
    'failed run manifest does not use ambiguous provider field';
like $failed_manifest->{error}, qr/unknown provider: missing/,
    'failed run manifest records error';
ok $failed_manifest->{timestamps}{finished_at},
    'failed run manifest records finish time';

done_testing;

sub _read_json {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return decode_json(<$fh>);
}
