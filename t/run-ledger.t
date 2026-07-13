use strictures 2;

use File::Copy ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::RunLedger;

my $repo          = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario      = Overnet::Burner::Config->load_file($scenario_path);
my $tmp           = tempdir(CLEANUP => 1);

my $ledger = Overnet::Burner::RunLedger->create(
  scenario      => $scenario,
  scenario_path => $scenario_path,
  runs_dir      => "$tmp/runs",
  run_id        => 'test-run-001',
  now           => sub {'2026-06-27T14:00:00Z'},
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

for my $path ('scenario.yml', 'config.normalized.json', 'plan.json', 'manifest.json', 'metrics.jsonl',) {
  ok -e File::Spec->catfile($run_dir, $path), "creates $path";
}

ok -d File::Spec->catdir($run_dir, 'logs'),      'creates logs directory';
ok -d File::Spec->catdir($run_dir, 'artifacts'), 'creates artifacts directory';

my $manifest = do {
  open my $fh, '<', File::Spec->catfile($run_dir, 'manifest.json')
    or die "open manifest.json: $!";
  local $/ = undef;
  JSON::decode_json(<$fh>);
};

is $manifest->{run_id},                  'test-run-001',          'manifest records run id';
is $manifest->{timestamps}{created_at},  '2026-06-27T14:00:00Z',  'manifest records timestamp';
is $manifest->{seed},                    12345,                   'manifest records seed';
is $manifest->{scenario}{name},          'single-relay-baseline', 'manifest records scenario name';
is $manifest->{topology_provider}{name}, 'generic-relay',         'manifest records topology provider';
ok exists $manifest->{runner},              'manifest has runner field';
ok !defined $manifest->{runner}{name},      'manifest leaves runner unset before run starts';
ok !exists $manifest->{provider},           'manifest does not use ambiguous provider field';
ok !exists $manifest->{execution_provider}, 'manifest does not use execution provider field';
is $manifest->{host_facts}{hostname}, 'builder-host', 'manifest records host facts';
is $manifest->{repo_sha},             'abc123',       'manifest records repo SHA';
like $manifest->{perl_version}, qr/^5\./mx, 'manifest records Perl version';
ok exists $manifest->{rex_version}, 'manifest has Rex version key';

my $normalized = do {
  open my $fh, '<', File::Spec->catfile($run_dir, 'config.normalized.json')
    or die "open config.normalized.json: $!";
  local $/ = undef;
  <$fh>;
};

is $normalized, Overnet::Burner::Config->normalized_json($scenario), 'ledger writes deterministic normalized config';

my $plan_json = do {
  open my $fh, '<', File::Spec->catfile($run_dir, 'plan.json')
    or die "open plan.json: $!";
  local $/ = undef;
  <$fh>;
};

is $plan_json,
  Overnet::Burner::Plan->canonical_json(Overnet::Burner::Plan->build($scenario),),
  'ledger writes deterministic plan';

my $bad_plan_tmp      = tempdir(CLEANUP => 1);
my $bad_plan_scenario = JSON::decode_json(Overnet::Burner::Config->normalized_json($scenario));
$bad_plan_scenario->{chaos} = [5];
my $bad_plan_created = eval {
  Overnet::Burner::RunLedger->create(
    scenario      => $bad_plan_scenario,
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($bad_plan_tmp, 'runs'),
    run_id        => 'bad-plan',
  );
  1;
};
my $bad_plan_error = $@;

ok !$bad_plan_created, 'rejects scenario that cannot produce a plan';
like $bad_plan_error, qr/chaos\[0\]\ must\ be\ a\ mapping/mx, 'reports plan generation error before writing ledger';
ok !-e File::Spec->catdir($bad_plan_tmp, 'runs', 'bad-plan'),
  'does not leave a partial run directory when plan generation fails';

for my $case (
  ['',            'empty run id'],
  ['.',           'single dot run id'],
  ['..',          'double dot run id'],
  ['../escape',   'forward slash traversal run id'],
  ['..\\escape',  'backslash traversal run id'],
  ['nested/run',  'forward slash run id'],
  ['nested\\run', 'backslash run id'],
  ['run id',      'space in run id'],
  ['run:id',      'punctuation outside safe run id set'],
) {
  my ($run_id, $label) = @{$case};
  my $case_tmp = tempdir(CLEANUP => 1);
  my $created  = eval {
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
  like $error, qr/\binvalid\ run_id\b/mx, "reports invalid run id for $label";
  ok !-d File::Spec->catdir($case_tmp, 'escape'), "does not create traversal directory for $label";
}

my $plan = Overnet::Burner::RunLedger->load_plan($run_dir);
is $plan, JSON::decode_json($plan_json), 'load_plan reads the recorded plan back';

$ledger->mark_started;
my $started_manifest = _read_manifest($run_dir);
is $started_manifest->{status},                  'running',              'mark_started records running status';
is $started_manifest->{timestamps}{started_at},  '2026-06-27T14:00:00Z', 'mark_started records started timestamp';
ok !defined $started_manifest->{runner}{name}, 'mark_started leaves runner unset when not provided';

$ledger->mark_started(runner => 'rex-local');
is _read_manifest($run_dir)->{runner}{name}, 'rex-local', 'mark_started records runner name when provided';

my $finished_without_status = eval { $ledger->finish; 1 };
my $finish_error            = $@;
ok !$finished_without_status, 'finish rejects missing status';
like $finish_error, qr/\bstatus\ is\ required\b/mx, 'finish reports missing status';

$ledger->finish(
  status    => 'failed',
  runner    => 'rex-local-workers',
  lifecycle => {stopped => 1},
  error     => 'relay crashed',
);
my $failed_manifest = _read_manifest($run_dir);
is $failed_manifest->{status},                   'failed',               'finish records status';
is $failed_manifest->{timestamps}{finished_at},  '2026-06-27T14:00:00Z', 'finish records finished timestamp';
is $failed_manifest->{runner}{name},             'rex-local-workers',    'finish updates runner name';
is $failed_manifest->{lifecycle},                {stopped => 1},         'finish records lifecycle';
is $failed_manifest->{error},                    'relay crashed',        'finish records error';

$ledger->finish(status => 'completed');
my $completed_manifest = _read_manifest($run_dir);
is $completed_manifest->{status}, 'completed', 'finish can rewrite status';
ok !exists $completed_manifest->{error}, 'finish without error clears the recorded error';

$ledger->append_runner_event({event => 'quiet'});
ok -e File::Spec->catfile($run_dir, 'logs', 'runner.jsonl'),
  'append_runner_event works without an event observer';

my @observed;
my $observing_tmp    = tempdir(CLEANUP => 1);
my $observing_ledger = Overnet::Burner::RunLedger->create(
  scenario       => $scenario,
  scenario_path  => $scenario_path,
  runs_dir       => "$observing_tmp/runs",
  run_id         => 'observer-run',
  now            => sub {'2026-06-27T15:00:00Z'},
  host_facts     => {hostname => 'builder-host'},
  repo_sha       => 'abc123',
  rex_version    => undef,
  event_observer => sub { push @observed, $_[0] },
);

my $bad_event_appended = eval { $observing_ledger->append_runner_event('not-a-hash'); 1 };
my $bad_event_error    = $@;
ok !$bad_event_appended, 'append_runner_event rejects non-hash events';
like $bad_event_error, qr/\bevent\ is\ required\b/mx, 'append_runner_event reports invalid event';

$observing_ledger->append_runner_event({event => 'provisioned'});
$observing_ledger->append_runner_event({event => 'stopped', timestamp => '2026-06-27T16:00:00Z'});

my $runner_log = do {
  open my $fh, '<', File::Spec->catfile($observing_ledger->{run_dir}, 'logs', 'runner.jsonl')
    or die "open runner.jsonl: $!";
  local $/ = undef;
  <$fh>;
};
my @entries = map { JSON::decode_json($_) } split /\n/, $runner_log;

is scalar @entries,          2,                      'append_runner_event appends one line per event';
is $entries[0]{event},       'provisioned',          'append_runner_event records the event fields';
is $entries[0]{timestamp},   '2026-06-27T15:00:00Z', 'append_runner_event stamps events without a timestamp';
is $entries[1]{timestamp},   '2026-06-27T16:00:00Z', 'append_runner_event preserves explicit timestamps';
is scalar @observed,         2,                      'append_runner_event notifies the event observer';
is $observed[1]{event},      'stopped',              'event observer receives the appended entry';

my $orphan_ledger = Overnet::Burner::RunLedger->new(
  run_id  => 'orphan',
  run_dir => File::Spec->catdir($observing_tmp, 'missing-run'),
  now     => sub {'2026-06-27T15:00:00Z'},
);
my $orphan_appended = eval { $orphan_ledger->append_runner_event({event => 'lost'}); 1 };
my $orphan_error    = $@;
ok !$orphan_appended, 'append_runner_event fails when the run directory is missing';
like $orphan_error, qr/\bopen\b/mx, 'append_runner_event reports the failed open';

for my $case (
  [{files        => ['Rexfile']}, 'relative_dir', 'record_rex_bundle requires relative_dir'],
  [{relative_dir => 'rex'},       'files',        'record_rex_bundle requires files'],
) {
  my ($bad_args, $field, $label) = @{$case};
  my $recorded = eval { $observing_ledger->record_rex_bundle(%{$bad_args}); 1 };
  my $error    = $@;
  ok !$recorded, $label;
  like $error, qr/\b$field\ is\ required\b/mx, "$label with a diagnostic";
}

$observing_ledger->record_rex_bundle(
  relative_dir => 'rex',
  files        => ['Rexfile', 'meta.json'],
);
my $bundle_manifest = _read_manifest($observing_ledger->{run_dir});
is $bundle_manifest->{rex_bundle},
  {
  path             => 'rex',
  rendered         => 1,
  rendered_at      => '2026-06-27T15:00:00Z',
  remote_execution => 'not_performed',
  files            => ['Rexfile', 'meta.json'],
  },
  'record_rex_bundle records the bundle metadata in the manifest';

my $default_tmp    = tempdir(CLEANUP => 1);
my $default_ledger = Overnet::Burner::RunLedger->create(
  scenario      => $scenario,
  scenario_path => $scenario_path,
  runs_dir      => "$default_tmp/runs",
  runner_name   => 'preselected-runner',
);
my $default_manifest = _read_manifest($default_ledger->{run_dir});

like $default_ledger->{run_id}, qr/\A\d{8}T\d{6}Z-\d+\z/mx, 'create generates a timestamped default run id';
like $default_manifest->{timestamps}{created_at}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/mx,
  'create uses ISO-8601 UTC timestamps by default';
is $default_manifest->{runner}{name}, 'preselected-runner', 'create records a provided runner name';
ok length $default_manifest->{host_facts}{hostname}, 'create collects host facts by default';
ok length $default_manifest->{host_facts}{os},       'create records the host operating system';
like $default_manifest->{repo_sha}, qr/\A[0-9a-f]{40}\z/mx, 'create records the repository SHA by default';
ok exists $default_manifest->{rex_version}, 'create probes the Rex version by default';

my $duplicate_created = eval {
  Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => "$default_tmp/runs",
    run_id        => $default_ledger->{run_id},
  );
  1;
};
my $duplicate_error = $@;
ok !$duplicate_created, 'create rejects an already existing run directory';
like $duplicate_error, qr/\brun\ already\ exists\b/mx, 'create reports the existing run directory';

my $sibling_ledger = Overnet::Burner::RunLedger->create(
  scenario      => $scenario,
  scenario_path => $scenario_path,
  runs_dir      => "$default_tmp/runs",
  run_id        => 'sibling-run',
);
ok -d $sibling_ledger->{run_dir}, 'create reuses an existing runs directory';

my $symlink_tmp = tempdir(CLEANUP => 1);
make_path("$symlink_tmp/runs");
my $symlink_supported = symlink File::Spec->catdir($symlink_tmp, 'missing-target'),
  File::Spec->catdir($symlink_tmp, 'runs', 'dangling');
if ($symlink_supported) {
  my $symlink_created = eval {
    Overnet::Burner::RunLedger->create(
      scenario      => $scenario,
      scenario_path => $scenario_path,
      runs_dir      => "$symlink_tmp/runs",
      run_id        => 'dangling',
    );
    1;
  };
  my $symlink_error = $@;
  ok !$symlink_created, 'create fails when the run directory cannot be created';
  like $symlink_error, qr/\bmkdir\b/mx, 'create reports the failed mkdir';
}

my $copy_tmp          = tempdir(CLEANUP => 1);
my $copy_fail_created = eval {
  Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => File::Spec->catfile($copy_tmp, 'missing-scenario.yml'),
    runs_dir      => "$copy_tmp/runs",
    run_id        => 'copy-fail',
  );
  1;
};
my $copy_fail_error = $@;
ok !$copy_fail_created, 'create fails when the scenario file cannot be copied';
like $copy_fail_error, qr/\bcopy\b/mx, 'create reports the failed scenario copy';

