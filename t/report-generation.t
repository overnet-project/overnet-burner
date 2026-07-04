use strictures 2;

use Digest::SHA;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use JSON::Schema::Modern;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

my $repo      = "$FindBin::Bin/..";
my $bin       = "$repo/bin/overnet-burner";
my $scenario  = "$repo/scenarios/single-relay-baseline.yml";
my $schema    = _read_json(File::Spec->catfile($repo, 'schemas', 'report-v1.schema.json'),);
my $schema_id = 'https://overnet-project.org/schemas/overnet-burner/report-v1.schema.json';

my $tmp = tempdir(CLEANUP => 1);

my $init_run_id = 'report-init-001';
my $init_run    = `$^X $bin init-run --scenario $scenario --runs-dir $tmp --run-id $init_run_id 2>&1`;
is $?, 0, 'creates initialized run for reporting';
like $init_run, qr{\Acreated\ run:\ \Q$tmp/$init_run_id\E\n?\z}xm, 'init-run reports created run directory';

my $init_run_dir        = File::Spec->catdir($tmp, $init_run_id);
my $init_report_command = `$^X $bin report --run-dir $init_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for initialized run';

my $init_report = _read_json(File::Spec->catfile($init_run_dir, 'report.json'));
_assert_common_report($init_report, $init_run_id);
is $init_report->{run}{status},       'created',       'initialized report records created status';
is $init_report->{run}{verdict},      'not_evaluated', 'initialized report records not evaluated verdict';
is $init_report->{run}{result_class}, 'none',          'initialized report records no result class';
is $init_report->{execution}{runner}, 'none',          'initialized report uses explicit none runner';
is $init_report->{execution}{phases}, [],              'initialized report records no execution phases';

my $noop_run_id = 'report-noop-001';
my $noop_run    = `$^X $bin run --scenario $scenario --runs-dir $tmp --run-id $noop_run_id --runner noop 2>&1`;
is $?, 0, 'creates noop run for reporting';
like $noop_run, qr{\Acompleted\ run:\ \Q$tmp/$noop_run_id\E\nwrote\ report:\ \Q$tmp/$noop_run_id/report.json\E\n?\z}xm,
  'noop run reports completed run directory and generated report';

my $noop_run_dir = File::Spec->catdir($tmp, $noop_run_id);
ok -e File::Spec->catfile($noop_run_dir, 'report.json'), 'noop run writes report.json automatically';
my $noop_report_command = `$^X $bin report --run-dir $noop_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for noop run';
like $noop_report_command, qr{\Awrote\ report:\ \Q$noop_run_dir/report.json\E\n?\z}xm,
  'report command prints report path';
ok -e File::Spec->catfile($noop_run_dir, 'report.json'), 'report command writes report.json';

my $noop_report = _read_json(File::Spec->catfile($noop_run_dir, 'report.json'));
_assert_common_report($noop_report, $noop_run_id);
is $noop_report->{run}{status},       'completed',     'noop report records completed status';
is $noop_report->{run}{verdict},      'smoke_passed',  'noop report classifies completed orchestration as smoke passed';
is $noop_report->{run}{result_class}, 'orchestration', 'noop report records orchestration result class';
is $noop_report->{scenario}{name},           'single-relay-baseline', 'noop report records scenario name';
is $noop_report->{scenario}{seed},           12345,                   'noop report records scenario seed';
is $noop_report->{topology}{provider}{name}, 'generic-relay',         'noop report records topology provider';
is $noop_report->{topology}{provider}{descriptor}, {},
  'noop report uses an empty provider descriptor for generic relay';
is $noop_report->{topology}{actors},
  {
  relays         => 1,
  publishers     => 1,
  subscribers    => 1,
  query_readers  => 1,
  object_readers => 1,
  observers      => 0,
  total          => 5,
  },
  'noop report records actor counts';
is $noop_report->{topology}{hosts}{total},      0,               'noop report does not invent host inventory';
is $noop_report->{execution}{runner},           'noop',          'noop report records runner';
is $noop_report->{execution}{remote_execution}, 'not_performed', 'noop report records no remote execution';
is [map {"$_->{kind}:$_->{name}:$_->{status}"} @{$noop_report->{execution}{phases}}],
  [
  'runner_phase:prepare:completed', 'runner_phase:start:completed',
  'runner_phase:observe:completed', 'runner_phase:stop:completed',
  'runner_phase:collect:completed',
  ],
  'noop report summarizes runner phases';
