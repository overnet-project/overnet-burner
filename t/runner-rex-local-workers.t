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
  relays_extra => "    endpoints:\n      - ws://127.0.0.1:59999",
  publishers   => 1,
  subscribers  => 1,
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
  is $input->{duration_seconds},  2,                             'input carries the run duration';

  my $plan = _read_json(File::Spec->catfile($run_dir, 'plan.json'));
  is $input->{seed}, $plan->{publishers}[0]{seed}, 'input carries the actor plan seed';

  my $stream = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  is scalar @{$stream},       1,               'fake worker emitted its metric event';
  is $stream->[0]{worker_id}, 'publisher-001', 'metric event names the worker';

  my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
  is scalar @{$aggregated}, 1, 'collect concatenated the publisher stream into metrics.jsonl';

  ok -f File::Spec->catfile($run_dir, 'logs', 'workers', 'publisher-001.stdout'), 'worker stdout is captured';

  my @events = grep { ($_->{event_kind} || q{}) eq 'worker' } @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  my %by_status;
  push @{$by_status{$_->{status}}}, $_ for @events;
  is [map { $_->{actor_id} } @{$by_status{launched}}], ['publisher-001'], 'runner launched the publisher worker';
  is [map { $_->{actor_id} } @{$by_status{ready}}],    ['publisher-001'], 'runner observed worker readiness';
  is [map {"$_->{actor_id}:$_->{exit_code}"} @{$by_status{exited}}], ['publisher-001:0'],
    'runner reaped the worker exit';
  is [map { $_->{actor_id} } @{$by_status{skipped_no_worker}}], ['subscriber-001'],
    'roles without a reference worker are skipped explicitly';
};

subtest 'a failing worker fails the run' => sub {
  local $ENV{OVERNET_BURNER_TEST_WORKER_FAIL} = 1;
  my $run_id = 'workers-run-fail-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'run fails when a worker exits non-zero';
  like $output, qr/worker\ publisher-001/mx, 'failure names the worker';

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
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0
workload:
  publish_rate_per_second: 5
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

  my $report_out = `$^X $bin report --run-dir $run_dir 2>&1`;
  is $?, 0, 'report generates for the end-to-end run';
  my $report = _read_json(File::Spec->catfile($run_dir, 'report.json'));
  is $report->{run}{status}, 'completed', 'end-to-end run completed';
  ok $report->{metrics}{streams}{seen} >= 1, 'report sees the collected publisher stream';
};

done_testing;

sub _write_scenario {
  my ($path, %args) = @_;
  my $relays_extra = delete $args{relays_extra} // q{};
  my $publishers   = delete $args{publishers};
  my $subscribers  = delete $args{subscribers};
  _write_yaml($path, <<"YAML");
run:
  name: workers-runner
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
$relays_extra
  publishers:
    count: $publishers
  subscribers:
    count: $subscribers
  query_readers:
    count: 0
  object_readers:
    count: 0
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
