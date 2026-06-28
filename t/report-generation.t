use strictures 2;

use Digest::SHA;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test::More;

use lib "$FindBin::Bin/../lib";

my $repo = "$FindBin::Bin/..";
my $bin = "$repo/bin/overnet-burner";
my $scenario = "$repo/scenarios/single-relay-baseline.yml";
my $schema_id = 'https://overnet-project.org/schemas/overnet-burner/report-v1.schema.json';

my $tmp = tempdir(CLEANUP => 1);

my $init_run_id = 'report-init-001';
my $init_run = `$^X $bin init-run --scenario $scenario --runs-dir $tmp --run-id $init_run_id 2>&1`;
is $?, 0, 'creates initialized run for reporting';
like $init_run, qr{^created run: \Q$tmp/$init_run_id\E$}m,
    'init-run reports created run directory';

my $init_run_dir = File::Spec->catdir($tmp, $init_run_id);
my $init_report_command = `$^X $bin report --run-dir $init_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for initialized run';

my $init_report = _read_json(File::Spec->catfile($init_run_dir, 'report.json'));
_assert_common_report($init_report, $init_run_id);
is $init_report->{run}{status}, 'created',
    'initialized report records created status';
is $init_report->{run}{verdict}, 'not_evaluated',
    'initialized report records not evaluated verdict';
is $init_report->{run}{result_class}, 'none',
    'initialized report records no result class';
is $init_report->{execution}{runner}, 'none',
    'initialized report uses explicit none runner';
is_deeply $init_report->{execution}{phases}, [],
    'initialized report records no execution phases';

my $noop_run_id = 'report-noop-001';
my $noop_run = `$^X $bin run --scenario $scenario --runs-dir $tmp --run-id $noop_run_id --runner noop 2>&1`;
is $?, 0, 'creates noop run for reporting';
like $noop_run, qr{^completed run: \Q$tmp/$noop_run_id\E$}m,
    'noop run reports completed run directory';

my $noop_run_dir = File::Spec->catdir($tmp, $noop_run_id);
my $noop_report_command = `$^X $bin report --run-dir $noop_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for noop run';
like $noop_report_command, qr{^wrote report: \Q$noop_run_dir/report.json\E$}m,
    'report command prints report path';
ok -e File::Spec->catfile($noop_run_dir, 'report.json'),
    'report command writes report.json';

my $noop_report = _read_json(File::Spec->catfile($noop_run_dir, 'report.json'));
_assert_common_report($noop_report, $noop_run_id);
is $noop_report->{run}{status}, 'completed',
    'noop report records completed status';
is $noop_report->{run}{verdict}, 'smoke_passed',
    'noop report classifies completed orchestration as smoke passed';
is $noop_report->{run}{result_class}, 'orchestration',
    'noop report records orchestration result class';
is $noop_report->{scenario}{name}, 'single-relay-baseline',
    'noop report records scenario name';
is $noop_report->{scenario}{seed}, 12345,
    'noop report records scenario seed';
is $noop_report->{topology}{provider}{name}, 'generic-relay',
    'noop report records topology provider';
is_deeply $noop_report->{topology}{provider}{descriptor}, {},
    'noop report uses an empty provider descriptor for generic relay';
is_deeply $noop_report->{topology}{actors},
    {
    relays         => 1,
    publishers     => 1,
    subscribers    => 1,
    query_readers  => 1,
    object_readers => 1,
    total          => 5,
    },
    'noop report records actor counts';
is $noop_report->{topology}{hosts}{total}, 0,
    'noop report does not invent host inventory';
is $noop_report->{execution}{runner}, 'noop',
    'noop report records runner';
is $noop_report->{execution}{remote_execution}, 'not_performed',
    'noop report records no remote execution';
is_deeply [map { "$_->{kind}:$_->{name}:$_->{status}" } @{ $noop_report->{execution}{phases} }],
    [
    'runner_phase:prepare:completed',
    'runner_phase:start:completed',
    'runner_phase:observe:completed',
    'runner_phase:stop:completed',
    'runner_phase:collect:completed',
    ],
    'noop report summarizes runner phases';