is $noop_report->{workload}{duration_seconds},                   60,  'noop report records workload duration';
is $noop_report->{workload}{phases}[0]{publish_rate_per_second}, 10,  'noop report records publish rate';
is $noop_report->{workload}{phases}[0]{object_reads_per_second}, 1,   'noop report records object read rate';
is $noop_report->{metrics}{collected},                  JSON::false,  'noop report records no metrics collected';
is $noop_report->{metrics}{reason},                     'smoke_only', 'noop report explains missing metrics';
is $noop_report->{metrics}{streams}{expected},          4,            'noop report records expected metric streams';
is $noop_report->{metrics}{streams}{seen},              0,            'noop report records no seen metric streams';
is scalar @{$noop_report->{metrics}{streams}{missing}}, 4,            'noop report records missing metric streams';
is [map {"$_->{id}:$_->{status}:$_->{reason}"} @{$noop_report->{thresholds}}],
  [
  'error_rate_max:not_evaluated:no_metrics', 'publish_p99_ms:not_evaluated:no_metrics',
  'subscription_fanout_p99_ms:not_evaluated:no_metrics',
  ],
  'noop report marks thresholds not evaluated without metrics';
is $noop_report->{chaos}{hooks_configured}, 0, 'noop report records no configured chaos hooks';
is $noop_report->{chaos}{hooks_executed},   0, 'noop report records no executed chaos hooks';
is $noop_report->{diagnostics}{warnings}[0]{code}, 'no_real_workload',
  'noop report warns that smoke did not run real workload';

my %noop_artifacts = map { $_->{id} => $_ } @{$noop_report->{artifacts}};
for my $id (qw(manifest scenario normalized_config plan runner_log metrics)) {
  ok exists $noop_artifacts{$id}, "noop report includes $id artifact";
  _assert_artifact_hash($noop_run_dir, $noop_artifacts{$id});
}
ok !exists $noop_artifacts{rexfile}, 'noop report does not report absent Rexfile artifact';

my $rex_tmp    = tempdir(CLEANUP => 1);
my $fake_rex   = _write_fake_rex($rex_tmp);
my $rex_log    = File::Spec->catfile($rex_tmp, 'fake-rex.log');
my $rex_run_id = 'report-rex-local-001';
{
  local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
  local $ENV{OVERNET_BURNER_TEST_REX_LOG} = $rex_log;
  my $rex_run = `$^X $bin run --scenario $scenario --runs-dir $tmp --run-id $rex_run_id --runner rex-local 2>&1`;
  is $?, 0, 'creates rex-local run for reporting';
  like $rex_run,
    qr{\Acompleted\ run:\ \Q$tmp/$rex_run_id\E\nwrote\ report:\ \Q$tmp/$rex_run_id/report.json\E\n?\z}xm,
    'rex-local run reports completed run directory and generated report';
}

