use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP qw(decode_json);
use Test::More;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::RunLedger;

my $repo = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario = Overnet::Burner::Config->load_file($scenario_path);
my $tmp = tempdir(CLEANUP => 1);

my $ledger = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => "$tmp/runs",
    run_id        => 'test-run-001',
    now           => sub { '2026-06-27T14:00:00Z' },
    host_facts    => {
        hostname => 'builder-host',
        os       => 'linux',
        arch     => 'x86_64',
    },
    repo_sha    => 'abc123',
    rex_version => undef,
);

my $run_dir = $ledger->{run_dir};
ok -d $run_dir, 'creates run directory';

for my $path (
    'scenario.yml',
    'config.normalized.json',
    'manifest.json',
    'metrics.jsonl',
) {
    ok -e File::Spec->catfile($run_dir, $path), "creates $path";
}

ok -d File::Spec->catdir($run_dir, 'logs'), 'creates logs directory';
ok -d File::Spec->catdir($run_dir, 'artifacts'), 'creates artifacts directory';

my $manifest = do {
    open my $fh, '<', File::Spec->catfile($run_dir, 'manifest.json')
        or die "open manifest.json: $!";
    local $/;
    decode_json(<$fh>);
};

is $manifest->{run_id}, 'test-run-001', 'manifest records run id';
is $manifest->{timestamps}{created_at}, '2026-06-27T14:00:00Z',
    'manifest records timestamp';
is $manifest->{seed}, 12345, 'manifest records seed';
is $manifest->{scenario}{name}, 'single-relay-baseline',
    'manifest records scenario name';
is $manifest->{provider}{name}, 'generic-relay', 'manifest records provider';
is $manifest->{host_facts}{hostname}, 'builder-host', 'manifest records host facts';
is $manifest->{repo_sha}, 'abc123', 'manifest records repo SHA';
like $manifest->{perl_version}, qr/^5\./, 'manifest records Perl version';
ok exists $manifest->{rex_version}, 'manifest has Rex version key';

my $normalized = do {
    open my $fh, '<', File::Spec->catfile($run_dir, 'config.normalized.json')
        or die "open config.normalized.json: $!";
    local $/;
    <$fh>;
};

is $normalized, Overnet::Burner::Config->normalized_json($scenario),
    'ledger writes deterministic normalized config';

for my $case (
    ['',             'empty run id'],
    ['.',            'single dot run id'],
    ['..',           'double dot run id'],
    ['../escape',    'forward slash traversal run id'],
    ['..\\escape',   'backslash traversal run id'],
    ['nested/run',   'forward slash run id'],
    ['nested\\run',  'backslash run id'],
    ['run id',       'space in run id'],
    ['run:id',       'punctuation outside safe run id set'],
) {
    my ($run_id, $label) = @{$case};
    my $case_tmp = tempdir(CLEANUP => 1);
    my $created = eval {
        Overnet::Burner::RunLedger->create(
            scenario      => $scenario,
            scenario_path => $scenario_path,
            runs_dir      => File::Spec->catdir($case_tmp, 'runs'),
            run_id        => $run_id,
        );
        1;
    };
    my $error = $@;

    ok !$created, "rejects $label";
    like $error, qr/\binvalid run_id\b/, "reports invalid run id for $label";
    ok !-d File::Spec->catdir($case_tmp, 'escape'),
        "does not create traversal directory for $label";
}

done_testing;
