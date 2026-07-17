package Overnet::Burner::Report;

use strictures 2;

use Carp qw(croak);
use Digest::SHA;
use English qw(-no_match_vars);
use File::Spec;
use JSON        ();
use POSIX       qw(strftime);
use Time::Local qw(timegm);

use Overnet::Burner::Metrics;
use Overnet::Burner::Util qw(checked_close json_text read_json_file read_jsonl_file write_file);

our $VERSION = '0.001';

my $SCHEMA_ID = 'https://overnet-project.org/schemas/overnet-burner/report-v1.schema.json';

my %THRESHOLD = (
  error_rate_max => {
    metric     => 'overall.error_rate',
    comparator => '<=',
    unit       => 'ratio',
  },
  object_read_p99_ms => {
    metric     => 'object_read.latency_ms.p99',
    comparator => '<=',
    unit       => 'ms',
  },
  publish_p99_ms => {
    metric     => 'publish.latency_ms.p99',
    comparator => '<=',
    unit       => 'ms',
  },
  query_p99_ms => {
    metric     => 'query.latency_ms.p99',
    comparator => '<=',
    unit       => 'ms',
  },
  subscription_fanout_p99_ms => {
    metric     => 'subscription_fanout.latency_ms.p99',
    comparator => '<=',
    unit       => 'ms',
  },
);

sub build {
  my ($class, %args) = @_;

  my $run_dir = $args{run_dir} || croak "run_dir is required\n";
  if (!-d $run_dir) {
    croak "run directory does not exist: $run_dir\n";
  }

  my $now       = $args{now} || \&_iso_now;
  my $manifest  = _read_json_file(_path($run_dir, 'manifest.json'));
  my $plan      = _read_json_file(_path($run_dir, 'plan.json'));
  my $config    = _read_json_file(_path($run_dir, 'config.normalized.json'));
  my $events    = _read_jsonl_file(_path($run_dir, 'logs', 'runner.jsonl'));
  my $inventory = _read_optional_json_file(_path($run_dir, 'artifacts', 'rex', 'inventory', 'hosts.json'),);
  my $clocks    = _read_optional_json_file(_path($run_dir, 'clocks.json'));

  my ($metrics, $summary, $metrics_error) = _metrics($run_dir, $plan, $manifest);
  my $thresholds = _thresholds($config, $metrics, $manifest, $summary);
  my $chaos      = _chaos($plan, $events);
  my $report     = {
    report_version => 1,
    schema         => $SCHEMA_ID,
    generated_at   => $now->(),
    run            => _run($manifest, $metrics, $thresholds, $chaos),
    scenario       => _scenario($manifest, $plan),
    environment    => _environment($manifest),
    topology       => _topology($manifest, $plan, $inventory),
    execution      => _execution($manifest, $events),
    workload       => _workload($plan),
    metrics        => $metrics,
    thresholds     => $thresholds,
    chaos          => $chaos,
    artifacts      => _artifacts($run_dir),
    diagnostics    => _diagnostics($manifest, $metrics, $metrics_error, $thresholds, $clocks),
    human_summary  => _human_summary($manifest, $metrics, $thresholds),
    extensions     => {},
  };

  return $report;
}

sub write_report {
  my ($class, %args) = @_;

  my $run_dir = $args{run_dir} || croak "run_dir is required\n";
  my $report  = $class->build(%args);
  my $path    = _path($run_dir, 'report.json');

  write_file($path, $class->canonical_json($report));

  return $path;
}

sub canonical_json {
  my ($class, $report) = @_;

  return json_text($report);
}

sub _run {
  my ($manifest, $metrics, $thresholds, $chaos) = @_;

  my $status = $manifest->{status} || 'created';
  my ($verdict, $result_class) = _verdict_and_result_class($manifest, $metrics, $thresholds, $chaos);

  return {
    id            => $manifest->{run_id},
    status        => $status,
    verdict       => $verdict,
    result_class  => $result_class,
    perturbations => [_perturbations($metrics, $chaos)],
    created_at    => $manifest->{timestamps}{created_at}  || undef,
    started_at    => $manifest->{timestamps}{started_at}  || undef,
    finished_at   => $manifest->{timestamps}{finished_at} || undef,
    duration_ms   => _duration_ms($manifest->{timestamps}{started_at}, $manifest->{timestamps}{finished_at},),
  };
}