my $rex_run_dir = File::Spec->catdir($tmp, $rex_run_id);
ok -e File::Spec->catfile($rex_run_dir, 'report.json'), 'rex-local run writes report.json automatically';
my $rex_report_command = `$^X $bin report --run-dir $rex_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for rex-local run';
like $rex_report_command, qr{\Awrote\ report:\ \Q$rex_run_dir/report.json\E\n?\z}xm,
  'rex-local report command prints report path';

my $rex_report = _read_json(File::Spec->catfile($rex_run_dir, 'report.json'));
_assert_common_report($rex_report, $rex_run_id);
is $rex_report->{execution}{runner},               'rex-local', 'rex report records rex-local runner';
is $rex_report->{topology}{hosts}{total},          1,           'rex report records rendered host inventory';
is $rex_report->{topology}{hosts}{groups}{relays}, 1,           'rex report records relay host group count';
ok scalar grep({ $_->{kind} eq 'rex_task' && $_->{name} eq 'bootstrap' && $_->{status} eq 'completed' }
  @{$rex_report->{execution}{phases}}),
  'rex report includes completed bootstrap Rex task phase';
ok scalar grep({ $_->{kind} eq 'rex_task' && $_->{name} eq 'cleanup' && $_->{status} eq 'completed' }
  @{$rex_report->{execution}{phases}}),
  'rex report includes completed cleanup Rex task phase';

my %rex_artifacts = map { $_->{id} => $_ } @{$rex_report->{artifacts}};
for my $id (qw(rex_bundle rexfile rex_lifecycle rex_inventory rex_topology_provider)) {
  ok exists $rex_artifacts{$id}, "rex report includes $id artifact";
  _assert_artifact_hash($rex_run_dir, $rex_artifacts{$id});
}

my $failed_run_id = 'report-failed-001';
my $failed_run    = `$^X $bin run --scenario $scenario --runs-dir $tmp --run-id $failed_run_id --runner missing 2>&1`;
is $? >> 8, 2, 'creates failed run for reporting';
like $failed_run, qr/unknown\ runner:\ missing/mx, 'failed run reports runner error';

my $failed_run_dir = File::Spec->catdir($tmp, $failed_run_id);
ok -e File::Spec->catfile($failed_run_dir, 'report.json'), 'failed run writes report.json automatically';
my $failed_report_command = `$^X $bin report --run-dir $failed_run_dir 2>&1`;
is $?, 0, 'report command exits successfully for failed run';

my $failed_report = _read_json(File::Spec->catfile($failed_run_dir, 'report.json'));
_assert_common_report($failed_report, $failed_run_id);
is $failed_report->{run}{status},       'failed',                'failed report records failed status';
is $failed_report->{run}{verdict},      'orchestration_failed',  'failed report records orchestration failure verdict';
is $failed_report->{run}{result_class}, 'orchestration',         'failed report keeps orchestration result class';
is $failed_report->{execution}{runner}, 'missing',               'failed report records requested runner';
is $failed_report->{diagnostics}{errors}[0]{code}, 'run_failed', 'failed report records structured run failure';
like $failed_report->{diagnostics}{errors}[0]{message}, qr/unknown\ runner:\ missing/mx,
  'failed report records run failure message';

my $missing_report = `$^X $bin report --run-dir $tmp/missing-run 2>&1`;
is $? >> 8, 2, 'report command rejects missing run directory';
like $missing_report, qr/run\ directory\ does\ not\ exist/mx, 'report command explains missing run directory';

subtest 'collected metrics are summarized and a failed threshold fails the run' => sub {
  my $run_dir = _run_with_metric_streams(
    'report-metrics-fail-001',
    'publisher-001' => [
      _metric_event(duration_ms => 10),
      _metric_event(duration_ms => 20),
      _metric_event(duration_ms => 30),
      _metric_event(duration_ms => 40),
      _metric_event(duration_ms => 500, status => 'error', error => 'publish timed out'),
    ],
    'subscriber-001' => [
      _metric_event(operation => 'subscription_fanout', role => 'subscriber', duration_ms => 100),
      _metric_event(operation => 'subscription_fanout', role => 'subscriber', duration_ms => 200),
    ],
    'query-reader-001' => [
      _metric_event(operation => 'query', role => 'query_reader', duration_ms => 50),
      _metric_event(operation => 'query', role => 'query_reader', duration_ms => 60),
    ],
    'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
  );

  my $report = _regenerated_report($run_dir);

  is $report->{metrics}{collected},     JSON::true, 'metrics are collected when all streams exist';
  is $report->{metrics}{reason},        'none',     'collected metrics need no excuse';
  is $report->{metrics}{streams}{seen}, 4,          'every declared worker stream is seen';
  is $report->{metrics}{operations}{publish},
    {
    count         => 5,
    success_count => 4,
    error_count   => 1,
    error_rate    => 0.2,
    latency_ms    => {min => 10, p50 => 20, p90 => 40, p95 => 40, p99 => 40, max => 40, mean => 25},
    },
    'publish operation summary matches the streams';

  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{publish_p99_ms}{status},             'passed', 'publish p99 threshold passes';
  is $thresholds{publish_p99_ms}{observed_value},     40,       'publish p99 records observed value';
  is $thresholds{publish_p99_ms}{reason},             'none',   'evaluated threshold needs no excuse';
  is $thresholds{subscription_fanout_p99_ms}{status}, 'passed', 'fanout p99 threshold passes';
  is $thresholds{error_rate_max}{status},             'failed', 'error rate threshold fails';
  is $thresholds{error_rate_max}{observed_value},     0.1,      'error rate threshold records overall rate';

  is $report->{run}{verdict},      'performance_failed', 'failed threshold fails the run verdict';
  is $report->{run}{result_class}, 'performance',        'evaluated thresholds classify the run as performance';
};

subtest 'passing thresholds yield a performance_passed verdict' => sub {
  my $run_dir = _run_with_metric_streams(
    'report-metrics-pass-001',
    'publisher-001'  => [map { _metric_event(duration_ms => 10 + $_) } 1 .. 5],
    'subscriber-001' => [_metric_event(operation => 'subscription_fanout', role => 'subscriber', duration_ms => 100)],
    'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
    'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
  );

  my $report = _regenerated_report($run_dir);

  my %thresholds = map { $_->{id} => $_->{status} } @{$report->{thresholds}};
  is \%thresholds,
    {
    publish_p99_ms             => 'passed',
    subscription_fanout_p99_ms => 'passed',
    error_rate_max             => 'passed',
    },
    'all thresholds pass';
  is $report->{run}{verdict},      'performance_passed', 'clean thresholds pass the run verdict';
  is $report->{run}{result_class}, 'performance',        'run is classified as performance';
};

subtest 'a threshold without its metric is inconclusive' => sub {
  my $run_dir = _run_with_metric_streams(
    'report-metrics-missing-001',
    'publisher-001'     => [map { _metric_event(duration_ms => 10 + $_) } 1 .. 5],
    'subscriber-001'    => [_metric_event(operation => 'noop_probe',  role => 'subscriber',    duration_ms => 1)],
    'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
    'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
  );

  my $report = _regenerated_report($run_dir);

  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{subscription_fanout_p99_ms}{status}, 'not_evaluated',  'missing metric is not evaluated';
  is $thresholds{subscription_fanout_p99_ms}{reason}, 'metric_missing', 'missing metric names the reason';
  is $thresholds{publish_p99_ms}{status},             'passed',         'present metrics still evaluate';
  is $report->{run}{verdict}, 'inconclusive_partial_run',
    'a configured threshold without its metric makes the run inconclusive';
  is $report->{run}{result_class}, 'performance', 'inconclusive threshold runs stay performance-classified';
};

subtest 'reader operations are judged by thresholds' => sub {
  my $scenario_readers = File::Spec->catfile($tmp, 'reader-thresholds.yml');
  _write_text($scenario_readers, <<'YAML');
run:
  name: reader-thresholds
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
  subscribers:
    count: 0
  query_readers:
    count: 1
  object_readers:
    count: 1
workload:
  publish_rate_per_second: 10
  query_filters:
    - kinds: [7800]
  object_reads:
    objects:
      - type: chat.channel
        id: irc:local:#overnet
thresholds:
  query_p99_ms: 100
  object_read_p99_ms: 100
  query.latency_ms.p50: 60
YAML

  my $run_dir = _run_with_metric_streams(
    'report-reader-thresholds-001',
    -scenario          => $scenario_readers,
    'publisher-001'    => [_metric_event(duration_ms => 10)],
    'query-reader-001' => [
      _metric_event(operation => 'query', role => 'query_reader', duration_ms => 50),
      _metric_event(operation => 'query', role => 'query_reader', duration_ms => 60),
    ],
    'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 150)],
  );

  my $report = _regenerated_report($run_dir);

  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{query_p99_ms}{status},         'passed',               'query p99 threshold evaluates';
  is $thresholds{query_p99_ms}{observed_value}, 60,                     'query p99 records the observed value';
  is $thresholds{query_p99_ms}{metric},         'query.latency_ms.p99', 'query p99 resolves its registry metric';
  is $thresholds{object_read_p99_ms}{status},   'failed',               'object read p99 threshold evaluates';
  is $thresholds{object_read_p99_ms}{observed_value},     150,          'object read p99 records the observed value';
  is $thresholds{'query.latency_ms.p50'}{status},         'passed',     'a raw metric path is a usable threshold id';
  is $thresholds{'query.latency_ms.p50'}{observed_value}, 50,           'raw path threshold records the observed value';

  is $report->{run}{verdict}, 'performance_failed', 'the failed reader threshold fails the run';
};

subtest 'a run with abuse workers is judged as a resilience experiment' => sub {
  my $scenario_abuse = File::Spec->catfile($tmp, 'abuse.yml');
  _write_text($scenario_abuse, <<'YAML');
run:
  name: abuse
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
  flooders:
    count: 1
workload:
  publish_rate_per_second: 10
  abuse:
    flooder:
      publish_rate_per_second: 5000
thresholds:
  flood_publish.defended_ratio: 0.9
  flood_publish.defended_correct_ratio: 0.9
  publish_p99_ms: 100
YAML

  my $defended = sub {
    my ($correct) = @_;
    return _metric_event(
      worker_id        => 'flooder-001',
      role             => 'flooder',
      operation        => 'flood_publish',
      status           => 'error',
      error            => 'rate-limited: slow down',
      outcome          => 'rejected',
      error_category   => ($correct ? 'policy rejection' : 'invalid input'),
      defended         => JSON::true,
      defended_correct => ($correct ? JSON::true : JSON::false),
    );
  };

  my $pass_dir = _run_with_metric_streams(
    'report-abuse-pass-001',
    -scenario       => $scenario_abuse,
    'publisher-001' => [_metric_event(duration_ms => 20)],
    'flooder-001'   => [map { $defended->(1) } 1 .. 10],
  );
  my $pass = _regenerated_report($pass_dir);

  my %pass_thresholds = map { $_->{id} => $_ } @{$pass->{thresholds}};
  is $pass_thresholds{'flood_publish.defended_ratio'}{comparator}, '>=',
    'defended ratio thresholds are judged as a floor, not a ceiling';
  is $pass_thresholds{'flood_publish.defended_ratio'}{observed_value}, 1, 'a fully defended flood observes ratio 1';
  is $pass_thresholds{'flood_publish.defended_ratio'}{status},         'passed', 'the defense floor is met';
  is $pass->{run}{verdict},       'resilience_passed', 'a defended run passes the resilience experiment';
  is $pass->{run}{result_class},  'resilience',        'an abuse run is a resilience experiment, not performance';
  is $pass->{run}{perturbations}, ['abuse'],           'the run records abuse as its perturbation mechanism';

  my $fail_dir = _run_with_metric_streams(
    'report-abuse-fail-001',
    -scenario       => $scenario_abuse,
    'publisher-001' => [_metric_event(duration_ms => 20)],
    'flooder-001'   => [
      (map { $defended->(1) } 1 .. 5),
      (
        map {
          _metric_event(
            worker_id        => 'flooder-001',
            role             => 'flooder',
            operation        => 'flood_publish',
            status           => 'success',
            outcome          => 'accepted',
            defended         => JSON::false,
            defended_correct => JSON::false,
          )
        } 1 .. 5
      )
    ],
  );
  my $fail = _regenerated_report($fail_dir);

  my %fail_thresholds = map { $_->{id} => $_ } @{$fail->{thresholds}};
  is $fail_thresholds{'flood_publish.defended_ratio'}{observed_value}, 0.5,      'half the flood got through';
  is $fail_thresholds{'flood_publish.defended_ratio'}{status},         'failed', 'the defense floor is not met';
  is $fail->{run}{verdict},      'resilience_failed', 'a run that let abuse through fails the resilience experiment';
  is $fail->{run}{result_class}, 'resilience',        'the failing run is still a resilience experiment';
};

subtest 'a run with both chaos and abuse is one resilience experiment' => sub {
  my $scenario_mixed = File::Spec->catfile($tmp, 'mixed.yml');
  _write_text($scenario_mixed, <<'YAML');
run:
  name: mixed
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
  flooders:
    count: 1
workload:
  publish_rate_per_second: 10
  abuse:
    flooder:
      publish_rate_per_second: 5000
chaos:
  - at: 5
    action: restart
    target: relay:1
thresholds:
  flood_publish.defended_ratio: 0.9
  publish_p99_ms: 5
YAML

  my $defended = _metric_event(
    worker_id        => 'flooder-001',
    role             => 'flooder',
    operation        => 'flood_publish',
    status           => 'error',
    error            => 'rate-limited: slow down',
    outcome          => 'rejected',
    error_category   => 'policy rejection',
    defended         => JSON::true,
    defended_correct => JSON::true,
  );

  my $run_dir = _run_with_metric_streams(
    'report-mixed-001',
    -scenario       => $scenario_mixed,
    'publisher-001' => [_metric_event(duration_ms => 20)],
    'flooder-001'   => [map {$defended} 1 .. 10],
  );

  # The chaos hook is scheduled in the plan but the noop runner does not fire
  # it, so record its execution in the runner log the report reads from.
  _record_chaos_hook($run_dir, 'chaos-001');

  my $report = _regenerated_report($run_dir);

  is $report->{chaos}{hooks_executed}, 1, 'the injected chaos hook is counted as executed';
  is $report->{run}{result_class}, 'resilience',
    'a run with both mechanisms is a single resilience experiment, not one class winning';
  is $report->{run}{perturbations}, ['abuse', 'chaos'], 'the run records both perturbation mechanisms it ran';

  # The failing threshold is the collateral publish latency, a performance
  # signal, yet the verdict is the unified resilience verdict rather than
  # being misattributed to whichever mechanism happened to win precedence.
  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{'flood_publish.defended_ratio'}{status}, 'passed', 'the defense floor is met';
  is $thresholds{publish_p99_ms}{status},                 'failed', 'the collateral latency threshold fails';
  is $report->{run}{verdict}, 'resilience_failed',
    'any threshold failure in a perturbation run is a single resilience_failed verdict';
};

subtest 'cross-host clock evidence is judged when fanout crosses hosts' => sub {
  my $scenario_clock = File::Spec->catfile($tmp, 'clock.yml');
  _write_text($scenario_clock, <<'YAML');
run:
  name: clock
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 10
  subscription_filters:
    - kinds: [7800]
thresholds:
  subscription_fanout_p99_ms: 1000
YAML

  # A remote host whose clock is off by more than the whole fanout budget
  # makes any cross-host fanout number untrustworthy.
  my $skew_dir = _run_with_metric_streams(
    'report-clock-skew-001',
    -scenario       => $scenario_clock,
    'publisher-001' => [_metric_event(duration_ms => 20)],
  );
  _write_clocks($skew_dir,
    [{name => 'worker-guest-001', transport => 'ssh', role => 'workers', offset_ms => 5000, round_trip_ms => 3}]);
  my $skew          = _regenerated_report($skew_dir);
  my %skew_warnings = map { $_->{code} => $_ } @{$skew->{diagnostics}{warnings}};
  ok $skew_warnings{cross_host_clock_skew}, 'a remote clock beyond the fanout bound is flagged as skew';

  # A remote host whose clock could not be measured is flagged as unverified.
  my $unverified_dir = _run_with_metric_streams(
    'report-clock-unverified-001',
    -scenario       => $scenario_clock,
    'publisher-001' => [_metric_event(duration_ms => 20)],
  );
  _write_clocks($unverified_dir,
    [{name => 'worker-guest-001', transport => 'ssh', role => 'workers', offset_ms => undef, round_trip_ms => undef}]);
  my $unverified          = _regenerated_report($unverified_dir);
  my %unverified_warnings = map { $_->{code} => $_ } @{$unverified->{diagnostics}{warnings}};
  ok $unverified_warnings{cross_host_clock_unverified}, 'an unmeasured remote clock is flagged as unverified';

  # A local-only run has one clock, so cross-host skew cannot apply.
  my $local_dir = _run_with_metric_streams(
    'report-clock-local-001',
    -scenario       => $scenario_clock,
    'publisher-001' => [_metric_event(duration_ms => 20)],
  );
  _write_clocks($local_dir,
    [{name => 'local', transport => 'exec', role => 'workers', offset_ms => 0, round_trip_ms => 0}]);
  my $local = _regenerated_report($local_dir);
  my @local_clock_warnings =
    grep { $_->{code} =~ /\Across_host_clock/mxs } @{$local->{diagnostics}{warnings}};
  is \@local_clock_warnings, [], 'a local-only run raises no cross-host clock warning';
};

subtest 'multi-phase runs are judged on the main phase only' => sub {
  my $scenario_phased = File::Spec->catfile($tmp, 'phased.yml');
  _write_text($scenario_phased, <<'YAML');
run:
  name: phased
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
workload:
  publish_rate_per_second: 10
  warmup:
    duration: 10
thresholds:
  error_rate_max: 0.1
YAML

  my $run_dir = _run_with_metric_streams(
    'report-phased-001',
    -scenario       => $scenario_phased,
    'publisher-001' => [
      _metric_event(phase => 'warmup', status      => 'error', error => 'cold start', duration_ms => 400),
      _metric_event(phase => 'main',   duration_ms => 10),
      _metric_event(phase => 'main',   duration_ms => 20),
    ],
  );

  my $report = _regenerated_report($run_dir);

  is $report->{metrics}{operations}{publish}{count},      2, 'only main phase events are summarized';
  is $report->{metrics}{operations}{publish}{error_rate}, 0, 'warmup errors do not reach the summary';
  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{error_rate_max}{status},         'passed',             'warmup errors do not fail thresholds';
  is $thresholds{error_rate_max}{observed_value}, 0,                    'the judged error rate is the main phase rate';
  is $report->{run}{verdict},                     'performance_passed', 'the run is judged on its steady state';
  is $report->{workload}{duration_seconds},       70, 'the report workload duration is the total window';
};

subtest 'an untagged event in a multi-phase run is a configuration error' => sub {
  my $scenario_phased = File::Spec->catfile($tmp, 'phased.yml');
  my $run_dir         = _run_with_metric_streams(
    'report-phased-untagged-001',
    -scenario       => $scenario_phased,
    'publisher-001' => [_metric_event(phase => 'main', duration_ms => 10), _metric_event(duration_ms => 20),],
  );

  my $report = _regenerated_report($run_dir);

  is $report->{metrics}{collected}, JSON::false,               'untagged events make metrics uncollectable';
  is $report->{metrics}{reason},    'configuration_error',     'the reason is a configuration error';
  is $report->{run}{verdict},       'inconclusive_no_metrics', 'the run cannot be judged';
};

subtest 'a corrupt metric stream is surfaced instead of summarized around' => sub {
  my $run_dir = _run_with_metric_streams(
    'report-metrics-corrupt-001',
    'publisher-001'  => [_metric_event(duration_ms => 10)],
    'subscriber-001' => [_metric_event(operation   => 'subscription_fanout', role => 'subscriber', duration_ms => 100)],
    'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
    'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
  );

  open my $fh, '>>', File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl') or die "append: $!";
  print {$fh} "not json\n" or die "print: $!";
  close $fh                or die "close: $!";

  my $report = _regenerated_report($run_dir);

  is $report->{metrics}{collected},      JSON::false,           'corrupt streams do not count as collected';
  is $report->{metrics}{reason},         'configuration_error', 'corrupt streams are named a configuration error';
  is $report->{metrics}{operations}, {}, 'no summaries are produced from corrupt streams';
  is $report->{run}{verdict},            'inconclusive_no_metrics', 'corrupt metrics make the run inconclusive';
  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{publish_p99_ms}{status}, 'not_evaluated',       'thresholds are not evaluated on corrupt metrics';
  is $thresholds{publish_p99_ms}{reason}, 'configuration_error', 'threshold reason names the configuration error';
};

done_testing;

sub _metric_event {
  my (%overrides) = @_;
  my %event = (
    metric_version => 1,
    run_id         => 'run-metrics',
    worker_id      => 'publisher-001',
    host           => 'host-test',
    role           => 'publisher',
    operation      => 'publish',
    started_at     => '2026-07-02T18:00:00Z',
    finished_at    => '2026-07-02T18:00:00.010Z',
    duration_ms    => 10,
    status         => 'success',
    %overrides,
  );
  return \%event;
}

sub _run_with_metric_streams {
  my ($run_id, %streams_by_actor) = @_;

  my $scenario_path = delete $streams_by_actor{-scenario} || $scenario;
  my $run           = `$^X $bin run --scenario $scenario_path --runs-dir $tmp --run-id $run_id --runner noop 2>&1`;
  is $?, 0, "$run_id run completes";
  my $run_dir = File::Spec->catdir($tmp, $run_id);

  my $metrics_dir = File::Spec->catdir($run_dir, 'metrics');
  mkdir $metrics_dir or die "mkdir $metrics_dir: $!";

  my $json       = JSON->new->canonical(1);
  my $aggregated = q{};
  for my $actor (sort keys %streams_by_actor) {
    my $content = join q{}, map { $json->encode($_) . "\n" } @{$streams_by_actor{$actor}};
    _write_text(File::Spec->catfile($metrics_dir, "$actor.jsonl"), $content);
    $aggregated .= $content;
  }
  _write_text(File::Spec->catfile($run_dir, 'metrics.jsonl'), $aggregated);

  return $run_dir;
}

sub _regenerated_report {
  my ($run_dir) = @_;
  my $output = `$^X $bin report --run-dir $run_dir 2>&1`;
  is $?, 0, 'report command succeeds' or diag($output);
  return _read_json(File::Spec->catfile($run_dir, 'report.json'));
}

sub _write_text {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}

sub _write_clocks {
  my ($run_dir, $guests) = @_;
  my $json = JSON->new->canonical(1);
  _write_text(
    File::Spec->catfile($run_dir, 'clocks.json'),
    $json->encode({measured_at => '2026-06-27T20:01:57Z', guests => $guests}),
  );
  return;
}

sub _record_chaos_hook {
  my ($run_dir, $hook_id) = @_;
  my $logs_dir = File::Spec->catdir($run_dir, 'logs');
  make_path($logs_dir);
  my $path = File::Spec->catfile($logs_dir, 'runner.jsonl');
  my $json = JSON->new->canonical(1);
  open my $fh, '>>', $path or die "open $path: $!";
  for my $status (qw(started completed)) {
    print {$fh} $json->encode(
      {
        runner     => 'noop',
        phase      => 'observe',
        event_kind => 'chaos_hook',
        hook_id    => $hook_id,
        action     => 'restart',
        target     => 'relay:1',
        actor_id   => 'relay-001',
        status     => $status,
        timestamp  => '2026-06-27T20:01:5' . ($status eq 'started' ? '7Z' : '8Z'),
      }
      )
      . "\n"
      or die "print $path: $!";
  }
  close $fh or die "close $path: $!";
  return;
}

sub _assert_common_report {
  my ($report, $run_id) = @_;

  _assert_schema_valid($report, $run_id);
  is $report->{report_version}, 1,          "$run_id report uses v1";
  is $report->{schema},         $schema_id, "$run_id report records schema id";
  ok $report->{generated_at}, "$run_id report records generated timestamp";
  is $report->{run}{id},               $run_id,        "$run_id report records run id";
  is $report->{scenario}{source_path}, 'scenario.yml', "$run_id report records scenario artifact path";
  is $report->{scenario}{normalized_config_path}, 'config.normalized.json',
    "$run_id report records normalized config artifact path";
  is $report->{scenario}{plan_path}, 'plan.json', "$run_id report records plan artifact path";
  ok exists $report->{environment}{host}{hostname}, "$run_id report records host facts";
  ok exists $report->{environment}{perl_version},   "$run_id report records Perl version";
  ok exists $report->{environment}{rex_version},    "$run_id report records Rex version";
  ok exists $report->{extensions},                  "$run_id report has extension point";
  ok $report->{human_summary}{headline},            "$run_id report has human headline";
  return;
}

sub _assert_schema_valid {
  my ($report, $run_id) = @_;

  my $result = JSON::Schema::Modern->new->evaluate($report, $schema);
  ok $result->valid, "$run_id report validates against report-v1 schema"
    or diag(JSON->new->canonical(1)->pretty(1)->encode($result->TO_JSON));
  return;
}

sub _assert_artifact_hash {
  my ($run_dir, $artifact) = @_;

  my $path = File::Spec->catfile($run_dir, $artifact->{path});
  ok -e $path, "$artifact->{id} artifact exists at reported path";
  is $artifact->{size_bytes}, -s $path,            "$artifact->{id} artifact records size";
  is $artifact->{sha256},     _sha256_file($path), "$artifact->{id} artifact records sha256";
  return;
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
  local $/ = undef;
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
