use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use JSON::Schema::Modern;
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo = "$FindBin::Bin/..";
my $bin  = "$repo/bin/overnet-burner";
my $schema =
  JSON::decode_json(_slurp(File::Spec->catfile($repo, 'schemas', 'worker-input-v1.schema.json')));

my $tmp         = tempdir(CLEANUP => 1);
my $fake_rex    = _write_fake_rex($tmp);
my $fake_worker = _write_fake_worker($tmp);

local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');
local $ENV{OVERNET_BURNER_WORKER}       = "$^X $fake_worker";

my $scenario = _write_scenario(
  "$tmp/workers.yml",
  relays_extra   => "    endpoints:\n      - ws://127.0.0.1:59999",
  publishers     => 1,
  subscribers    => 1,
  query_readers  => 1,
  object_readers => 1,
  observers      => 1,
);

subtest 'workers runner launches contract workers and collects streams' => sub {
  my $run_id = 'workers-run-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'workers runner completes' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);

  my $manifest = _read_json(File::Spec->catfile($run_dir, 'manifest.json'));
  is $manifest->{status},       'completed',         'manifest records completion';
  is $manifest->{runner}{name}, 'rex-local-workers', 'manifest records the workers runner';

  my $input_path = File::Spec->catfile($run_dir, 'workers', 'publisher-001', 'input.json');
  ok -f $input_path, 'runner wrote the publisher worker input document';
  my $input  = _read_json($input_path);
  my $result = JSON::Schema::Modern->new->evaluate($input, $schema);
  ok $result->valid, 'worker input validates against worker-input-v1';
  is $input->{worker_id},         'publisher-001',               'input names the actor';
  is $input->{endpoints}{relays}, ['ws://127.0.0.1:59999'],      'input carries the scenario relay endpoints';
  is $input->{metric_stream},     'metrics/publisher-001.jsonl', 'input assigns the plan metric stream';
  is $input->{duration_seconds},  2,                             'input carries the total run duration';
  is [map { $_->{name} } @{$input->{phases}}], ['main'],         'input carries the ordered phase list';
  ok !exists $input->{phases}[0]{actor_seeds}, 'input phases do not leak other actors seeds';

  my $plan = _read_json(File::Spec->catfile($run_dir, 'plan.json'));
  is $input->{seed}, $plan->{publishers}[0]{seed}, 'input carries the actor plan seed';

  my $stream = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  is scalar @{$stream},       1,               'fake worker emitted its metric event';
  is $stream->[0]{worker_id}, 'publisher-001', 'metric event names the worker';

  my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
  is scalar @{$aggregated}, 5, 'collect concatenated every worker stream into metrics.jsonl';

  ok -f File::Spec->catfile($run_dir, 'logs', 'workers', 'publisher-001.stdout'), 'worker stdout is captured';

  my @events = grep { ($_->{event_kind} || q{}) eq 'worker' } @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  my %by_status;
  push @{$by_status{$_->{status}}}, $_ for @events;
  is [map { $_->{actor_id} } @{$by_status{launched}}],
    ['subscriber-001', 'query-reader-001', 'object-reader-001', 'observer-001', 'publisher-001'],
    'runner launched subscribers, readers, and observers before publishers';
  is [map { $_->{actor_id} } @{$by_status{ready}}],
    ['subscriber-001', 'query-reader-001', 'object-reader-001', 'observer-001', 'publisher-001'],
    'runner observed first-wave readiness before launching the publisher';
  is [sort map {"$_->{actor_id}:$_->{exit_code}"} @{$by_status{exited}}],
    ['object-reader-001:0', 'observer-001:0', 'publisher-001:0', 'query-reader-001:0', 'subscriber-001:0'],
    'runner reaped every worker exit';
  is $by_status{skipped_no_worker}, undef, 'every current plan role has a reference worker';
};