# The perturbation mechanisms a run actually exercised. A run that injures
# infrastructure (chaos) and a run that introduces adversarial participants
# (abuse) are two mechanisms of one resilience experiment, so the report
# records which ran rather than collapsing them to a single winning class.
sub _perturbations {
  my ($metrics, $chaos) = @_;
  my @mechanisms;
  if (_has_abuse_operations($metrics)) {
    push @mechanisms, 'abuse';
  }
  if (_chaos_run($chaos)) {
    push @mechanisms, 'chaos';
  }
  return @mechanisms;
}

sub _chaos_run {
  my ($chaos) = @_;
  return (($chaos->{hooks_executed} || 0) > 0) ? 1 : 0;
}

sub _verdict_and_result_class {
  my ($manifest, $metrics, $thresholds, $chaos) = @_;

  my $status = $manifest->{status} || 'created';
  if ($status eq 'created' || $status eq 'running') {
    return ('not_evaluated', 'none');
  }
  if ($status eq 'aborted') {
    return ('aborted', 'orchestration');
  }
  if ($status eq 'failed') {
    return ('orchestration_failed', 'orchestration');
  }
  if ($status ne 'completed') {
    return ('not_evaluated', 'none');
  }

  my $perturbation = _chaos_run($chaos) || _has_abuse_operations($metrics);

  if (!$metrics->{collected}) {
    if (($metrics->{reason} || q{}) eq 'configuration_error') {
      return ('inconclusive_no_metrics', 'performance');
    }
    return ('smoke_passed', 'orchestration');
  }

  my @failed    = grep { $_->{status} eq 'failed' } @{$thresholds};
  my @missing   = grep { ($_->{reason} || q{}) eq 'metric_missing' } @{$thresholds};
  my @evaluated = grep { $_->{status} eq 'passed' || $_->{status} eq 'failed' } @{$thresholds};

  # Chaos and abuse are two mechanisms of one resilience experiment. A run
  # that ran either is judged as a single resilience experiment, so the
  # verdict never depends on which mechanism a run happened to use and a
  # mixed run cannot be misattributed to one of them.
  my $class   = $perturbation ? 'resilience' : 'performance';
  my %verdict = (
    resilience  => {failed => 'resilience_failed',  passed => 'resilience_passed'},
    performance => {failed => 'performance_failed', passed => 'performance_passed'},
  );

  if (@failed) {
    return ($verdict{$class}{failed}, $class);
  }
  if (@missing) {
    return ('inconclusive_partial_run', $class);
  }
  if (@evaluated) {
    return ($verdict{$class}{passed}, $class);
  }

  return ('smoke_passed', 'orchestration');
}

sub _has_abuse_operations {
  my ($metrics) = @_;

  my $operations = $metrics->{operations} || {};
  for my $operation (values %{$operations}) {
    if (ref $operation eq 'HASH' && exists $operation->{defended_ratio}) {
      return 1;
    }
  }

  return 0;
}

sub _scenario {
  my ($manifest, $plan) = @_;

  return {
    name                   => $manifest->{scenario}{name} || $plan->{scenario}{name},
    seed                   => 0 + ($manifest->{seed} || $plan->{run}{seed} || 0),
    source_path            => 'scenario.yml',
    normalized_config_path => 'config.normalized.json',
    plan_path              => 'plan.json',
  };
}

sub _environment {
  my ($manifest) = @_;
  my $host = $manifest->{host_facts} || {};

  return {
    host => {
      hostname => $host->{hostname},
      os       => $host->{os},
      release  => $host->{release},
      arch     => $host->{arch},
    },
    perl_version => $manifest->{perl_version},
    rex_version  => $manifest->{rex_version},
    repo_sha     => $manifest->{repo_sha},
  };
}

sub _topology {
  my ($manifest, $plan, $inventory) = @_;

  my $topology_provider = $plan->{topology_provider} || $manifest->{topology_provider} || {};
  my %descriptor        = %{$topology_provider};
  delete $descriptor{name};

  return {
    provider => {
      name       => $topology_provider->{name},
      descriptor => \%descriptor,
    },
    hosts  => _hosts($inventory),
    actors => _actor_counts($plan),
  };
}

