use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Report;
use Overnet::Burner::Runner;
use Overnet::Burner::RunLedger;

my $repo          = "$FindBin::Bin/..";
my $baseline_path = "$repo/scenarios/single-relay-baseline.yml";
my $tmp           = tempdir(CLEANUP => 1);
my $json          = JSON->new->canonical(1);

subtest 'build validates its run directory argument' => sub {
  my $built = eval { Overnet::Burner::Report->build; 1 };
  ok !$built, 'build requires a run directory';
  like $@, qr/run_dir\ is\ required/mx, 'the missing run directory is reported';

  $built = eval { Overnet::Burner::Report->build(run_dir => File::Spec->catdir($tmp, 'absent')); 1 };
  ok !$built, 'build rejects a run directory that does not exist';
  like $@, qr/run\ directory\ does\ not\ exist/mx, 'the absent run directory is reported';
};

subtest 'runs that never completed are not evaluated' => sub {
  my $created = _build_report(_ledgered_run(run_id => 'created', status => 'created'));
  is $created->{run}{status},       'created',       'an initialized run reports created status';
  is $created->{run}{verdict},      'not_evaluated', 'an initialized run is not evaluated';
  is $created->{run}{result_class}, 'none',          'an initialized run has no result class';
  is $created->{execution}{runner}, 'none',          'an initialized run names no runner';
  is $created->{execution}{phases}, [],              'an initialized run has no phases';
  ok !defined $created->{run}{duration_ms}, 'an unstarted run has no duration';

  my $running = _build_report(_ledgered_run(run_id => 'running', status => 'running'));
  is $running->{run}{status},  'running',       'a started run reports running status';
  is $running->{run}{verdict}, 'not_evaluated', 'a running run is not evaluated';

  my $aborted = _build_report(_ledgered_run(run_id => 'aborted', status => 'aborted'));
  is $aborted->{run}{verdict},      'aborted',       'an aborted run reports an aborted verdict';
  is $aborted->{run}{result_class}, 'orchestration', 'an aborted run is an orchestration result';

  my $odd = _build_report(_ledgered_run(run_id => 'odd-status', status => 'paused'));
  is $odd->{run}{verdict},      'not_evaluated', 'an unknown terminal status is not evaluated';
  is $odd->{run}{result_class}, 'none',          'an unknown terminal status has no result class';
};

subtest 'a failed run reports the orchestration failure' => sub {
  my $run_dir = _ledgered_run(run_id => 'failed', status => 'failed', error => 'relay exploded');
  my $report  = _build_report($run_dir);

  is $report->{run}{verdict},      'orchestration_failed', 'a failed run fails orchestration';
  is $report->{run}{result_class}, 'orchestration',        'a failed run is an orchestration result';
  is $report->{diagnostics}{errors}[0]{code},    'run_failed',     'the failure is a structured diagnostic';
  is $report->{diagnostics}{errors}[0]{message}, 'relay exploded', 'the diagnostic carries the manifest error';
  is $report->{human_summary}{headline}, 'Run failed during orchestration.', 'the headline names the failure';
  is $report->{human_summary}{important_notes}, ['relay exploded'], 'the notes carry the manifest error';
  is [map { $_->{reason} } @{$report->{thresholds}}],
    [('run_failed') x 3],
    'thresholds on a failed run are excused as run_failed';

  my $bare = _build_report(_ledgered_run(run_id => 'failed-bare', status => 'failed'));
  is $bare->{diagnostics}{errors}[0]{message}, 'run failed', 'a failed run without a message uses a fallback';
  is $bare->{human_summary}{important_notes}, ['run failed'], 'the fallback reaches the human summary';
};