my $nonrepo_tmp           = tempdir(CLEANUP => 1);
my $nonrepo_scenario_path = File::Spec->catfile($nonrepo_tmp, 'scenario.yml');
File::Copy::copy($scenario_path, $nonrepo_scenario_path)
  or die "copy scenario fixture: $!";
my $nonrepo_ledger = Overnet::Burner::RunLedger->create(
  scenario      => $scenario,
  scenario_path => $nonrepo_scenario_path,
  runs_dir      => "$nonrepo_tmp/runs",
  run_id        => 'nonrepo-run',
);
ok !defined _read_manifest($nonrepo_ledger->{run_dir})->{repo_sha},
  'create records no repo SHA outside a git repository';

my $fake_git_tmp = tempdir(CLEANUP => 1);
_write_executable(
  File::Spec->catfile($fake_git_tmp, 'git'),
  "#!/bin/sh\nprintf '\\n'\nexit 0\n",
);
my $empty_sha_ledger = do {
  local $ENV{PATH} = $fake_git_tmp;
  Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => "$fake_git_tmp/runs",
    run_id        => 'empty-sha-run',
  );
};
ok !defined _read_manifest($empty_sha_ledger->{run_dir})->{repo_sha},
  'create records no repo SHA when git reports an empty revision';

my $no_git_tmp    = tempdir(CLEANUP => 1);
my $no_git_ledger = do {
  local $ENV{PATH} = $no_git_tmp;
  Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => "$no_git_tmp/runs",
    run_id        => 'no-git-run',
  );
};
ok !defined _read_manifest($no_git_ledger->{run_dir})->{repo_sha},
  'create records no repo SHA when git cannot be executed';

sub _read_manifest {
  my ($dir) = @_;

  open my $fh, '<', File::Spec->catfile($dir, 'manifest.json')
    or die "open manifest.json: $!";
  local $/ = undef;
  return JSON::decode_json(<$fh>);
}

sub _write_executable {
  my ($path, $content) = @_;

  open my $fh, '>', $path
    or die "open $path: $!";
  print {$fh} $content
    or die "print $path: $!";
  close $fh
    or die "close $path: $!";
  chmod 0755, $path
    or die "chmod $path: $!";
  return;
}

done_testing;