subtest 'workers are assigned relays round-robin' => sub {
  my $scenario_multi = _write_scenario(
    "$tmp/multi-relay.yml",
    relays_count => 2,
    relays_extra => "    endpoints:\n      - ws://127.0.0.1:58881\n      - ws://127.0.0.1:58882",
    publishers   => 2,
    subscribers  => 1,
  );

  my $run_id = 'workers-run-multi-001';
  my $output =
    `$^X $bin run --scenario $scenario_multi --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'multi-relay run completes' or diag($output);

  my $run_dir  = File::Spec->catdir($tmp, 'runs', $run_id);
  my %expected = (
    'publisher-001'  => ['ws://127.0.0.1:58881', 'ws://127.0.0.1:58882'],
    'publisher-002'  => ['ws://127.0.0.1:58882', 'ws://127.0.0.1:58881'],
    'subscriber-001' => ['ws://127.0.0.1:58881', 'ws://127.0.0.1:58882'],
  );
  for my $actor_id (sort keys %expected) {
    my $input = _read_json(File::Spec->catfile($run_dir, 'workers', $actor_id, 'input.json'));
    is $input->{endpoints}{relays}, $expected{$actor_id},
      "$actor_id gets its assigned relay first and every endpoint after";
  }
};

subtest 'a failing worker fails the run' => sub {
  local $ENV{OVERNET_BURNER_TEST_WORKER_FAIL} = 1;
  my $run_id = 'workers-run-fail-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'run fails when a worker exits non-zero';
  like $output, qr/worker\ subscriber-001/mx, 'failure names the first-wave worker that died';

  my $manifest = _read_json(File::Spec->catfile($tmp, 'runs', $run_id, 'manifest.json'));
  is $manifest->{status}, 'failed', 'manifest records the failure';
};

subtest 'workers require declared relay endpoints' => sub {
  my $no_endpoints = _write_scenario("$tmp/no-endpoints.yml", publishers => 1, subscribers => 0);
  my $run_id       = 'workers-run-noendpoints-001';
  my $output =
    `$^X $bin run --scenario $no_endpoints --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'run fails without relay endpoints';
  like $output, qr/topology\.relays\.endpoints/mx, 'failure names the missing scenario field';
};

