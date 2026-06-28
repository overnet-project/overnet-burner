package Overnet::Burner::Report;

use strictures 2;

use Digest::SHA;
use File::Spec;
use JSON ();
use POSIX qw(strftime);
use Time::Local qw(timegm);

my $SCHEMA_ID = 'https://overnet-project.org/schemas/overnet-burner/report-v1.schema.json';

my %THRESHOLD = (
    error_rate_max => {
        metric     => 'overall.error_rate',
        comparator => '<=',
        unit       => 'ratio',
    },
    publish_p99_ms => {
        metric     => 'publish.latency_ms.p99',
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

    my $run_dir = $args{run_dir} || die "run_dir is required\n";
    die "run directory does not exist: $run_dir\n" unless -d $run_dir;

    my $now = $args{now} || \&_iso_now;
    my $manifest = _read_json_file(_path($run_dir, 'manifest.json'));
    my $plan = _read_json_file(_path($run_dir, 'plan.json'));
    my $config = _read_json_file(_path($run_dir, 'config.normalized.json'));
    my $events = _read_jsonl_file(_path($run_dir, 'logs', 'runner.jsonl'));
    my $inventory = _read_optional_json_file(
        _path($run_dir, 'artifacts', 'rex', 'inventory', 'hosts.json'),
    );

    my $metrics = _metrics($run_dir, $plan, $manifest);
    my $report = {
        report_version => 1,
        schema         => $SCHEMA_ID,
        generated_at   => $now->(),
        run            => _run($manifest),
        scenario       => _scenario($manifest, $plan),
        environment    => _environment($manifest),
        topology       => _topology($manifest, $plan, $inventory),
        execution      => _execution($manifest, $events),
        workload       => _workload($plan),
        metrics        => $metrics,
        thresholds     => _thresholds($config, $metrics, $manifest),
        chaos          => _chaos($plan, $events),
        artifacts      => _artifacts($run_dir),
        diagnostics    => _diagnostics($manifest, $metrics),
        human_summary  => _human_summary($manifest, $metrics),
        extensions     => {},
    };

    return $report;
}

sub write {
    my ($class, %args) = @_;

    my $run_dir = $args{run_dir} || die "run_dir is required\n";
    my $report = $class->build(%args);
    my $path = _path($run_dir, 'report.json');

    _write_file($path, $class->canonical_json($report));

    return $path;
}

sub canonical_json {
    my ($class, $report) = @_;

    return JSON->new->canonical(1)->pretty(1)->space_before(0)
        ->encode($report);
}

sub _run {
    my ($manifest) = @_;

    my $status = $manifest->{status} || 'created';

    return {
        id          => $manifest->{run_id},
        status      => $status,
        verdict     => _verdict($manifest),
        result_class => (
            $status eq 'created' || $status eq 'running'
            ? 'none'
            : 'orchestration'
        ),
        created_at  => $manifest->{timestamps}{created_at}  || undef,
        started_at  => $manifest->{timestamps}{started_at}  || undef,
        finished_at => $manifest->{timestamps}{finished_at} || undef,
        duration_ms => _duration_ms(
            $manifest->{timestamps}{started_at},
            $manifest->{timestamps}{finished_at},
        ),
    };
}

sub _verdict {
    my ($manifest) = @_;

    my $status = $manifest->{status} || 'created';
    return 'not_evaluated' if $status eq 'created' || $status eq 'running';
    return 'aborted' if $status eq 'aborted';
    return 'orchestration_failed' if $status eq 'failed';
    return 'smoke_passed' if $status eq 'completed';

    return 'not_evaluated';
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
    my %descriptor = %{$topology_provider};
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

    return {
        total  => 0,
        groups => {},
    } unless ref $inventory eq 'HASH';

    return {
        total => scalar @{ $inventory->{hosts} || [] },
        groups => {
            map { $_ => scalar @{ $inventory->{groups}{$_} || [] } }
                sort keys %{ $inventory->{groups} || {} },
        },
    };
}

sub _actor_counts {
    my ($plan) = @_;
    my @roles = qw(relays publishers subscribers query_readers object_readers);
    my %counts = map { $_ => scalar @{ $plan->{$_} || [] } } @roles;
    $counts{total} = 0;
    $counts{total} += $counts{$_} for @roles;

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
        my $key = join "\0", $spec->{kind}, $spec->{id};

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

        my $record = $phase{$key};
        $record->{status} = $event->{status};
        $record->{actor_id} = $event->{actor_id} if exists $event->{actor_id};
        $record->{command} = $event->{command} if exists $event->{command};
        $record->{exit_code} = $event->{exit_code} if exists $event->{exit_code};
        $record->{error} = $event->{error} if exists $event->{error};
        $record->{started_at} = $event->{timestamp}
            if ($event->{status} || '') eq 'started';
        $record->{finished_at} = $event->{timestamp}
            if ($event->{status} || '') ne 'started';
        $record->{artifacts} = _event_artifact_refs($event)
            if exists $event->{stdout_path} || exists $event->{stderr_path};
        $record->{duration_ms} = _duration_ms(
            $record->{started_at},
            $record->{finished_at},
        );
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
            id   => join('-', 'provider', $event->{actor_id}, $event->{command_kind}),
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

    push @refs, {
        id   => "$event->{actor_id}-$event->{command_kind}-stdout",
        path => $event->{stdout_path},
    } if exists $event->{stdout_path};
    push @refs, {
        id   => "$event->{actor_id}-$event->{command_kind}-stderr",
        path => $event->{stderr_path},
    } if exists $event->{stderr_path};

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
            object_reads_per_second   => 0 + ($_->{object_reads}{count_per_second} || 0),
            subscription_filter_count => scalar @{ $_->{subscription_filters} || [] },
            query_filter_count        => scalar @{ $_->{query_filters} || [] },
            actor_seeds               => $_->{actor_seeds} || {},
        }
    } @{ $plan->{workload}{phases} || [] };

    return {
        duration_seconds => 0 + ($plan->{run}{duration_seconds} || 0),
        phases           => \@phases,
    };
}