sub _hosts {
  my ($inventory) = @_;

  if (ref $inventory ne 'HASH') {
    return {
      total  => 0,
      groups => {},
    };
  }

  return {
    total  => scalar @{$inventory->{hosts} || []},
    groups => {
      map { $_ => scalar @{$inventory->{groups}{$_} || []} }
      sort keys %{$inventory->{groups} || {}},
    },
  };
}

sub _actor_counts {
  my ($plan) = @_;
  my @roles  = qw(relays publishers subscribers query_readers object_readers observers);
  my %counts = map { $_ => scalar @{$plan->{$_} || []} } @roles;
  $counts{total} = 0;
  for my $role (@roles) {
    $counts{total} += $counts{$role};
  }

  return \%counts;
}

sub _execution {
  my ($manifest, $events) = @_;

  return {
    runner           => $manifest->{runner}{name} || 'none',
    remote_execution => _remote_execution($manifest),
    phases           => _phases($events),
  };
}

sub _remote_execution {
  my ($manifest) = @_;

  return $manifest->{rex_bundle}{remote_execution}
    if ref $manifest->{rex_bundle} eq 'HASH'
    && defined $manifest->{rex_bundle}{remote_execution};

  return 'not_performed';
}

sub _phases {
  my ($events) = @_;
  my %phase;
  my @order;

  for my $event (@{$events}) {
    my $spec = _phase_spec($event);
    my $key  = join "\0", $spec->{kind}, $spec->{id};

    if (!exists $phase{$key}) {
      push @order, $key;
      $phase{$key} = {
        id          => $spec->{id},
        name        => $spec->{name},
        kind        => $spec->{kind},
        status      => 'planned',
        started_at  => undef,
        finished_at => undef,
        duration_ms => undef,
        actor_id    => $event->{actor_id},
        host_id     => undef,
        command     => $event->{command},
        exit_code   => undef,
        error       => undef,
        artifacts   => [],
        extensions  => {},
      };
    }

    my $phase_record = $phase{$key};

    # Ledger events use a "started" status, but the report schema's phase
    # vocabulary is planned/skipped/running/completed/failed/not_evaluated. Map
    # the in-flight event onto "running" so a phase that never finished (an
    # interrupted run) stays schema-valid instead of carrying "started".
    my $event_status = $event->{status};
    $phase_record->{status} = (defined $event_status && $event_status eq 'started') ? 'running' : $event_status;
    if (exists $event->{actor_id}) {
      $phase_record->{actor_id} = $event->{actor_id};
    }
    if (exists $event->{command}) {
      $phase_record->{command} = $event->{command};
    }
    if (exists $event->{exit_code}) {
      $phase_record->{exit_code} = $event->{exit_code};
    }
    if (exists $event->{error}) {
      $phase_record->{error} = $event->{error};
    }
    if (($event->{status} || q{}) eq 'started') {
      $phase_record->{started_at} = $event->{timestamp};
    }
    if (($event->{status} || q{}) ne 'started') {
      $phase_record->{finished_at} = $event->{timestamp};
    }
    if (exists $event->{stdout_path} || exists $event->{stderr_path}) {
      $phase_record->{artifacts} = _event_artifact_refs($event);
    }
    $phase_record->{duration_ms} = _duration_ms($phase_record->{started_at}, $phase_record->{finished_at},);
  }

  return [map { $phase{$_} } @order];
}

sub _phase_spec {
  my ($event) = @_;

  if (exists $event->{rex_task}) {
    return {
      id   => "rex-$event->{rex_task}",
      name => $event->{rex_task},
      kind => 'rex_task',
    };
  }

  if (exists $event->{command_kind}) {
    return {
      id   => join(q{-}, 'provider', $event->{actor_id}, $event->{command_kind}),
      name => $event->{command_kind},
      kind => 'provider_command',
    };
  }

  return {
    id   => "runner-$event->{phase}",
    name => $event->{phase},
    kind => 'runner_phase',
  };
}