subtest 'chaos hooks fire during the workload window' => sub {
  my $provider_log   = File::Spec->catfile($tmp, 'chaos-provider.log');
  my $scenario_chaos = "$tmp/chaos.yml";
  _write_yaml($scenario_chaos, <<"YAML");
run:
  name: workers-chaos
  duration: 3
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "echo start >> $provider_log"
      health: "echo health >> $provider_log"
      stop: "echo stop >> $provider_log"
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
chaos:
  - at: 1
    action: restart
    target: relay:1
thresholds:
  error_rate_max: 0.5
YAML

  my $run_id = 'workers-chaos-001';
  my $output =
    `$^X $bin run --scenario $scenario_chaos --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'chaos run completes' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);

  my @provider_ops = grep {length} split /\n/, _slurp($provider_log);
  is \@provider_ops, [qw(start health stop start health stop)],
    'provider saw the initial start, the chaos restart, and the teardown stop';

  my @chaos_events =
    grep { ($_->{event_kind} || q{}) eq 'chaos_hook' } @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  is [map {"$_->{hook_id}:$_->{status}"} @chaos_events], ['chaos-001:started', 'chaos-001:completed'],
    'ledger records the chaos hook lifecycle';
  is $chaos_events[1]{action},   'restart',   'chaos event records the action';
  is $chaos_events[1]{target},   'relay:1',   'chaos event records the target';
  is $chaos_events[1]{actor_id}, 'relay-001', 'chaos event resolves the relay actor';
  ok $chaos_events[1]{offset_seconds} >= 1, 'hook fired no earlier than scheduled'
    or diag($chaos_events[1]{offset_seconds});
  ok defined $chaos_events[1]{duration_ms} && $chaos_events[1]{duration_ms} >= 0, 'chaos event records its duration';

  my $report_out = `$^X $bin report --run-dir $run_dir 2>&1`;
  is $?, 0, 'report generates for the chaos run' or diag($report_out);
  my $report = _read_json(File::Spec->catfile($run_dir, 'report.json'));
  is $report->{chaos}{hooks_executed},   1,           'report counts the executed hook';
  is $report->{chaos}{hooks}[0]{status}, 'completed', 'report records the hook as completed';
  ok $report->{chaos}{hooks}[0]{started_at} && $report->{chaos}{hooks}[0]{finished_at},
    'report carries real hook timings';
  is $report->{run}{verdict},      'chaos_passed', 'passing thresholds under chaos give a chaos verdict';
  is $report->{run}{result_class}, 'chaos',        'the run is classified as a chaos experiment';
};

subtest 'a failing chaos hook fails the run' => sub {
  my $counter        = File::Spec->catfile($tmp, 'chaos-start-count');
  my $scenario_chaos = "$tmp/chaos-fail.yml";
  _write_yaml($scenario_chaos, <<"YAML");
run:
  name: workers-chaos-fail
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "n=\$(cat $counter 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > $counter; [ \$n -le 1 ]"
      health: "true"
      stop: "true"
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
chaos:
  - at: 0
    action: start
    target: relay:1
YAML

  my $run_id = 'workers-chaos-fail-001';
  my $output =
    `$^X $bin run --scenario $scenario_chaos --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'run fails when a chaos hook cannot execute';
  like $output, qr/chaos\ hook\ chaos-001/mx, 'failure names the chaos hook';

  my $run_dir  = File::Spec->catdir($tmp, 'runs', $run_id);
  my $manifest = _read_json(File::Spec->catfile($run_dir, 'manifest.json'));
  is $manifest->{status}, 'failed', 'manifest records the failure';

  my @chaos_events =
    grep { ($_->{event_kind} || q{}) eq 'chaos_hook' } @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  my ($failed) = grep { $_->{status} eq 'failed' } @chaos_events;
  ok $failed, 'ledger records the failed chaos hook';
  like $failed->{error}, qr/provider\ command\ failed/mx, 'failed hook carries the provider error';
};