subtest 'a completed smoke run passes orchestration only' => sub {
  my $run_dir = _ledgered_run(run_id => 'smoke', status => 'completed');
  my $report  = _build_report($run_dir);

  is $report->{run}{verdict},      'smoke_passed',  'a metricless completed run is a smoke pass';
  is $report->{run}{result_class}, 'orchestration', 'a smoke run is an orchestration result';
  is $report->{run}{perturbations}, [], 'a smoke run ran no perturbations';
  ok defined $report->{run}{duration_ms}, 'a finished run has a duration';
  is $report->{metrics}{reason}, 'smoke_only', 'missing metrics on a completed run are smoke only';
  is $report->{execution}{remote_execution}, 'not_performed', 'no Rex bundle means no remote execution';
  is [map {"$_->{kind}:$_->{name}:$_->{status}"} @{$report->{execution}{phases}}],
    [
    'runner_phase:prepare:completed', 'runner_phase:start:completed',
    'runner_phase:observe:completed', 'runner_phase:stop:completed',
    'runner_phase:collect:completed',
    ],
    'the runner phases are summarized';
  is $report->{diagnostics}{warnings}[0]{code}, 'no_real_workload', 'the smoke run warns about missing workload';
  is $report->{topology}{hosts}, {total => 0, groups => {}}, 'no inventory yields no hosts';
  is $report->{workload}{phases}[0]{publish_rate_per_second}, 10, 'the workload phases are summarized';
  ok exists $report->{scenario}{name}, 'the scenario is summarized';
  ok((grep { $_->{id} eq 'manifest' } @{$report->{artifacts}}), 'required artifacts are listed');
  ok !(grep { $_->{id} eq 'rexfile' } @{$report->{artifacts}}), 'absent artifacts are not listed';

  my $path = Overnet::Burner::Report->write_report(run_dir => $run_dir, now => sub {'2026-07-13T13:00:00Z'});
  ok -e $path, 'write_report writes report.json';
  my $written = _read_json($path);
  is $written->{generated_at}, '2026-07-13T13:00:00Z', 'the written report uses the injected clock';
};

subtest 'a recorded Rex bundle drives execution and topology evidence' => sub {
  my $run_dir = _ledgered_run(
    run_id    => 'rex-evidence',
    status    => 'completed',
    customize => sub {
      my ($ledger) = @_;
      my $rex_dir = File::Spec->catdir($ledger->{run_dir}, 'artifacts', 'rex');
      make_path(File::Spec->catdir($rex_dir, 'inventory'));
      _write_text(File::Spec->catfile($rex_dir, 'bundle.json'),    $json->encode({execution => 'performed'}));
      _write_text(File::Spec->catfile($rex_dir, 'Rexfile'),        "# rexfile\n");
      _write_text(File::Spec->catfile($rex_dir, 'lifecycle.json'), $json->encode({commands => []}));
      _write_text(
        File::Spec->catfile($rex_dir, 'inventory', 'hosts.json'),
        $json->encode(
          {
            hosts  => [{id => 'host-1'}, {id => 'host-2'}],
            groups => {relays => ['host-1'], workers => ['host-1', 'host-2']},
          },
        ),
      );
      _write_text(File::Spec->catfile($rex_dir, 'topology-provider.json'), $json->encode({relays => []}));
      $ledger->record_rex_bundle(relative_dir => 'artifacts/rex', files => ['Rexfile']);
    },
  );
  my $report = _build_report($run_dir);

  is $report->{execution}{remote_execution}, 'not_performed', 'the manifest bundle reports its execution state';
  is $report->{topology}{hosts},
    {total => 2, groups => {relays => 1, workers => 2}},
    'the rendered inventory is summarized into host counts';
  ok((grep { $_->{id} eq 'rexfile' } @{$report->{artifacts}}), 'bundle artifacts are listed once present');
};

