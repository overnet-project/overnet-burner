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

open my $fh, '<', $manifest_path or die "open $manifest_path: $!";
local $/;
my $manifest = decode_json(<$fh>);

is $manifest->{run_id}, $run_id, 'CLI manifest records run id';
is $manifest->{scenario}{name}, 'single-relay-baseline',
    'CLI manifest records scenario name';

my $bad_tmp = tempdir(CLEANUP => 1);
my $bad_init = `$^X $bin init-run --scenario $scenario --runs-dir $bad_tmp/runs --run-id ../escape 2>&1`;
is $? >> 8, 2, 'init-run rejects invalid run id';
like $bad_init, qr/\binvalid run_id\b/, 'init-run reports invalid run id';
ok !-d File::Spec->catdir($bad_tmp, 'escape'),
    'init-run does not write outside runs dir for invalid run id';

done_testing;
