use strictures 2;

use File::Spec;
use FindBin;
use JSON ();
use Test::More;

my $repo = "$FindBin::Bin/..";
my $schema_path = File::Spec->catfile($repo, 'schemas', 'report-v1.schema.json');
my $example_path = File::Spec->catfile($repo, 'examples', 'report-v1-smoke.json');
my $docs_path = File::Spec->catfile($repo, 'docs', 'REPORT.md');

ok -e $schema_path, 'report v1 schema exists';
ok -e $example_path, 'report v1 smoke example exists';
ok -e $docs_path, 'report contract documentation exists';

my $schema = _read_json($schema_path);
my $example = _read_json($example_path);
my $docs = _read_file($docs_path);

my $schema_id = 'https://overnet-project.org/schemas/overnet-burner/report-v1.schema.json';

is $schema->{'$schema'}, 'https://json-schema.org/draft/2020-12/schema',
    'schema declares JSON Schema draft 2020-12';
is $schema->{'$id'}, $schema_id, 'schema has stable id';
is $schema->{title}, 'overnet-burner report v1', 'schema names the contract';
is $schema->{additionalProperties}, JSON::false,
    'top-level report schema is closed';
is $schema->{properties}{report_version}{const}, 1,
    'report_version is locked to v1';
is $schema->{properties}{schema}{const}, $schema_id,
    'schema URI is locked in the report payload';

is_deeply $schema->{required},
    [
    qw(
        report_version
        schema
        generated_at
        run
        scenario
        environment
        topology
        execution
        workload
        metrics
        thresholds
        chaos
        artifacts
        diagnostics
        human_summary
        extensions
    )
    ],
    'top-level required sections are stable';

is_deeply $schema->{properties}{run}{properties}{status}{enum},
    [qw(created running completed failed aborted)],
    'run status enum is explicit';
is_deeply $schema->{properties}{run}{properties}{verdict}{enum},
    [
    qw(
        not_evaluated
        smoke_passed
        performance_passed
        performance_failed
        chaos_passed
        chaos_failed
        conformance_passed
        conformance_failed
        orchestration_failed
        inconclusive_no_metrics
        inconclusive_partial_run
        aborted
    )
    ],
    'run verdict enum is explicit';
is_deeply $schema->{properties}{run}{properties}{result_class}{enum},
    [qw(none orchestration performance chaos conformance mixed)],
    'result class enum is explicit';
is_deeply $schema->{'$defs'}{phase}{properties}{status}{enum},
    [qw(planned skipped running completed failed not_evaluated)],
    'phase status enum is explicit';
is_deeply $schema->{'$defs'}{threshold}{properties}{status}{enum},
    [qw(planned not_evaluated passed failed)],
    'threshold status enum is explicit';
ok exists $schema->{properties}{extensions},
    'schema has an explicit extension point';

is $example->{report_version}, 1, 'example uses report version 1';
is $example->{schema}, $schema_id, 'example records schema URI';
_assert_required($schema->{required}, $example, 'example top-level report');
is $example->{run}{status}, 'completed', 'example records completed run status';
is $example->{run}{verdict}, 'smoke_passed', 'example records smoke verdict';
is $example->{run}{result_class}, 'orchestration',
    'example classifies smoke as orchestration';
is $example->{topology}{actors}{total}, 5,
    'example records actor total';
is $example->{execution}{runner}, 'rex-local',
    'example records execution runner';
is $example->{execution}{remote_execution}, 'not_performed',
    'example records no remote execution';
is $example->{metrics}{collected}, JSON::false,
    'example records no metrics collected';
is $example->{metrics}{reason}, 'smoke_only',
    'example explains missing metrics';
is $example->{thresholds}[0]{status}, 'not_evaluated',
    'example threshold is machine-readable';
is $example->{thresholds}[0]{reason}, 'no_metrics',
    'example threshold gives structured reason';
is $example->{chaos}{hooks_configured}, 0,
    'example records no chaos hooks configured';
is $example->{diagnostics}{warnings}[0]{code}, 'no_real_workload',
    'example diagnostics capture the current smoke limitation';
ok @{$example->{artifacts}} >= 5, 'example lists artifact references';
for my $artifact (@{ $example->{artifacts} }) {
    _assert_required(
        [qw(id path media_type role required sha256 size_bytes)],
        $artifact,
        "artifact $artifact->{id}",
    );
}

like $docs, qr/report\.json is the stable automation contract/,
    'docs define report.json as the automation contract';
like $docs, qr/manifest\.json, plan\.json, runner\.jsonl, and metrics\.jsonl are evidence/,
    'docs distinguish internal evidence from the report contract';
like $docs, qr/Breaking changes require a new report_version/,
    'docs define compatibility rules';

done_testing;

sub _read_json {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return JSON::decode_json(<$fh>);
}

sub _read_file {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return <$fh>;
}

sub _assert_required {
    my ($required, $object, $label) = @_;

    for my $field (@{$required}) {
        ok exists $object->{$field}, "$label has required field $field";
    }
}