subtest 'provider commands, rex tasks, and odd timestamps become phases' => sub {
  my $run_dir = _ledgered_run(
    run_id    => 'phase-kinds',
    status    => 'completed',
    customize => sub {
      my ($ledger) = @_;
      $ledger->append_runner_event(
        {
          runner       => 'noop',
          phase        => 'start',
          actor_id     => 'relay-001',
          command_kind => 'start',
          command      => 'exit 0',
          status       => 'started',
          stdout_path  => 'logs/provider/relay-001-start.stdout',
          stderr_path  => 'logs/provider/relay-001-start.stderr',
        },
      );
      $ledger->append_runner_event(
        {
          runner       => 'noop',
          phase        => 'start',
          actor_id     => 'relay-001',
          command_kind => 'start',
          command      => 'exit 0',
          status       => 'completed',
          exit_code    => 0,
          stdout_path  => 'logs/provider/relay-001-start.stdout',
        },
      );
      $ledger->append_runner_event({runner => 'noop', phase => 'start', rex_task => 'bootstrap', status => 'started'});
      $ledger->append_runner_event(
        {
          runner   => 'noop',
          phase    => 'start',
          rex_task => 'bootstrap',
          status   => 'failed',
          error    => 'task exploded',
        },
      );
      $ledger->append_runner_event(
        {
          runner       => 'noop',
          phase        => 'stop',
          actor_id     => 'relay-001',
          command_kind => 'stop',
          command      => 'exit 0',
          status       => 'completed',
          exit_code    => 0,
          stderr_path  => 'logs/provider/relay-001-stop.stderr',
        },
      );
      $ledger->append_runner_event(
        {
          runner    => 'noop',
          phase     => 'warp',
          status    => 'started',
          timestamp => 'not-a-timestamp',
        },
      );
      $ledger->append_runner_event({runner => 'noop', phase => 'warp', status => 'completed'});
    },
  );
  my $report = _build_report($run_dir);

  my %phases = map { $_->{id} => $_ } @{$report->{execution}{phases}};
  my $provider = $phases{'provider-relay-001-start'};
  ok $provider, 'a provider command becomes a provider phase';
  is $provider->{kind},      'provider_command', 'the provider phase records its kind';
  is $provider->{exit_code}, 0,                  'the provider phase records the exit code';
  is $provider->{artifacts},
    [{id => 'relay-001-start-stdout', path => 'logs/provider/relay-001-start.stdout'}],
    'the final provider event decides the artifact references';
  ok defined $provider->{duration_ms}, 'the provider phase has a duration';

  my $rex = $phases{'rex-bootstrap'};
  ok $rex, 'a rex task becomes a rex phase';
  is $rex->{status}, 'failed',        'the rex phase records the failure';
  is $rex->{error},  'task exploded', 'the rex phase records the error';

  my $stop = $phases{'provider-relay-001-stop'};
  is $stop->{artifacts}, [{id => 'relay-001-stop-stderr', path => 'logs/provider/relay-001-stop.stderr'}],
    'a stderr-only event yields one artifact reference';

  my $warp = $phases{'runner-warp'};
  ok !defined $warp->{duration_ms}, 'an unparseable timestamp yields no duration';
};

subtest 'collected metrics judge thresholds and the verdict' => sub {
  my $failing = _build_report(
    _ledgered_run(
      run_id  => 'metrics-failing',
      status  => 'completed',
      metrics => {
        'publisher-001' => [
          _metric_event(duration_ms => 10),
          _metric_event(duration_ms => 40),
          _metric_event(duration_ms => 500, status => 'error', error => 'publish timed out'),
        ],
        'subscriber-001' =>
          [_metric_event(operation => 'subscription_fanout', role => 'subscriber', duration_ms => 100)],
        'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
        'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
      },
    ),
  );
  is $failing->{metrics}{collected}, JSON::true, 'all streams present collects metrics';
  my %failing_thresholds = map { $_->{id} => $_ } @{$failing->{thresholds}};
  is $failing_thresholds{publish_p99_ms}{status}, 'passed', 'the latency threshold passes';
  is $failing_thresholds{error_rate_max}{status}, 'failed', 'the error rate threshold fails';
  is $failing->{run}{verdict},      'performance_failed', 'a failed threshold fails the run';
  is $failing->{run}{result_class}, 'performance',        'an unperturbed run is a performance result';
  like $failing->{human_summary}{important_notes}[0], qr/Failed\ thresholds:\ error_rate_max/mx,
    'the failed thresholds are named in the summary';

  my $passing = _build_report(
    _ledgered_run(
      run_id  => 'metrics-passing',
      status  => 'completed',
      metrics => {
        'publisher-001' => [map { _metric_event(duration_ms => 10 + $_) } 1 .. 5],
        'subscriber-001' =>
          [_metric_event(operation => 'subscription_fanout', role => 'subscriber', duration_ms => 100)],
        'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
        'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
      },
    ),
  );
  is $passing->{run}{verdict}, 'performance_passed', 'clean thresholds pass the run';
  is $passing->{human_summary}{headline}, 'Run completed and metrics were collected.',
    'the passing summary is calm';

  my $missing = _build_report(
    _ledgered_run(
      run_id  => 'metrics-missing',
      status  => 'completed',
      metrics => {
        'publisher-001'  => [_metric_event(duration_ms => 10)],
        'subscriber-001' => [_metric_event(operation => 'noop_probe', role => 'subscriber', duration_ms => 1)],
        'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
        'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
      },
    ),
  );
  my %missing_thresholds = map { $_->{id} => $_ } @{$missing->{thresholds}};
  is $missing_thresholds{subscription_fanout_p99_ms}{reason}, 'metric_missing', 'a missing metric is excused';
  is $missing->{run}{verdict}, 'inconclusive_partial_run', 'a missing metric makes the run inconclusive';
  like $missing->{human_summary}{important_notes}[0], qr/Thresholds\ without\ metrics/mx,
    'the missing metrics are named in the summary';
};