sub _metrics {
    my ($run_dir, $plan, $manifest) = @_;

    my @streams = @{ $plan->{metric_streams} || [] };
    my @missing;
    my $seen = 0;

    for my $stream (@streams) {
        my $path = _path($run_dir, $stream->{path});
        if (-e $path && -s $path) {
            $seen++;
        }
        else {
            push @missing, $stream->{path};
        }
    }

    my $collected = @streams && $seen == @streams ? JSON::true : JSON::false;

    return {
        collected => $collected,
        reason    => $collected
            ? 'none'
            : (($manifest->{status} || '') eq 'failed' ? 'run_failed' : 'smoke_only'),
        streams => {
            expected => scalar @streams,
            seen     => $seen,
            missing  => \@missing,
        },
        operations => {},
    };
}

sub _thresholds {
    my ($config, $metrics, $manifest) = @_;
    my $thresholds = $config->{thresholds} || {};
    my @records;

    for my $id (sort keys %{$thresholds}) {
        my $spec = $THRESHOLD{$id} || {
            metric     => $id,
            comparator => '<=',
            unit       => undef,
        };
        push @records, {
            id               => $id,
            status           => $metrics->{collected} ? 'planned' : 'not_evaluated',
            metric           => $spec->{metric},
            comparator       => $spec->{comparator},
            configured_value => $thresholds->{$id},
            observed_value   => undef,
            unit             => $spec->{unit},
            reason           => $metrics->{collected}
                ? 'none'
                : (($manifest->{status} || '') eq 'failed' ? 'run_failed' : 'no_metrics'),
        };
    }

    return \@records;
}

sub _chaos {
    my ($plan, $events) = @_;
    my @hooks = map {
        {
            id                   => $_->{id},
            action               => $_->{action},
            target               => $_->{target},
            status               => 'not_evaluated',
            scheduled_at_seconds => 0 + ($_->{at_seconds} || 0),
            started_at           => undef,
            finished_at          => undef,
            duration_ms          => undef,
            error                => undef,
        }
    } @{ $plan->{chaos_hooks} || [] };

    return {
        hooks_configured => scalar @hooks,
        hooks_executed   => 0,
        hooks            => \@hooks,
    };
}