is $noop_report->{workload}{duration_seconds}, 60,
    'noop report records workload duration';
is $noop_report->{workload}{phases}[0]{publish_rate_per_second}, 10,
    'noop report records publish rate';
is $noop_report->{workload}{phases}[0]{object_reads_per_second}, 1,
    'noop report records object read rate';
is $noop_report->{metrics}{collected}, JSON::false,
    'noop report records no metrics collected';
is $noop_report->{metrics}{reason}, 'smoke_only',
    'noop report explains missing metrics';
is $noop_report->{metrics}{streams}{expected}, 5,
    'noop report records expected metric streams';
is $noop_report->{metrics}{streams}{seen}, 0,
    'noop report records no seen metric streams';
is scalar @{ $noop_report->{metrics}{streams}{missing} }, 5,
    'noop report records missing metric streams';
is_deeply [map { "$_->{id}:$_->{status}:$_->{reason}" } @{ $noop_report->{thresholds} }],
    [
    'error_rate_max:not_evaluated:no_metrics',
    'publish_p99_ms:not_evaluated:no_metrics',
    'subscription_fanout_p99_ms:not_evaluated:no_metrics',
    ],
    'noop report marks thresholds not evaluated without metrics';
is $noop_report->{chaos}{hooks_configured}, 0,
    'noop report records no configured chaos hooks';
is $noop_report->{chaos}{hooks_executed}, 0,
    'noop report records no executed chaos hooks';
is $noop_report->{diagnostics}{warnings}[0]{code}, 'no_real_workload',
    'noop report warns that smoke did not run real workload';

my %noop_artifacts = map { $_->{id} => $_ } @{ $noop_report->{artifacts} };
for my $id (qw(manifest scenario normalized_config plan runner_log metrics)) {
    ok exists $noop_artifacts{$id}, "noop report includes $id artifact";
    _assert_artifact_hash($noop_run_dir, $noop_artifacts{$id});
}
ok !exists $noop_artifacts{rexfile},
    'noop report does not report absent Rexfile artifact';

my $rex_tmp = tempdir(CLEANUP => 1);
my $fake_rex = _write_fake_rex($rex_tmp);
my $rex_log = File::Spec->catfile($rex_tmp, 'fake-rex.log');
my $rex_run_id = 'report-rex-local-001';
{
    local $ENV{OVERNET_BURNER_REX} = $fake_rex;
    local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $rex_log;
    my $rex_run = `$^X $bin run --scenario $scenario --runs-dir $tmp --run-id $rex_run_id --runner rex-local 2>&1`;
    is $?, 0, 'creates rex-local run for reporting';
    like $rex_run, qr{^completed run: \Q$tmp/$rex_run_id\E$}m,
        'rex-local run reports completed run directory';
}

my $rex_run_dir = File::Spec->catdir($tmp, $rex_run_id);
my $rex_report_command = `$^X $bin report --run-dir $rex_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for rex-local run';
like $rex_report_command, qr{^wrote report: \Q$rex_run_dir/report.json\E$}m,
    'rex-local report command prints report path';

my $rex_report = _read_json(File::Spec->catfile($rex_run_dir, 'report.json'));
_assert_common_report($rex_report, $rex_run_id);
is $rex_report->{execution}{runner}, 'rex-local',
    'rex report records rex-local runner';
is $rex_report->{topology}{hosts}{total}, 1,
    'rex report records rendered host inventory';
is $rex_report->{topology}{hosts}{groups}{relays}, 1,
    'rex report records relay host group count';
ok scalar grep({ $_->{kind} eq 'rex_task' && $_->{name} eq 'bootstrap' && $_->{status} eq 'completed' }
        @{ $rex_report->{execution}{phases} }),
    'rex report includes completed bootstrap Rex task phase';
ok scalar grep({ $_->{kind} eq 'rex_task' && $_->{name} eq 'cleanup' && $_->{status} eq 'completed' }
        @{ $rex_report->{execution}{phases} }),
    'rex report includes completed cleanup Rex task phase';

my %rex_artifacts = map { $_->{id} => $_ } @{ $rex_report->{artifacts} };
for my $id (qw(rex_bundle rexfile rex_lifecycle rex_inventory rex_topology_provider)) {
    ok exists $rex_artifacts{$id}, "rex report includes $id artifact";
    _assert_artifact_hash($rex_run_dir, $rex_artifacts{$id});
}

my $failed_run_id = 'report-failed-001';
my $failed_run = `$^X $bin run --scenario $scenario --runs-dir $tmp --run-id $failed_run_id --runner missing 2>&1`;
is $? >> 8, 2, 'creates failed run for reporting';
like $failed_run, qr/unknown runner: missing/,
    'failed run reports runner error';

my $failed_run_dir = File::Spec->catdir($tmp, $failed_run_id);
my $failed_report_command = `$^X $bin report --run-dir $failed_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for failed run';

