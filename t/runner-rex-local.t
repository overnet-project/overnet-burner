use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test::More;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Runner;
use Overnet::Burner::RunLedger;

my $repo = "$FindBin::Bin/..";
my $bin = "$repo/bin/overnet-burner";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario = Overnet::Burner::Config->load_file($scenario_path);
my @rex_tasks = qw(bootstrap deploy start warmup run chaos collect cleanup);
my @bundle_files = (
    'Rexfile',
    'actor-hosts.json',
    'actors/object-reader-001.json',
    'actors/publisher-001.json',
    'actors/query-reader-001.json',
    'actors/relay-001.json',
    'actors/subscriber-001.json',
    'artifact-collection.json',
    'bundle.json',
    'chaos-hooks.json',
    'inventory/hosts.json',
    'lifecycle.json',
    'topology-provider.json',
);

my $tmp = tempdir(CLEANUP => 1);
my $fake_rex = _write_fake_rex($tmp);
my $fake_rex_log = File::Spec->catfile($tmp, 'fake-rex.log');
local $ENV{OVERNET_BURNER_REX} = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $fake_rex_log;

my @times = map { sprintf '2026-06-27T14:00:%02dZ', $_ } 0 .. 59;
my $ledger = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => "$tmp/runs",
    run_id        => 'rex-local-runner-001',
    now           => sub { shift @times },
    host_facts    => {
        hostname => 'builder-host',
        os       => 'linux',
        arch     => 'x86_64',
    },
    repo_sha    => 'abc123',
    rex_version => undef,
);
my $plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});

my $runner = Overnet::Burner::Runner->load(
    name    => 'rex-local',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
);

is $runner->name, 'rex-local', 'loads rex-local runner by name';

my $summary = $runner->run_lifecycle;

is $summary->{runner}, 'rex-local', 'summary records runner name';
is_deeply $summary->{phases},
    {
    prepare => 'completed',
    start   => 'completed',
    observe => 'completed',
    stop    => 'completed',
    collect => 'completed',
    },
    'summary records completed base lifecycle phases';
is_deeply $summary->{actor_counts},
    {
    relays         => 1,
    publishers     => 1,
    subscribers    => 1,
    query_readers  => 1,
    object_readers => 1,
    total          => 5,
    },
    'summary retains actor counts';
is_deeply $summary->{rex_bundle},
    {
    path             => 'artifacts/rex',
    rendered         => 1,
    remote_execution => 'not_performed',
    files            => \@bundle_files,
    },
    'summary includes rendered Rex bundle metadata';
is_deeply [map { $_->{task} } @{ $summary->{rex_tasks} }],
    \@rex_tasks,
    'summary records Rex tasks from the rendered lifecycle';
is_deeply [map { $_->{status} } @{ $summary->{rex_tasks} }],
    [('completed') x @rex_tasks],
    'summary records completed Rex task results';
is_deeply $summary->{rex_tasks}[0],
    {
    task       => 'bootstrap',
    status     => 'completed',
    bundle_dir => 'artifacts/rex',
    rexfile    => 'artifacts/rex/Rexfile',
    },
    'summary task result records bundle paths';

my $bundle_dir = File::Spec->catdir($ledger->{run_dir}, 'artifacts', 'rex');
ok -e File::Spec->catfile($bundle_dir, 'Rexfile'),
    'rex-local renders Rexfile before task execution';
ok -e File::Spec->catfile($bundle_dir, 'lifecycle.json'),
    'rex-local renders lifecycle artifact before task execution';

my $manifest = _read_json(File::Spec->catfile($ledger->{run_dir}, 'manifest.json'));
is $manifest->{rex_bundle}{path}, 'artifacts/rex',
    'manifest records rendered Rex bundle path';
is $manifest->{rex_bundle}{rendered}, 1,
    'manifest records rendered Rex bundle';
is $manifest->{rex_bundle}{remote_execution}, 'not_performed',
    'manifest records local stub execution boundary';
ok !exists $manifest->{provider}, 'manifest avoids ambiguous provider field';
ok !exists $manifest->{execution_provider},
    'manifest avoids execution provider field';

my $runner_log_path = File::Spec->catfile($ledger->{run_dir}, 'logs', 'runner.jsonl');
open my $log_fh, '<', $runner_log_path or die "open $runner_log_path: $!";
my @events = map { JSON::decode_json($_) } <$log_fh>;