subtest 'raw metric paths resolve through the summary' => sub {
  my $scenario_path = File::Spec->catfile($tmp, 'raw-paths.yml');
  _write_text($scenario_path, <<'YAML');
run:
  name: raw-paths
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
thresholds:
  overall.error_rate: 0.5
  publish.latency_ms.p50: 60
  publish.latency_ms: 1
  absent_op.latency_ms.p99: 1
YAML

  my $report = _build_report(
    _ledgered_run(
      run_id        => 'raw-paths',
      status        => 'completed',
      scenario_path => $scenario_path,
      metrics       => {'publisher-001' => [_metric_event(duration_ms => 10), _metric_event(duration_ms => 20)]},
    ),
  );

  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{'overall.error_rate'}{status},        'passed', 'an overall metric path resolves';
  is $thresholds{'publish.latency_ms.p50'}{status},    'passed', 'an operation metric path resolves';
  is $thresholds{'publish.latency_ms'}{reason}, 'metric_missing',
    'a path that stops at a structure is a missing metric';
  is $thresholds{'absent_op.latency_ms.p99'}{reason}, 'metric_missing',
    'a path through an absent operation is a missing metric';
};

subtest 'metrics without thresholds and streams without workers' => sub {
  my $no_thresholds_path = File::Spec->catfile($tmp, 'no-thresholds.yml');
  _write_text($no_thresholds_path, <<'YAML');
run:
  name: no-thresholds
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
YAML

  my $unjudged = _build_report(
    _ledgered_run(
      run_id        => 'no-thresholds',
      status        => 'completed',
      scenario_path => $no_thresholds_path,
      metrics       => {'publisher-001' => [_metric_event(duration_ms => 10)]},
    ),
  );
  is $unjudged->{metrics}{collected}, JSON::true, 'metrics are collected without thresholds';
  is $unjudged->{thresholds}, [], 'no thresholds are configured';
  is $unjudged->{run}{verdict}, 'smoke_passed', 'collected metrics without thresholds stay a smoke pass';

  my $no_workers_path = File::Spec->catfile($tmp, 'no-workers.yml');
  _write_text($no_workers_path, <<'YAML');
run:
  name: no-workers
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: exit 0
      stop: exit 0
      health: exit 0
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

  my $no_streams = _build_report(
    _ledgered_run(run_id => 'no-workers', status => 'completed', scenario_path => $no_workers_path),
  );
  is $no_streams->{metrics}{streams}{expected}, 0, 'a workerless plan expects no streams';
  is $no_streams->{metrics}{collected}, JSON::false, 'no streams cannot be collected';

  my $partial = _build_report(
    _ledgered_run(
      run_id  => 'partial-streams',
      status  => 'completed',
      metrics => {'publisher-001' => [_metric_event(duration_ms => 10)]},
    ),
  );
  is $partial->{metrics}{streams}{seen}, 1, 'a partial run sees only the written streams';
  is scalar @{$partial->{metrics}{streams}{missing}}, 3, 'a partial run lists the missing streams';
  is $partial->{metrics}{collected}, JSON::false, 'partial streams do not count as collected';
};