my $failed_report = _read_json(File::Spec->catfile($failed_run_dir, 'report.json'));
_assert_common_report($failed_report, $failed_run_id);
is $failed_report->{run}{status}, 'failed',
    'failed report records failed status';
is $failed_report->{run}{verdict}, 'orchestration_failed',
    'failed report records orchestration failure verdict';
is $failed_report->{run}{result_class}, 'orchestration',
    'failed report keeps orchestration result class';
is $failed_report->{execution}{runner}, 'missing',
    'failed report records requested runner';
is $failed_report->{diagnostics}{errors}[0]{code}, 'run_failed',
    'failed report records structured run failure';
like $failed_report->{diagnostics}{errors}[0]{message}, qr/unknown runner: missing/,
    'failed report records run failure message';

my $missing_report = `$^X $bin report --run-dir $tmp/missing-run 2>&1`;
is $? >> 8, 2, 'report command rejects missing run directory';
like $missing_report, qr/run directory does not exist/,
    'report command explains missing run directory';

done_testing;

sub _assert_common_report {
    my ($report, $run_id) = @_;

    is $report->{report_version}, 1, "$run_id report uses v1";
    is $report->{schema}, $schema_id, "$run_id report records schema id";
    ok $report->{generated_at}, "$run_id report records generated timestamp";
    is $report->{run}{id}, $run_id, "$run_id report records run id";
    is $report->{scenario}{source_path}, 'scenario.yml',
        "$run_id report records scenario artifact path";
    is $report->{scenario}{normalized_config_path}, 'config.normalized.json',
        "$run_id report records normalized config artifact path";
    is $report->{scenario}{plan_path}, 'plan.json',
        "$run_id report records plan artifact path";
    ok exists $report->{environment}{host}{hostname},
        "$run_id report records host facts";
    ok exists $report->{environment}{perl_version},
        "$run_id report records Perl version";
    ok exists $report->{environment}{rex_version},
        "$run_id report records Rex version";
    ok exists $report->{extensions}, "$run_id report has extension point";
    ok $report->{human_summary}{headline},
        "$run_id report has human headline";
}

sub _assert_artifact_hash {
    my ($run_dir, $artifact) = @_;

    my $path = File::Spec->catfile($run_dir, $artifact->{path});
    ok -e $path, "$artifact->{id} artifact exists at reported path";
    is $artifact->{size_bytes}, -s $path,
        "$artifact->{id} artifact records size";
    is $artifact->{sha256}, _sha256_file($path),
        "$artifact->{id} artifact records sha256";
}

sub _sha256_file {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    binmode $fh;
    my $digest = Digest::SHA->new(256);
    $digest->addfile($fh);
    close $fh or die "close $path: $!";
    return $digest->hexdigest;
}

sub _read_json {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return JSON::decode_json(<$fh>);
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
for my $index (0 .. $#ARGV - 1) {
    next unless $ARGV[$index] eq '-f';
    die "Rexfile does not exist: $ARGV[$index + 1]\n"
        unless -f $ARGV[$index + 1];
}
print "fake rex: @ARGV\n";
exit 0;
PERL
    close $fh or die "close $path: $!";
    chmod 0755, $path or die "chmod $path: $!";

    return $path;
}