is_deeply [map { "$_->{phase}:$_->{status}" } grep { !exists $_->{rex_task} } @events],
    [
    'prepare:started',
    'prepare:completed',
    'start:started',
    'start:completed',
    'observe:started',
    'observe:completed',
    'stop:started',
    'stop:completed',
    'collect:started',
    'collect:completed',
    ],
    'base lifecycle runner events stay coherent';

my @task_events = grep { exists $_->{rex_task} } @events;
is_deeply [map { "$_->{rex_task}:$_->{status}" } @task_events],
    [
    map { ("$_:started", "$_:completed") } @rex_tasks
    ],
    'runner log records Rex task execution event order';
is $task_events[0]{runner}, 'rex-local', 'Rex task event records runner';
is $task_events[0]{phase}, 'start', 'Rex task event records base phase';
is $task_events[0]{bundle_dir}, 'artifacts/rex',
    'Rex task event records bundle directory';
is $task_events[0]{rexfile}, 'artifacts/rex/Rexfile',
    'Rex task event records Rexfile path';

ok -e $fake_rex_log, 'rex-local invokes a Rex executable';
my @rex_invocations = _read_lines($fake_rex_log);
is_deeply \@rex_invocations,
    [
    map {
        join "\0",
            '-f',
            File::Spec->catfile($bundle_dir, 'Rexfile'),
            $_
    } @rex_tasks
    ],
    'rex-local shells out to Rex for each rendered lifecycle task';

my $artifact = _read_json(
    File::Spec->catfile($ledger->{run_dir}, 'artifacts', 'rex-local-runner.json'),
);
is_deeply $artifact, $summary,
    'rex-local writes deterministic summary artifact';

my $cli_tmp = tempdir(CLEANUP => 1);
my $cli_run_id = 'cli-rex-local-001';
my $cli_run = `$^X $bin run --scenario $scenario_path --runs-dir $cli_tmp --run-id $cli_run_id --runner rex-local 2>&1`;
is $?, 0, 'CLI run --runner rex-local exits successfully';
like $cli_run, qr{^completed run: \Q$cli_tmp/$cli_run_id\E$}m,
    'CLI run reports completed rex-local run directory';

my $cli_manifest = _read_json(
    File::Spec->catfile($cli_tmp, $cli_run_id, 'manifest.json'),
);
is $cli_manifest->{status}, 'completed',
    'CLI rex-local manifest records completion';
is $cli_manifest->{runner}{name}, 'rex-local',
    'CLI rex-local manifest records selected runner';
is $cli_manifest->{rex_bundle}{path}, 'artifacts/rex',
    'CLI rex-local manifest records Rex bundle path';
is $cli_manifest->{rex_bundle}{rendered}, 1,
    'CLI rex-local manifest records rendered Rex bundle';
is $cli_manifest->{lifecycle}{runner}, 'rex-local',
    'CLI rex-local manifest records lifecycle runner';
is_deeply [map { $_->{task} } @{ $cli_manifest->{lifecycle}{rex_tasks} }],
    \@rex_tasks,
    'CLI rex-local lifecycle records Rex task results';
is scalar _read_lines($fake_rex_log), 2 * @rex_tasks,
    'CLI rex-local also shells out to Rex tasks';
ok !exists $cli_manifest->{provider},
    'CLI rex-local manifest avoids ambiguous provider field';
ok !exists $cli_manifest->{execution_provider},
    'CLI rex-local manifest avoids execution provider field';

my $external_tmp = tempdir(CLEANUP => 1);
my $marker = File::Spec->catfile($external_tmp, 'external-command-ran');
my $command = {
    start  => qq{python -c "open('$marker','w').write('start')"},
    stop   => 'pkill -f pyovernet.relay',
    health => 'curl -fsS http://127.0.0.1:9/health',
};
my $external_scenario = File::Spec->catfile($external_tmp, 'external-command.yml');
_write_yaml($external_scenario, _scenario_yaml($command));