sub _artifacts {
    my ($run_dir) = @_;
    my @candidates = (
        [manifest              => 'manifest.json',                         'application/json',     'evidence',   1],
        [scenario              => 'scenario.yml',                          'application/yaml',     'input',      1],
        [normalized_config     => 'config.normalized.json',                'application/json',     'evidence',   1],
        [plan                  => 'plan.json',                             'application/json',     'evidence',   1],
        [runner_log            => 'logs/runner.jsonl',                     'application/x-ndjson', 'log',        1],
        [metrics               => 'metrics.jsonl',                         'application/x-ndjson', 'metrics',    1],
        [rex_bundle            => 'artifacts/rex/bundle.json',             'application/json',     'rex_bundle', 0],
        [rexfile               => 'artifacts/rex/Rexfile',                 'text/x-perl',          'rex_bundle', 0],
        [rex_lifecycle         => 'artifacts/rex/lifecycle.json',          'application/json',     'rex_bundle', 0],
        [rex_inventory         => 'artifacts/rex/inventory/hosts.json',    'application/json',     'rex_bundle', 0],
        [rex_topology_provider => 'artifacts/rex/topology-provider.json',  'application/json',     'rex_bundle', 0],
    );
    my @artifacts;

    for my $candidate (@candidates) {
        my ($id, $relative_path, $media_type, $role, $required) = @{$candidate};
        my $path = _path($run_dir, split m{/}, $relative_path);
        next unless -e $path;
        push @artifacts, _artifact(
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
    my ($manifest, $metrics) = @_;
    my @errors;
    my @warnings;

    if (($manifest->{status} || '') eq 'failed') {
        push @errors, {
            severity => 'error',
            code     => 'run_failed',
            message  => $manifest->{error} || 'run failed',
            source   => 'manifest.error',
        };
    }

    if (($manifest->{status} || '') eq 'completed' && !$metrics->{collected}) {
        push @warnings, {
            severity => 'warning',
            code     => 'no_real_workload',
            message  => 'Run completed without collecting real Overnet workload metrics.',
            source   => 'metrics',
        };
    }

    return {
        errors   => \@errors,
        warnings => \@warnings,
    };
}

sub _human_summary {
    my ($manifest, $metrics) = @_;

    if (($manifest->{status} || '') eq 'failed') {
        return {
            headline        => 'Run failed during orchestration.',
            important_notes => [$manifest->{error} || 'run failed'],
        };
    }

    if (!$metrics->{collected}) {
        return {
            headline        => 'Orchestration smoke completed; no real Overnet workload metrics were collected.',
            important_notes => [
                'This report proves orchestration wiring, not system performance.',
                'Thresholds were not evaluated because metrics were not collected.',
            ],
        };
    }

    return {
        headline        => 'Run completed and metrics were collected.',
        important_notes => [],
    };
}

sub _duration_ms {
    my ($started_at, $finished_at) = @_;

    return undef unless defined $started_at && defined $finished_at;
    my $started = _parse_timestamp($started_at);
    my $finished = _parse_timestamp($finished_at);
    return undef unless defined $started && defined $finished;

    return int(($finished - $started) * 1000);
}

sub _parse_timestamp {
    my ($timestamp) = @_;

    return undef unless defined $timestamp
        && $timestamp =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/;

    return eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
}

sub _read_json_file {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return JSON::decode_json(<$fh>);
}

sub _read_optional_json_file {
    my ($path) = @_;

    return undef unless -e $path;
    return _read_json_file($path);
}

sub _read_jsonl_file {
    my ($path) = @_;

    return [] unless -e $path;
    open my $fh, '<', $path or die "open $path: $!";
    my @records = map { JSON::decode_json($_) } <$fh>;
    close $fh or die "close $path: $!";
    return \@records;
}

sub _write_file {
    my ($path, $content) = @_;

    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $content;
    close $fh or die "close $path: $!";
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

sub _path {
    return File::Spec->catfile(@_);
}

sub _iso_now {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
}

1;