sub _event_artifact_refs {
  my ($event) = @_;
  my @refs;

  if (exists $event->{stdout_path}) {
    push @refs,
      {
      id   => "$event->{actor_id}-$event->{command_kind}-stdout",
      path => $event->{stdout_path},
      };
  }
  if (exists $event->{stderr_path}) {
    push @refs,
      {
      id   => "$event->{actor_id}-$event->{command_kind}-stderr",
      path => $event->{stderr_path},
      };
  }

  return \@refs;
}

sub _workload {
  my ($plan) = @_;

  my @phases = map {
    {
      id                        => $_->{id},
      name                      => $_->{name},
      start_seconds             => 0 + $_->{start_seconds},
      duration_seconds          => 0 + $_->{duration_seconds},
      publish_rate_per_second   => 0 + $_->{publish_rate_per_second},
      object_reads_per_second   => 0 + ($_->{object_reads}{rate_per_second} || 0),
      subscription_filter_count => scalar @{$_->{subscription_filters} || []},
      query_filter_count        => scalar @{$_->{query_filters}        || []},
      actor_seeds               => $_->{actor_seeds} || {},
    }
  } @{$plan->{workload}{phases} || []};

  return {
    duration_seconds => 0 + ($plan->{run}{total_duration_seconds} // $plan->{run}{duration_seconds} // 0),
    phases           => \@phases,
  };
}

sub _metrics {
  my ($run_dir, $plan, $manifest) = @_;

  my @streams = @{$plan->{metric_streams} || []};
  my @missing;
  my $seen = 0;

  for my $stream (@streams) {
    my $path = _path($run_dir, $stream->{path});
    if (-e $path && -s $path) {
      $seen++;
    } else {
      push @missing, $stream->{path};
    }
  }

  my $collected = @streams && $seen == @streams ? 1 : 0;

  my $multi_phase = scalar(@{$plan->{workload}{phases} || []}) > 1;
  my $summary;
  my $metrics_error;
  if ($collected) {
    eval {
      $summary =
        Overnet::Burner::Metrics->summarize_stream_files($run_dir, \@streams, $multi_phase ? (phase => 'main') : (),);
      1;
    } or do {
      $metrics_error = $EVAL_ERROR || 'metric stream summarization failed';
      chomp $metrics_error;
      $summary   = undef;
      $collected = 0;
    };
  }

  my $reason =
      $collected     ? 'none'
    : $metrics_error ? 'configuration_error'
    : (($manifest->{status} || q{}) eq 'failed' ? 'run_failed' : 'smoke_only');

  my $section = {
    collected => $collected ? JSON::true : JSON::false,
    reason    => $reason,
    streams   => {
      expected => scalar @streams,
      seen     => $seen,
      missing  => \@missing,
    },
    operations => $summary ? $summary->{operations} : {},
  };

  return ($section, $summary, $metrics_error);
}

sub _thresholds {
  my ($config, $metrics, $manifest, $summary) = @_;
  my $thresholds = $config->{thresholds} || {};
  my @records;

  for my $id (sort keys %{$thresholds}) {
    my $defense = $id =~ /[.](?:defended_ratio|defended_correct_ratio)\z/mxs;
    my $spec    = $THRESHOLD{$id}
      || {
      metric     => $id,
      comparator => ($defense ? '>='    : '<='),
      unit       => ($defense ? 'ratio' : undef),
      };

    my $threshold_record = {
      id               => $id,
      metric           => $spec->{metric},
      comparator       => $spec->{comparator},
      configured_value => $thresholds->{$id},
      observed_value   => undef,
      unit             => $spec->{unit},
    };

    if (!$metrics->{collected}) {
      $threshold_record->{status} = 'not_evaluated';
      $threshold_record->{reason} =
          ($metrics->{reason}  || q{}) eq 'configuration_error' ? 'configuration_error'
        : ($manifest->{status} || q{}) eq 'failed'              ? 'run_failed'
        :                                                         'no_metrics';
    } else {
      my $observed = _resolve_metric_path($summary, $spec->{metric});
      if (defined $observed) {
        $threshold_record->{observed_value} = 0 + $observed;
        $threshold_record->{status} =
          _threshold_holds($spec->{comparator}, $observed, $thresholds->{$id}) ? 'passed' : 'failed';
        $threshold_record->{reason} = 'none';
      } else {
        $threshold_record->{status} = 'not_evaluated';
        $threshold_record->{reason} = 'metric_missing';
      }
    }

    push @records, $threshold_record;
  }

  return \@records;
}

sub _resolve_metric_path {
  my ($summary, $metric) = @_;

  return if !$summary || !defined $metric;

  my @segments = split /[.]/mxs, $metric;
  return if !@segments;

  my $node;
  if ($segments[0] eq 'overall') {
    shift @segments;
    $node = $summary->{overall};
  } else {
    my $operation = shift @segments;
    $node = $summary->{operations}{$operation};
  }

  for my $segment (@segments) {
    return if ref($node) ne 'HASH' || !exists $node->{$segment};
    $node = $node->{$segment};
  }

  return (defined $node && !ref $node) ? $node : undef;
}

sub _threshold_holds {
  my ($comparator, $observed, $configured) = @_;

  return $observed <= $configured if $comparator eq q{<=};
  return $observed < $configured  if $comparator eq q{<};
  return $observed >= $configured if $comparator eq q{>=};
  return $observed > $configured  if $comparator eq q{>};
  return $observed == $configured if $comparator eq q{==};
  return $observed != $configured if $comparator eq q{!=};
  croak "unsupported threshold comparator: $comparator\n";
}

sub _chaos {
  my ($plan, $events) = @_;

  my ($started, $finished) = _chaos_hook_events($events);

  my @hooks;
  my $executed = 0;
  for my $hook (@{$plan->{chaos_hooks} || []}) {
    my $row = _chaos_hook_row($hook, $started->{$hook->{id}}, $finished->{$hook->{id}});
    if ($row->{status} eq 'completed') {
      $executed++;
    }
    push @hooks, $row;
  }

  return {
    hooks_configured => scalar @hooks,
    hooks_executed   => $executed,
    hooks            => \@hooks,
  };
}

sub _chaos_hook_events {
  my ($events) = @_;

  my (%started, %finished);
  for my $event (@{$events || []}) {
    if (($event->{event_kind} || q{}) ne 'chaos_hook' || !$event->{hook_id}) {
      next;
    }
    if ($event->{status} eq 'started') {
      $started{$event->{hook_id}} = $event;
    } elsif ($event->{status} eq 'completed' || $event->{status} eq 'failed') {
      $finished{$event->{hook_id}} = $event;
    }
  }

  return (\%started, \%finished);
}

sub _chaos_hook_row {
  my ($hook, $started, $finished) = @_;

  my $status =
      $finished ? $finished->{status}
    : $started  ? 'failed'
    :             'not_evaluated';
  my $error =
      $finished && defined $finished->{error} ? $finished->{error}
    : $started  && !$finished                 ? 'hook never finished'
    :                                           undef;

  return {
    id                   => $hook->{id},
    action               => $hook->{action},
    target               => $hook->{target},
    status               => $status,
    scheduled_at_seconds => 0 + ($hook->{at_seconds} || 0),
    started_at           => $started                                      ? $started->{timestamp}        : undef,
    finished_at          => $finished                                     ? $finished->{timestamp}       : undef,
    duration_ms          => $finished && defined $finished->{duration_ms} ? 0 + $finished->{duration_ms} : undef,
    error                => $error,
  };
}

sub _artifacts {
  my ($run_dir) = @_;
  my @candidates = (
    [manifest              => 'manifest.json',                        'application/json',     'evidence',   1],
    [scenario              => 'scenario.yml',                         'application/yaml',     'input',      1],
    [profile_template      => 'profile-template.yml',                 'application/yaml',     'input',      0],
    [generated_profile     => 'profile.generated.yml',                'application/yaml',     'input',      0],
    [normalized_config     => 'config.normalized.json',               'application/json',     'evidence',   1],
    [plan                  => 'plan.json',                            'application/json',     'evidence',   1],
    [runner_log            => 'logs/runner.jsonl',                    'application/x-ndjson', 'log',        1],
    [metrics               => 'metrics.jsonl',                        'application/x-ndjson', 'metrics',    1],
    [clocks                => 'clocks.json',                          'application/json',     'evidence',   0],
    [rex_bundle            => 'artifacts/rex/bundle.json',            'application/json',     'rex_bundle', 0],
    [rexfile               => 'artifacts/rex/Rexfile',                'text/x-perl',          'rex_bundle', 0],
    [rex_lifecycle         => 'artifacts/rex/lifecycle.json',         'application/json',     'rex_bundle', 0],
    [rex_inventory         => 'artifacts/rex/inventory/hosts.json',   'application/json',     'rex_bundle', 0],
    [rex_topology_provider => 'artifacts/rex/topology-provider.json', 'application/json',     'rex_bundle', 0],
  );
  my @artifacts;

  for my $candidate (@candidates) {
    my ($id, $relative_path, $media_type, $role, $required) = @{$candidate};
    my $path = _path($run_dir, split m{/}mxs, $relative_path);
    if (!-e $path) {
      next;
    }
    push @artifacts,
      _artifact(
      id            => $id,
      path          => $relative_path,
      media_type    => $media_type,
      role          => $role,
      required      => $required,
      absolute_path => $path,
      );
  }

  return \@artifacts;
}

sub _artifact {
  my (%args) = @_;

  return {
    id         => $args{id},
    path       => $args{path},
    media_type => $args{media_type},
    role       => $args{role},
    required   => $args{required} ? JSON::true : JSON::false,
    sha256     => _sha256_file($args{absolute_path}),
    size_bytes => 0 + (-s $args{absolute_path}),
  };
}

sub _diagnostics {
  my ($manifest, $metrics, $metrics_error, $thresholds, $clocks) = @_;
  my @errors;
  my @warnings;

  if (($manifest->{status} || q{}) eq 'failed') {
    push @errors,
      {
      severity => 'error',
      code     => 'run_failed',
      message  => $manifest->{error} || 'run failed',
      source   => 'manifest.error',
      };
  }

  if ($metrics_error) {
    push @errors,
      {
      severity => 'error',
      code     => 'metrics_configuration_error',
      message  => $metrics_error,
      source   => 'metrics',
      };
  }

  if ( ($manifest->{status} || q{}) eq 'completed'
    && !$metrics->{collected}
    && ($metrics->{reason} || q{}) eq 'smoke_only') {
    push @warnings,
      {
      severity => 'warning',
      code     => 'no_real_workload',
      message  => 'Run completed without collecting real Overnet workload metrics.',
      source   => 'metrics',
      };
  }

  push @warnings, _clock_diagnostics($thresholds, $clocks);

  return {
    errors   => \@errors,
    warnings => \@warnings,
  };
}

# subscription_fanout is a subscriber's receive time minus the publisher's
# sent_at stamp, so when the two sit on different hosts the measurement
# crosses two clocks. When that metric is being judged and the run used
# remote guests, the report surfaces whether the per-host clock offsets were
# captured and whether any exceeds the fanout budget it is judged against.
sub _clock_diagnostics {
  my ($thresholds, $clocks) = @_;

  my ($fanout) = grep { ($_->{id} || q{}) eq 'subscription_fanout_p99_ms' } @{$thresholds || []};
  if (!$fanout) {
    return ();
  }

  my @remote =
    grep { ($_->{transport} || 'exec') ne 'exec' } @{(ref $clocks eq 'HASH' ? $clocks->{guests} : undef) || []};
  if (!@remote) {
    return ();
  }

  my @warnings;
  my @unverified = grep { !defined $_->{offset_ms} } @remote;
  if (@unverified) {
    push @warnings,
      {
      severity => 'warning',
      code     => 'cross_host_clock_unverified',
      message  => 'subscription_fanout is judged across hosts but the clock offset of '
        . join(q{, }, map { $_->{name} } @unverified)
        . ' was not captured; cross-host fanout timing may be unreliable.',
      source => 'clocks',
      };
  }

  my $bound = $fanout->{configured_value};
  my @skewed =
    defined $bound ? grep { defined $_->{offset_ms} && abs($_->{offset_ms}) > $bound } @remote : ();
  if (@skewed) {
    push @warnings,
      {
      severity => 'warning',
      code     => 'cross_host_clock_skew',
      message  => 'host clock offsets exceed the subscription_fanout_p99_ms bound ('
        . $bound . 'ms): '
        . join(q{, }, map {"$_->{name} $_->{offset_ms}ms"} @skewed)
        . '; cross-host fanout measurements may be corrupted.',
      source => 'clocks',
      };
  }

  return @warnings;
}

sub _human_summary {
  my ($manifest, $metrics, $thresholds) = @_;

  if (($manifest->{status} || q{}) eq 'failed') {
    return {
      headline        => 'Run failed during orchestration.',
      important_notes => [$manifest->{error} || 'run failed'],
    };
  }

  if (!$metrics->{collected}) {
    if (($metrics->{reason} || q{}) eq 'configuration_error') {
      return {
        headline        => 'Metric streams were present but invalid; the run is inconclusive.',
        important_notes => ['Fix the metric streams before trusting anything in this run directory.',],
      };
    }
    return {
      headline        => 'Orchestration smoke completed; no real Overnet workload metrics were collected.',
      important_notes => [
        'This report proves orchestration wiring, not system performance.',
        'Thresholds were not evaluated because metrics were not collected.',
      ],
    };
  }

  my @failed  = grep { $_->{status} eq 'failed' } @{$thresholds};
  my @missing = grep { ($_->{reason} || q{}) eq 'metric_missing' } @{$thresholds};
  my @notes;
  if (@failed) {
    push @notes, 'Failed thresholds: ' . join(q{, }, map { $_->{id} } @failed) . q{.};
  }
  if (@missing) {
    push @notes, 'Thresholds without metrics: ' . join(q{, }, map { $_->{id} } @missing) . q{.};
  }

  return {
    headline => @failed
    ? 'Run completed and at least one performance threshold failed.'
    : 'Run completed and metrics were collected.',
    important_notes => \@notes,
  };
}

sub _duration_ms {
  my ($started_at, $finished_at) = @_;
  my $missing;

  if (!(defined $started_at && defined $finished_at)) {
    return $missing;
  }
  my $started  = _parse_timestamp($started_at);
  my $finished = _parse_timestamp($finished_at);
  if (!(defined $started && defined $finished)) {
    return $missing;
  }

  # A clock that steps backward mid-phase (an NTP correction) would make the
  # elapsed time negative, which the schema's non-negative duration_ms forbids.
  # Report no duration rather than an impossible one.
  if ($finished < $started) {
    return $missing;
  }

  return int(($finished - $started) * 1000);
}

sub _parse_timestamp {
  my ($timestamp) = @_;
  my $missing;

  if (!defined $timestamp) {
    return $missing;
  }

  my ($year, $month, $day, $hour, $minute, $seconds) =
    $timestamp =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/mxs;
  if (!defined $year) {
    return $missing;
  }

  return eval { timegm($seconds, $minute, $hour, $day, $month - 1, $year) };
}

sub _read_json_file {
  my ($path) = @_;

  return read_json_file($path);
}

sub _read_optional_json_file {
  my ($path) = @_;
  my $missing;

  if (!-e $path) {
    return $missing;
  }
  return _read_json_file($path);
}

sub _read_jsonl_file {
  my ($path) = @_;

  return read_jsonl_file($path);
}

sub _sha256_file {
  my ($path) = @_;

  open my $fh, '<', $path
    or croak "open $path: $OS_ERROR\n";
  binmode $fh;
  my $digest = Digest::SHA->new(256);
  $digest->addfile($fh);
  checked_close($fh, $path);
  return $digest->hexdigest;
}

sub _path {
  my (@path) = @_;
  return File::Spec->catfile(@path);
}

sub _iso_now {
  return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
}

1;

=head1 NAME

Overnet::Burner::Report - structured report generation

=head1 DESCRIPTION

Builds and writes versioned overnet-burner run reports.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $report = Overnet::Burner::Report->build(run_dir => $run_dir);

=head1 SUBROUTINES/METHODS

=head2 build

=head2 write_report

=head2 canonical_json

=head1 DIAGNOSTICS

Missing run directories and failed IO operations are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Report data is read from an overnet-burner run directory.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