subtest 'chaos end to end: a real relay restart is measured, not fatal' => sub {
  my $port      = _free_port();
  my $relay_pid = File::Spec->catfile($tmp, 'chaos-e2e-relay.pid');
  my $start     = "$^X -MNet::Nostr::Relay -e 'Net::Nostr::Relay->new->run(q(127.0.0.1), $port)' "
    . "> /dev/null 2>&1 & echo \$! > $relay_pid";
  my $health =
      "$^X -MIO::Socket::INET -e '"
    . 'for (1 .. 100) { exit 0 if IO::Socket::INET->new(PeerAddr => q(127.0.0.1), PeerPort => '
    . $port
    . ', Timeout => 1); select undef, undef, undef, 0.1 } exit 1' . "'";
  my $stop = "kill \$(cat $relay_pid)";

  my $scenario_chaos = "$tmp/chaos-e2e.yml";
  _write_yaml($scenario_chaos, <<"YAML");
run:
  name: chaos-e2e
  duration: 8
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "$start"
      health: "$health"
      stop: "$stop"
    endpoints:
      - ws://127.0.0.1:$port
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
chaos:
  - at: 2
    action: restart
    target: relay:1
thresholds:
  error_rate_max: 0.5
YAML

  local $ENV{OVERNET_BURNER_WORKER} = "$^X -I$repo/lib $repo/bin/overnet-burner-worker";
  my $run_id = 'chaos-e2e-001';
  my $output =
    `$^X $bin run --scenario $scenario_chaos --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the chaos run completes despite the mid-run relay restart' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
  my $stream  = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));

  my @errors = grep { $_->{status} eq 'error' } @{$stream};
  ok @errors >= 1, 'the outage shows up as publish error metrics' or diag(scalar @{$stream});

  my ($last_error_index) = grep { $stream->[$_]{status} eq 'error' } reverse 0 .. $#{$stream};
  my @after_recovery = grep { $_->{status} eq 'success' } @{$stream}[$last_error_index .. $#{$stream}];
  ok @after_recovery >= 1, 'the publisher recovered and published against the restarted relay';

  my $report_out = `$^X $bin report --run-dir $run_dir 2>&1`;
  is $?, 0, 'report generates for the chaos run' or diag($report_out);
  my $report = _read_json(File::Spec->catfile($run_dir, 'report.json'));
  is $report->{chaos}{hooks_executed}, 1,              'report counts the executed restart hook';
  is $report->{run}{verdict},          'chaos_passed', 'the system met its thresholds under chaos';
  is $report->{run}{result_class},     'chaos',        'the run is judged as a chaos experiment';
};

subtest 'end to end: real relay, real publisher, real metrics' => sub {
  my $port      = _free_port();
  my $relay_pid = File::Spec->catfile($tmp, 'relay.pid');
  my $start     = "$^X -MNet::Nostr::Relay -e 'Net::Nostr::Relay->new->run(q(127.0.0.1), $port)' "
    . "> /dev/null 2>&1 & echo \$! > $relay_pid";
  my $health =
      "$^X -MIO::Socket::INET -e '"
    . 'for (1 .. 100) { exit 0 if IO::Socket::INET->new(PeerAddr => q(127.0.0.1), PeerPort => '
    . $port
    . ', Timeout => 1); select undef, undef, undef, 0.1 } exit 1' . "'";
  my $stop = "kill \$(cat $relay_pid)";

  my $scenario_e2e = "$tmp/e2e.yml";
  _write_yaml($scenario_e2e, <<"YAML");
run:
  name: workers-e2e
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "$start"
      health: "$health"
      stop: "$stop"
    endpoints:
      - ws://127.0.0.1:$port
  publishers:
    count: 1
  subscribers:
    count: 1
  query_readers:
    count: 1
  object_readers:
    count: 0
  observers:
    count: 1
workload:
  publish_rate_per_second: 5
  query_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
  query_filters:
    - kinds: [7800]
YAML

  local $ENV{OVERNET_BURNER_WORKER} = "$^X -I$repo/lib $repo/bin/overnet-burner-worker";
  my $run_id = 'workers-e2e-001';
  my $output =
    `$^X $bin run --scenario $scenario_e2e --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'end-to-end run completes' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
  my $stream  = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  ok @{$stream} >= 3, 'real publisher emitted publish metrics' or diag(scalar @{$stream});

  my @failures = grep { $_->{status} ne 'success' } @{$stream};
  is \@failures, [], 'every publish against the provider relay succeeded';

  my $fanout = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'subscriber-001.jsonl'));
  ok @{$fanout} >= 1,          'real subscriber measured live fanout' or diag(scalar @{$fanout});
  ok @{$fanout} <= @{$stream}, 'subscriber measured at most the published events';

  my @bad_fanout =
    grep { $_->{operation} ne 'subscription_fanout' || $_->{status} ne 'success' } @{$fanout};
  is \@bad_fanout, [], 'subscriber metrics are successful subscription_fanout events';

  my %published_ids = map  { $_->{event_id} => 1 } @{$stream};
  my @unknown_ids   = grep { !$published_ids{$_->{event_id}} } @{$fanout};
  is \@unknown_ids, [], 'every fanout metric names an event the publisher actually published';

  my $queries =
    Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'query-reader-001.jsonl'));
  ok @{$queries} >= 1, 'real query reader measured queries' or diag(scalar @{$queries});

  my @bad_queries =
    grep { $_->{operation} ne 'query' || $_->{status} ne 'success' } @{$queries};
  is \@bad_queries, [], 'query metrics are successful query events';

  my @bad_result_counts =
    grep { !defined $_->{result_count} || $_->{result_count} > @{$stream} } @{$queries};
  is \@bad_result_counts, [], 'no query claims more stored events than were published';

  my $pings = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'observer-001.jsonl'));
  ok @{$pings} >= 1, 'the observer produced relay-side evidence' or diag(scalar @{$pings});
  my @bad_pings = grep { $_->{operation} ne 'relay_ping' || $_->{status} ne 'success' } @{$pings};
  is \@bad_pings, [], 'observer pings against the live relay succeed';

  my $report_out = `$^X $bin report --run-dir $run_dir 2>&1`;
  is $?, 0, 'report generates for the end-to-end run';
  my $report = _read_json(File::Spec->catfile($run_dir, 'report.json'));
  is $report->{run}{status}, 'completed', 'end-to-end run completed';
  ok $report->{metrics}{streams}{seen} >= 4, 'report sees every collected worker stream';
};