subtest 'corrupt metric streams are a configuration error' => sub {
  my $run_dir = _ledgered_run(
    run_id  => 'corrupt-metrics',
    status  => 'completed',
    metrics => {
      'publisher-001' => [_metric_event(duration_ms => 10)],
      'subscriber-001' =>
        [_metric_event(operation => 'subscription_fanout', role => 'subscriber', duration_ms => 100)],
      'query-reader-001'  => [_metric_event(operation => 'query',       role => 'query_reader',  duration_ms => 50)],
      'object-reader-001' => [_metric_event(operation => 'object_read', role => 'object_reader', duration_ms => 60)],
    },
  );
  open my $fh, '>>', File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl') or die "append: $!";
  print {$fh} "not json\n" or die "print: $!";
  close $fh or die "close: $!";

  my $report = _build_report($run_dir);
  is $report->{metrics}{reason}, 'configuration_error',     'corrupt streams are a configuration error';
  is $report->{run}{verdict},    'inconclusive_no_metrics', 'corrupt streams make the run inconclusive';
  is $report->{diagnostics}{errors}[0]{code}, 'metrics_configuration_error', 'the corrupt stream is a diagnostic';
  like $report->{human_summary}{headline}, qr/inconclusive/mx, 'the summary calls the run inconclusive';
  is [map { $_->{reason} } @{$report->{thresholds}}],
    [('configuration_error') x 3],
    'thresholds are excused as configuration errors';
};

subtest 'abuse metrics make the run a resilience experiment' => sub {
  my $scenario_path = File::Spec->catfile($tmp, 'abuse.yml');
  _write_text($scenario_path, <<'YAML');
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
  publish_p99_ms: 100
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
  my $report = _build_report(
    _ledgered_run(
      run_id        => 'abuse',
      status        => 'completed',
      scenario_path => $scenario_path,
      metrics       => {
        'publisher-001' => [_metric_event(duration_ms => 20)],
        'flooder-001'   => [map {$defended} 1 .. 4],
      },
    ),
  );

  my %thresholds = map { $_->{id} => $_ } @{$report->{thresholds}};
  is $thresholds{'flood_publish.defended_ratio'}{comparator}, '>=', 'defense thresholds are floors';
  is $report->{run}{verdict},       'resilience_passed', 'a defended abuse run passes resilience';
  is $report->{run}{result_class},  'resilience',        'an abuse run is a resilience experiment';
  is $report->{run}{perturbations}, ['abuse'],           'abuse is the recorded perturbation';
};