my $external_run_id = 'external-command-rex-local';
my $external_run = `$^X $bin run --scenario $external_scenario --runs-dir $external_tmp/runs --run-id $external_run_id --runner rex-local 2>&1`;
is $?, 0, 'rex-local run accepts external-command provider scenario';
like $external_run,
    qr{^completed run: \Q$external_tmp/runs/$external_run_id\E$}m,
    'rex-local completes external-command provider run';
ok !-e $marker, 'rex-local does not execute provider command strings';

my $topology_provider = _read_json(
    File::Spec->catfile(
        $external_tmp,
        'runs',
        $external_run_id,
        'artifacts',
        'rex',
        'topology-provider.json',
    ),
);
is_deeply $topology_provider->{relays}[0]{lifecycle},
    {
    health => {
        command   => $command->{health},
        execution => 'planned',
    },
    start => {
        command   => $command->{start},
        execution => 'planned',
    },
    stop => {
        command   => $command->{stop},
        execution => 'planned',
    },
    },
    'rex-local preserves provider command metadata as planned artifacts';
is scalar _read_lines($fake_rex_log), 3 * @rex_tasks,
    'external-command rex-local run still only invokes Rex tasks';

my $relative_tmp = tempdir(CLEANUP => 1);
my $relative_fake_rex = _write_fake_rex($relative_tmp);
my $relative_rex_log = File::Spec->catfile($relative_tmp, 'fake-rex.log');
my $relative_runs = "relative-rex-local-$$";
{
    local $ENV{OVERNET_BURNER_REX} = $relative_fake_rex;
    local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $relative_rex_log;
    my $relative_run = `$^X $bin run --scenario $scenario_path --runs-dir $relative_runs --run-id relative --runner rex-local 2>&1`;
    is $?, 0, 'CLI rex-local works with a relative runs-dir';
    like $relative_run, qr{^completed run: \Q$relative_runs/relative\E$}m,
        'relative runs-dir run reports completed run directory';
}
_remove_tree($relative_runs);

my $failure_tmp = tempdir(CLEANUP => 1);
local $ENV{OVERNET_BURNER_TEST_REX_FAIL_TASK} = 'warmup';
my $failed_run_id = 'cli-rex-local-failed';
my $failed_run = `$^X $bin run --scenario $scenario_path --runs-dir $failure_tmp --run-id $failed_run_id --runner rex-local 2>&1`;
is $? >> 8, 2, 'CLI rex-local fails when a Rex task fails';
like $failed_run, qr/Rex task command failed:/,
    'CLI rex-local reports Rex task failure';

my $failed_manifest = _read_json(
    File::Spec->catfile($failure_tmp, $failed_run_id, 'manifest.json'),
);
is $failed_manifest->{status}, 'failed',
    'failed rex-local manifest records failed status';
is $failed_manifest->{runner}{name}, 'rex-local',
    'failed rex-local manifest records runner';
like $failed_manifest->{error}, qr/Rex task command failed:/,
    'failed rex-local manifest records Rex task error';
is $failed_manifest->{rex_bundle}{path}, 'artifacts/rex',
    'failed rex-local manifest keeps rendered Rex bundle metadata';

my $failed_events = _read_jsonl(
    File::Spec->catfile($failure_tmp, $failed_run_id, 'logs', 'runner.jsonl'),
);
my @failed_rex_events = grep { exists $_->{rex_task} } @{$failed_events};
is_deeply [map { "$_->{rex_task}:$_->{status}" } @failed_rex_events],
    [
    'bootstrap:started',
    'bootstrap:completed',
    'deploy:started',
    'deploy:completed',
    'start:started',
    'start:completed',
    'warmup:started',
    'warmup:failed',
    ],
    'runner log records failed Rex task and stops later tasks';

done_testing;

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

sub _scenario_yaml {
    my ($command) = @_;

    return <<"YAML";
run:
  name: external-command-relay
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

sub _write_yaml {
    my ($path, $yaml) = @_;

    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $yaml;
    close $fh or die "close $path: $!";
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
    local $/;
    return <$fh>;
}

sub _remove_tree {
    my ($path) = @_;

    return unless -e $path;

    if (-d $path) {
        opendir my $dh, $path or die "opendir $path: $!";
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh or die "closedir $path: $!";
        _remove_tree(File::Spec->catfile($path, $_)) for @entries;
        rmdir $path or die "rmdir $path: $!";
        return;
    }

    unlink $path or die "unlink $path: $!";
}