done_testing;

sub _write_scenario {
  my ($path, %args) = @_;
  my $relays_count   = delete $args{relays_count} // 1;
  my $relays_extra   = delete $args{relays_extra} // q{};
  my $publishers     = delete $args{publishers};
  my $subscribers    = delete $args{subscribers};
  my $query_readers  = delete $args{query_readers}  // 0;
  my $object_readers = delete $args{object_readers} // 0;
  my $observers      = delete $args{observers}      // 0;
  _write_yaml($path, <<"YAML");
run:
  name: workers-runner
  duration: 2
  seed: 12345
topology:
  relays:
    count: $relays_count
    provider: generic-relay
$relays_extra
  publishers:
    count: $publishers
  subscribers:
    count: $subscribers
  query_readers:
    count: $query_readers
  object_readers:
    count: $object_readers
  observers:
    count: $observers
workload:
  publish_rate_per_second: 5
YAML
  return $path;
}

sub _write_fake_rex {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-rex');
  _write_yaml($path, <<'PERL');
#!/usr/bin/env perl
use strictures 2;
my $log = $ENV{OVERNET_BURNER_TEST_REX_LOG} or die "OVERNET_BURNER_TEST_REX_LOG is required\n";
open my $fh, '>>', $log or die "open $log: $!";
print {$fh} join("\0", @ARGV), "\n";
close $fh or die "close $log: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod $path: $!";
  return $path;
}

sub _write_fake_worker {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-worker');
  _write_yaml($path, <<'PERL');
#!/usr/bin/env perl
use strictures 2;
use JSON::PP ();
my $input_path = $ENV{OVERNET_BURNER_WORKER_INPUT} or die "OVERNET_BURNER_WORKER_INPUT is required\n";
open my $in, '<', $input_path or die "open $input_path: $!";
my $input = JSON::PP::decode_json(do { local $/; <$in> });
close $in or die "close: $!";

if ($ENV{OVERNET_BURNER_TEST_WORKER_FAIL}) {
    die "fake worker failing on request\n";
}

open my $ready, '>', "$input->{run_dir}/$input->{ready_file}" or die "ready: $!";
close $ready or die "close ready: $!";

my %metric = (
    metric_version => 1,
    run_id         => $input->{run_id},
    worker_id      => $input->{worker_id},
    host           => 'fake-host',
    role           => $input->{role},
    operation      => 'noop_probe',
    started_at     => '2026-07-02T18:00:00Z',
    finished_at    => '2026-07-02T18:00:00.001Z',
    duration_ms    => 1,
    status         => 'success',
);
open my $stream, '>>', "$input->{run_dir}/$input->{metric_stream}" or die "stream: $!";
print {$stream} JSON::PP->new->canonical(1)->encode(\%metric), "\n" or die "print: $!";
close $stream or die "close stream: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod $path: $!";
  return $path;
}

sub _free_port {
  my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
  ) or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _read_json {
  my ($path) = @_;
  return JSON::decode_json(_slurp($path));
}

sub _read_jsonl {
  my ($path) = @_;
  return [map { JSON::decode_json($_) } grep {/\S/} split /\n/, _slurp($path)];
}

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return $content;
}

sub _write_yaml {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