subtest 'chaos hooks are matched to their runner events' => sub {
  my $scenario_path = File::Spec->catfile($tmp, 'chaos.yml');
  _write_text($scenario_path, <<'YAML');
run:
  name: chaos
  duration: 60
  seed: 12345
topology:
  relays:
    count: 2
    provider: generic-relay
  publishers:
    count: 1
workload:
  publish_rate_per_second: 10
chaos:
  - at: 5
    action: restart
    target: relay:1
  - at: 10
    action: restart
    target: relay:2
  - at: 15
    action: restart
    target: relay:1
  - at: 20
    action: restart
    target: relay:2
thresholds:
  publish_p99_ms: 100
YAML

  my $run_dir = _ledgered_run(
    run_id        => 'chaos',
    status        => 'completed',
    scenario_path => $scenario_path,
    metrics       => {'publisher-001' => [_metric_event(duration_ms => 20)]},
    customize     => sub {
      my ($ledger) = @_;
      my @events = (
        {hook_id => 'chaos-001', status => 'started',   timestamp => '2026-07-13T12:10:00Z'},
        {hook_id => 'chaos-001', status => 'completed', timestamp => '2026-07-13T12:10:01Z', duration_ms => 1000},
        {hook_id => 'chaos-002', status => 'started',   timestamp => '2026-07-13T12:10:05Z'},
        {hook_id => 'chaos-002', status => 'failed',    timestamp => '2026-07-13T12:10:06Z',
          error => 'restart tool crashed'},
        {hook_id => 'chaos-003', status => 'started', timestamp => '2026-07-13T12:10:10Z'},
        {hook_id => 'chaos-003', status => 'ticking', timestamp => '2026-07-13T12:10:11Z'},
        {status  => 'started',   timestamp => '2026-07-13T12:10:12Z'},
      );
      for my $event (@events) {
        $ledger->append_runner_event(
          {
            runner     => 'noop',
            phase      => 'observe',
            event_kind => 'chaos_hook',
            action     => 'restart',
            %{$event},
          },
        );
      }
    },
  );
  my $report = _build_report($run_dir);

  is $report->{chaos}{hooks_configured}, 4, 'all planned hooks are reported';
  is $report->{chaos}{hooks_executed},   1, 'only completed hooks count as executed';
  my %hooks = map { $_->{id} => $_ } @{$report->{chaos}{hooks}};
  is $hooks{'chaos-001'}{status},      'completed', 'a completed hook reports completion';
  is $hooks{'chaos-001'}{duration_ms}, 1000,        'a completed hook reports its duration';
  is $hooks{'chaos-002'}{status}, 'failed',               'a failed hook reports failure';
  is $hooks{'chaos-002'}{error},  'restart tool crashed', 'a failed hook carries its error';
  is $hooks{'chaos-003'}{status}, 'failed',               'a hook that never finished is failed';
  is $hooks{'chaos-003'}{error},  'hook never finished',  'the unfinished hook is explained';
  ok !defined $hooks{'chaos-003'}{duration_ms}, 'an unfinished hook has no duration';
  is $hooks{'chaos-004'}{status}, 'not_evaluated', 'a hook that never ran is not evaluated';
  ok !defined $hooks{'chaos-004'}{started_at}, 'an unrun hook never started';

  is $report->{run}{perturbations}, ['chaos'],           'chaos is the recorded perturbation';
  is $report->{run}{result_class},  'resilience',        'a chaos run is a resilience experiment';
  is $report->{run}{verdict},       'resilience_passed', 'the chaos run passes its thresholds';
};

subtest 'cross-host clock evidence is judged against the fanout bound' => sub {
  my $write_clocks = sub {
    my ($ledger, $guests) = @_;
    _write_text(
      File::Spec->catfile($ledger->{run_dir}, 'clocks.json'),
      $json->encode({measured_at => '2026-07-13T12:00:00Z', guests => $guests}),
    );
  };

  my $skewed = _build_report(
    _ledgered_run(
      run_id    => 'clock-skew',
      status    => 'completed',
      customize => sub {
        $write_clocks->(
          $_[0],
          [
            {name => 'worker-guest-001', transport => 'ssh',  offset_ms => 5000, round_trip_ms => 3},
            {name => 'worker-guest-002', transport => 'ssh',  offset_ms => 1,    round_trip_ms => 3},
            {name => 'local',            transport => 'exec', offset_ms => 0,    round_trip_ms => 0},
          ],
        );
      },
    ),
  );
  my %skew_warnings = map { $_->{code} => $_ } @{$skewed->{diagnostics}{warnings}};
  ok $skew_warnings{cross_host_clock_skew}, 'a clock beyond the fanout bound is skew';
  like $skew_warnings{cross_host_clock_skew}{message}, qr/worker-guest-001\ 5000ms/mx,
    'the skewed guest is named';
  unlike $skew_warnings{cross_host_clock_skew}{message}, qr/worker-guest-002/mx,
    'a guest within the bound is not named';

  my $unverified = _build_report(
    _ledgered_run(
      run_id    => 'clock-unverified',
      status    => 'completed',
      customize => sub {
        $write_clocks->($_[0], [{name => 'worker-guest-001', transport => 'ssh', offset_ms => undef}]);
      },
    ),
  );
  my %unverified_warnings = map { $_->{code} => $_ } @{$unverified->{diagnostics}{warnings}};
  ok $unverified_warnings{cross_host_clock_unverified}, 'an unmeasured remote clock is unverified';

  my $local_only = _build_report(
    _ledgered_run(
      run_id    => 'clock-local',
      status    => 'completed',
      customize => sub {
        $write_clocks->($_[0], [{name => 'local', transport => 'exec', offset_ms => 0}]);
      },
    ),
  );
  ok !(grep { $_->{code} =~ /\Across_host_clock/mxs } @{$local_only->{diagnostics}{warnings}}),
    'a local-only run raises no clock warnings';

  my $malformed = _build_report(
    _ledgered_run(
      run_id    => 'clock-malformed',
      status    => 'completed',
      customize => sub {
        _write_text(File::Spec->catfile($_[0]->{run_dir}, 'clocks.json'), $json->encode(['not', 'a', 'hash']));
      },
    ),
  );
  ok !(grep { $_->{code} =~ /\Across_host_clock/mxs } @{$malformed->{diagnostics}{warnings}}),
    'malformed clock evidence raises no clock warnings';

  my $no_fanout_path = File::Spec->catfile($tmp, 'no-fanout.yml');
  _write_text($no_fanout_path, <<'YAML');
run:
  name: no-fanout
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
thresholds:
  publish_p99_ms: 100
YAML
  my $no_fanout = _build_report(
    _ledgered_run(
      run_id        => 'clock-no-fanout',
      status        => 'completed',
      scenario_path => $no_fanout_path,
      customize     => sub {
        $write_clocks->($_[0], [{name => 'worker-guest-001', transport => 'ssh', offset_ms => 5000}]);
      },
    ),
  );
  ok !(grep { $_->{code} =~ /\Across_host_clock/mxs } @{$no_fanout->{diagnostics}{warnings}}),
    'clock warnings only apply when fanout is judged';
};

subtest 'threshold comparators hold and reject as specified' => sub {
  ok Overnet::Burner::Report::_threshold_holds('<=', 1, 1),  'observed at the ceiling passes';
  ok !Overnet::Burner::Report::_threshold_holds('<=', 2, 1), 'observed above the ceiling fails';
  ok Overnet::Burner::Report::_threshold_holds('<', 1, 2),   'strictly-below passes below';
  ok !Overnet::Burner::Report::_threshold_holds('<', 2, 2),  'strictly-below fails at the bound';
  ok Overnet::Burner::Report::_threshold_holds('>=', 1, 1),  'observed at the floor passes';
  ok !Overnet::Burner::Report::_threshold_holds('>=', 0, 1), 'observed below the floor fails';
  ok Overnet::Burner::Report::_threshold_holds('>', 2, 1),   'strictly-above passes above';
  ok !Overnet::Burner::Report::_threshold_holds('>', 1, 1),  'strictly-above fails at the bound';
  ok Overnet::Burner::Report::_threshold_holds('==', 1, 1),  'equality passes when equal';
  ok !Overnet::Burner::Report::_threshold_holds('==', 1, 2), 'equality fails when different';
  ok Overnet::Burner::Report::_threshold_holds('!=', 1, 2),  'inequality passes when different';
  ok !Overnet::Burner::Report::_threshold_holds('!=', 1, 1), 'inequality fails when equal';

  my $held = eval { Overnet::Burner::Report::_threshold_holds('~', 1, 1); 1 };
  ok !$held, 'an unknown comparator is rejected';
  like $@, qr/unsupported\ threshold\ comparator/mx, 'the unknown comparator is reported';

  ok !defined Overnet::Burner::Report::_parse_timestamp(undef), 'an undefined timestamp does not parse';
};

subtest 'a report generated without an injected clock stamps real time' => sub {
  my $run_dir = _ledgered_run(run_id => 'real-clock', status => 'created');
  my $report  = Overnet::Burner::Report->build(run_dir => $run_dir);
  like $report->{generated_at}, qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/mx,
    'generated_at is an ISO-8601 UTC timestamp';
};

subtest 'multi-phase runs are judged on their main phase' => sub {
  my $scenario_path = File::Spec->catfile($tmp, 'phased.yml');
  _write_text($scenario_path, <<'YAML');
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

  my $report = _build_report(
    _ledgered_run(
      run_id        => 'phased',
      status        => 'completed',
      scenario_path => $scenario_path,
      metrics       => {
        'publisher-001' => [
          _metric_event(phase => 'warmup', status => 'error', error => 'cold start', duration_ms => 400),
          _metric_event(phase => 'main', duration_ms => 10),
        ],
      },
    ),
  );

  is $report->{metrics}{operations}{publish}{count}, 1,  'only main phase events are summarized';
  is $report->{workload}{duration_seconds},          70, 'the workload duration covers all phases';
  is scalar @{$report->{workload}{phases}},          2,  'each workload phase is summarized';
  is $report->{run}{verdict}, 'performance_passed', 'the run is judged on its steady state';
};

done_testing;

sub _ledgered_run {
  my (%args) = @_;

  my $scenario_path = $args{scenario_path} || $baseline_path;
  my $scenario      = Overnet::Burner::Config->load_file($scenario_path);
  my $tick          = 0;
  my $now           = sub { sprintf '2026-07-13T12:%02d:%02dZ', int($tick / 60) % 60, $tick++ % 60 };
  my $ledger        = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => $args{run_id},
    now           => $now,
    host_facts    => {hostname => 'builder-host', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  my $status = $args{status} || 'completed';

  if ($status ne 'created') {
    $ledger->mark_started(runner => 'noop');
  }
  if ($status ne 'created' && $status ne 'running') {
    my $plan   = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});
    my $runner = Overnet::Burner::Runner->load(
      name    => 'noop',
      ledger  => $ledger,
      plan    => $plan,
      run_dir => $ledger->{run_dir},
    );
    my $summary = $runner->run_lifecycle;
    $ledger->finish(
      status => $status,
      runner => 'noop',
      $status eq 'completed' ? (lifecycle => $summary)  : (),
      exists $args{error}    ? (error => $args{error})  : (),
    );
  }

  if ($args{metrics}) {
    my $metrics_dir = File::Spec->catdir($ledger->{run_dir}, 'metrics');
    make_path($metrics_dir);
    my $aggregated = q{};
    for my $actor (sort keys %{$args{metrics}}) {
      my $content = join q{}, map { $json->encode($_) . "\n" } @{$args{metrics}{$actor}};
      _write_text(File::Spec->catfile($metrics_dir, "$actor.jsonl"), $content);
      $aggregated .= $content;
    }
    _write_text(File::Spec->catfile($ledger->{run_dir}, 'metrics.jsonl'), $aggregated);
  }

  if ($args{customize}) {
    $args{customize}->($ledger);
  }

  return $ledger->{run_dir};
}

sub _build_report {
  my ($run_dir) = @_;

  return Overnet::Burner::Report->build(run_dir => $run_dir, now => sub {'2026-07-13T13:00:00Z'});
}

sub _metric_event {
  my (%overrides) = @_;

  return {
    metric_version => 1,
    run_id         => 'run-metrics',
    worker_id      => 'publisher-001',
    host           => 'host-test',
    role           => 'publisher',
    operation      => 'publish',
    started_at     => '2026-07-13T12:00:00Z',
    finished_at    => '2026-07-13T12:00:00.010Z',
    duration_ms    => 10,
    status         => 'success',
    %overrides,
  };
}

sub _write_text {
  my ($path, $content) = @_;

  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}

sub _read_json {
  my ($path) = @_;

  my $content = do {
    open my $fh, '<', $path or die "open $path: $!";
    local $/ = undef;
    <$fh>;
  };
  return JSON::decode_json($content);
}
