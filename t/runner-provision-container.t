use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo = "$FindBin::Bin/..";
my $bin  = "$repo/bin/overnet-burner";

my $tmp         = tempdir(CLEANUP => 1);
my $engine_log  = File::Spec->catfile($tmp, 'engine-argv.log');
my $fake_worker = _write_fake_worker($tmp);
my $fake_rex    = _write_fake_rex($tmp);

local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

subtest 'container-provisioned workers run through the engine adapter' => sub {
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $engine_log;
  local $ENV{OVERNET_BURNER_DOCKER}          = _write_emulating_engine($tmp);
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

  my $scenario = _write_scenario($tmp, 'container.yml', <<"YAML");
provision:
  workers:
    how: container
    image: example.test/worker:fake
    count: 2
    worker: "$^X $fake_worker"
YAML

  my $run_id = 'container-run-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the run completes on container guests' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);

  my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is [map { $_->{transport} } @{$guests->{guests}}], ['container', 'container'],
    'container guests use the container transport';
  is $guests->{engine}{name}, 'docker', 'the detected engine is recorded in the ledger';
  like $guests->{engine}{version}, qr/emulated/mx, 'the engine version is recorded, never assumed';
  is [map { $_->{container} } @{$guests->{guests}}],
    ["burner-$run_id-worker-guest-001", "burner-$run_id-worker-guest-002"],
    'container names are namespaced by run';
  is $guests->{placement},
    {
    'publisher-001'  => 'worker-guest-001',
    'publisher-002'  => 'worker-guest-002',
    'subscriber-001' => 'worker-guest-001',
    },
    'actors are placed round-robin across container guests';

  my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
  is scalar @{$aggregated}, 3, 'every stream was pulled from its container and aggregated';

  for my $actor_id (qw(publisher-001 publisher-002 subscriber-001)) {
    ok -s File::Spec->catfile($run_dir, 'metrics', "$actor_id.jsonl"),
      "the $actor_id stream was pulled into the local run directory";
    ok -e File::Spec->catfile($run_dir, 'logs', 'workers', "$actor_id.stdout"),
      "the $actor_id stdout log was pulled into the local run directory";
  }

  my $argv = _slurp($engine_log);
  my @runs = grep {/\Arun\x{0}-d\x{0}--name\x{0}burner-\Q$run_id\E/mx} split /\n/, $argv;
  is scalar @runs, 2, 'two containers were started';
  like $runs[0], qr/--network\x{0}host/mx,                                'worker containers use host networking';
  like $runs[0], qr/example\.test\/worker:fake\x{0}sleep\x{0}infinity/mx, 'containers idle on sleep infinity';

  my @removed = grep {/\Arm\x{0}-f\x{0}burner-\Q$run_id\E/mx} split /\n/, $argv;
  is scalar @removed, 2, 'both containers were removed after collection';
};

subtest 'containers are removed even when the run fails' => sub {
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG}  = $engine_log;
  local $ENV{OVERNET_BURNER_DOCKER}           = _write_emulating_engine($tmp);
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM}  = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}    = File::Spec->catdir($tmp, 'guest-fs', 'runs');
  local $ENV{OVERNET_BURNER_TEST_WORKER_FAIL} = 1;

  my $scenario = _write_scenario($tmp, 'container-fail.yml', <<"YAML");
provision:
  workers:
    how: container
    image: example.test/worker:fake
    count: 2
    worker: "$^X $fake_worker"
YAML

  my $run_id = 'container-run-fail-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'the run fails when a containerized worker dies';

  my $manifest = _read_json(File::Spec->catfile($tmp, 'runs', $run_id, 'manifest.json'));
  is $manifest->{status}, 'failed', 'manifest records the failure';

  my @removed = grep {/\Arm\x{0}-f\x{0}burner-\Q$run_id\E/mx} split /\n/, _slurp($engine_log);
  is scalar @removed, 2, 'failure cleanup still removes every container';

  my $pulled_stderr = File::Spec->catfile($tmp, 'runs', $run_id, 'logs', 'workers', 'subscriber-001.stderr');
  ok -e $pulled_stderr, 'failure cleanup pulls worker logs back as evidence';
  like _slurp($pulled_stderr), qr/fake\sworker\sfailing\son\srequest/mx, 'the pulled stderr explains the failure';
};

subtest 'network chaos actions drive the engine and record evidence' => sub {
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $engine_log;
  local $ENV{OVERNET_BURNER_DOCKER}          = _write_emulating_engine($tmp);
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

  my $scenario = _write_scenario($tmp, 'container-net-chaos.yml', <<"YAML", 'ws://192.0.2.10:59999');
provision:
  workers:
    how: container
    image: example.test/worker:fake
    count: 2
    network: bridge
    worker: "$^X $fake_worker"
chaos:
  - at: 0
    action: net-delay
    target: worker-guest:1
    delay_ms: 100
    jitter_ms: 20
  - at: 0
    action: net-loss
    target: worker-guest:2
    loss_percent: 25
  - at: 1
    action: partition
    target: worker-guest:1
  - at: 1
    action: heal
    target: worker-guest:1
YAML

  my $run_id = 'container-net-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the chaos run completes on bridge-networked container guests' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);

  my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is $guests->{network}, {name => "burner-$run_id", mode => 'bridge'},
    'the per-run network is recorded in the guest ledger';
  is [map { $_->{cap_add} } @{$guests->{guests}}], [['NET_ADMIN'], ['NET_ADMIN']],
    'netem hooks grant NET_ADMIN to every worker container, recorded per guest';

  my $argv = _slurp($engine_log);
  like $argv, qr/^network\x{0}create\x{0}burner-\Q$run_id\E$/mx, 'the per-run network is created';
  my @runs = grep {/\Arun\x{0}/mx} split /\n/, $argv;
  is scalar(grep {/--network\x{0}burner-\Q$run_id\E\x{0}/mx} @runs), 2, 'containers join the per-run network';
  is scalar(grep {/--cap-add\x{0}NET_ADMIN/mx} @runs),               2, 'containers are granted NET_ADMIN';
  like $argv, qr/^exec\x{0}burner-\Q$run_id\E-worker-guest-001\x{0}[^\n]*netem\ delay\ 100ms\ 20ms/mx,
    'net-delay shapes guest one through tc netem';
  like $argv, qr/^exec\x{0}burner-\Q$run_id\E-worker-guest-002\x{0}[^\n]*netem\ loss\ 25%/mx,
    'net-loss shapes guest two through tc netem';
  like $argv, qr/^network\x{0}disconnect\x{0}burner-\Q$run_id\E\x{0}burner-\Q$run_id\E-worker-guest-001$/mx,
    'partition disconnects the guest from the per-run network';
  like $argv, qr/^network\x{0}connect\x{0}burner-\Q$run_id\E\x{0}burner-\Q$run_id\E-worker-guest-001$/mx,
    'heal reconnects the partitioned guest';
  like $argv, qr/^network\x{0}rm\x{0}burner-\Q$run_id\E$/mx, 'teardown removes the per-run network';

  my @completed =
    grep { ($_->{event_kind} || q{}) eq 'chaos_hook' && $_->{status} eq 'completed' }
    @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  is scalar @completed, 4, 'every network hook records a completed event';
  is [map { $_->{guest} } @completed], ['worker-guest-001', 'worker-guest-002', 'worker-guest-001', 'worker-guest-001'],
    'network hook events name the target guest';
  ok defined $_->{evidence}, "hook $_->{hook_id} records post-action evidence" for @completed;
  like $completed[0]{evidence}, qr/netem/mx, 'netem evidence is the captured qdisc state';
};

subtest 'a failing network action fails the run but still tears down' => sub {
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $engine_log;
  local $ENV{OVERNET_BURNER_DOCKER}          = _write_emulating_engine($tmp);
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');
  local $ENV{OVERNET_BURNER_TEST_NET_FAIL}   = 1;

  my $scenario = _write_scenario($tmp, 'container-net-fail.yml', <<"YAML", 'ws://192.0.2.10:59999');
provision:
  workers:
    how: container
    image: example.test/worker:fake
    count: 2
    network: bridge
    worker: "$^X $fake_worker"
chaos:
  - at: 0
    action: net-delay
    target: worker-guest:1
    delay_ms: 100
YAML

  my $run_id = 'container-net-fail-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'the run fails when a network action cannot be applied';

  my $run_dir  = File::Spec->catdir($tmp, 'runs', $run_id);
  my $manifest = _read_json(File::Spec->catfile($run_dir, 'manifest.json'));
  is $manifest->{status}, 'failed', 'manifest records the failure';

  my @failed =
    grep { ($_->{event_kind} || q{}) eq 'chaos_hook' && $_->{status} eq 'failed' }
    @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  is scalar @failed, 1, 'the failed hook records a failed event';
  ok length $failed[0]{error}, 'the failed event carries the error';

  my $argv    = _slurp($engine_log);
  my @removed = grep {/\Arm\x{0}-f\x{0}burner-\Q$run_id\E/mx} split /\n/, $argv;
  is scalar @removed, 2, 'failure cleanup still removes every container';
  like $argv, qr/^network\x{0}rm\x{0}burner-\Q$run_id\E$/mx, 'failure cleanup still removes the per-run network';
};

subtest 'a real engine runs the whole container path when available' => sub {
  my @engines = grep {length} split /\s+/, ($ENV{OVERNET_BURNER_TEST_CONTAINER_ENGINES} || q{});
  skip_all 'set OVERNET_BURNER_TEST_CONTAINER_ENGINES to run against real engines' if !@engines;

  delete local $ENV{OVERNET_BURNER_DOCKER};
  delete local $ENV{OVERNET_BURNER_PODMAN};
  delete local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG};

  for my $engine_name (@engines) {
    subtest "real $engine_name" => sub {
      my $tag = "overnet-burner-test-worker:$$";

      my $context = File::Spec->catdir($tmp, "image-$engine_name");
      mkdir $context or die "mkdir $context: $!";
      _spew(File::Spec->catfile($context, 'fake-worker'), _fake_worker_source());
      _spew(File::Spec->catfile($context, 'Dockerfile'),  <<'DOCKERFILE');
FROM docker.io/library/perl:5.38-slim
COPY fake-worker /fake-worker
DOCKERFILE

      my $build = `$engine_name build -q -t $tag $context 2>&1`;
      is $?, 0, "$engine_name builds the worker image" or diag($build);

      my $scenario = _write_scenario($tmp, "container-real-$engine_name.yml", <<"YAML");
provision:
  workers:
    how: container
    engine: $engine_name
    image: $tag
    count: 2
    worker: "perl /fake-worker"
YAML

      my $run_id = "container-real-$engine_name-001";
      my $output =
        `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
      is $?, 0, "the run completes on real $engine_name containers" or diag($output);

      my $run_dir    = File::Spec->catdir($tmp, 'runs', $run_id);
      my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
      is scalar @{$aggregated}, 3, "every stream came back from real $engine_name containers";

      my $leftovers = `$engine_name ps -a --format '{{.Names}}' 2>&1`;
      unlike $leftovers, qr/burner-\Q$run_id\E/mx, "no $engine_name containers outlive the run";

      system $engine_name, 'rmi', '-f', $tag;
    };
  }
};

subtest 'a real engine executes network chaos with recorded evidence' => sub {
  my @engines = grep {length} split /\s+/, ($ENV{OVERNET_BURNER_TEST_CONTAINER_ENGINES} || q{});
  skip_all 'set OVERNET_BURNER_TEST_CONTAINER_ENGINES to run against real engines' if !@engines;

  delete local $ENV{OVERNET_BURNER_DOCKER};
  delete local $ENV{OVERNET_BURNER_PODMAN};
  delete local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG};

  for my $engine_name (@engines) {
    subtest "real $engine_name network chaos" => sub {
      my $tag = "overnet-burner-test-netchaos:$$";

      my $context = File::Spec->catdir($tmp, "image-net-$engine_name");
      mkdir $context or die "mkdir $context: $!";
      _spew(File::Spec->catfile($context, 'fake-worker'), _fake_worker_source());
      _spew(File::Spec->catfile($context, 'Dockerfile'),  <<'DOCKERFILE');
FROM docker.io/library/perl:5.38-slim
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 && rm -rf /var/lib/apt/lists/*
COPY fake-worker /fake-worker
DOCKERFILE

      my $build = `$engine_name build -q -t $tag $context 2>&1`;
      is $?, 0, "$engine_name builds the netchaos worker image" or diag($build);

      my $scenario = _write_scenario($tmp, "container-net-real-$engine_name.yml", <<"YAML", 'ws://192.0.2.10:59999');
provision:
  workers:
    how: container
    engine: $engine_name
    image: $tag
    count: 2
    network: bridge
    worker: "perl /fake-worker"
chaos:
  - at: 0
    action: net-delay
    target: worker-guest:1
    delay_ms: 100
  - at: 0
    action: partition
    target: worker-guest:2
  - at: 1
    action: heal
    target: worker-guest:2
YAML

      my $run_id = "container-net-real-$engine_name-001";
      my $output =
        `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
      is $?, 0, "the chaos run completes on real $engine_name containers" or diag($output);

      my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
      my %completed =
        map  { $_->{hook_id} => $_ }
        grep { ($_->{event_kind} || q{}) eq 'chaos_hook' && $_->{status} eq 'completed' }
        @{_read_jsonl("$run_dir/logs/runner.jsonl")};
      is scalar keys %completed, 3, "every hook completed on real $engine_name";
      like $completed{'chaos-001'}{evidence}, qr/netem/mx,         "real $engine_name evidence shows the netem qdisc";
      like $completed{'chaos-001'}{evidence}, qr/delay\s+100ms/mx, "real $engine_name evidence shows the delay";
      unlike $completed{'chaos-002'}{evidence}, qr/default/mx,
        "a partitioned guest has no default route on real $engine_name";
      like $completed{'chaos-003'}{evidence}, qr/default/mx, "a healed guest routes again on real $engine_name";

      my $leftover_networks = `$engine_name network ls --format '{{.Name}}' 2>&1`;
      unlike $leftover_networks, qr/burner-\Q$run_id\E/mx, "no $engine_name networks outlive the run";
      my $leftovers = `$engine_name ps -a --format '{{.Names}}' 2>&1`;
      unlike $leftovers, qr/burner-\Q$run_id\E/mx, "no $engine_name containers outlive the run";

      system $engine_name, 'rmi', '-f', $tag;
    };
  }
};

done_testing;

sub _write_scenario {
  my ($dir, $basename, $provision_yaml, $endpoint) = @_;

  $endpoint ||= 'ws://127.0.0.1:59999';
  my $path = File::Spec->catfile($dir, $basename);
  _spew($path, <<"YAML");
run:
  name: container-provision
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - $endpoint
  publishers:
    count: 2
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
$provision_yaml
YAML

  return $path;
}

sub _write_emulating_engine {
  my ($dir) = @_;

  my $path = File::Spec->catfile($dir, 'emulating-engine');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;

# Emulates a container with its own filesystem: every guest-side path is
# relocated under a shadow root, so nothing the "container" writes ever
# appears at the controller-side path.
sub remap {
  my ($value) = @_;
  my $from = $ENV{OVERNET_BURNER_TEST_REMAP_FROM};
  my $to   = $ENV{OVERNET_BURNER_TEST_REMAP_TO};
  return $value if !(defined $from && defined $to);
  $value =~ s/\Q$from\E/$to/g;
  return $value;
}

if (my $log = $ENV{OVERNET_BURNER_TEST_ENGINE_LOG}) {
  open my $fh, '>>', $log or die "log: $!";
  print {$fh} join("\0", @ARGV), "\n";
  close $fh or die "close: $!";
}

my $subcommand = shift @ARGV // '';
if ($subcommand eq '--version') {
  print "Docker version 99.0-emulated\n";
  exit 0;
}
if ($subcommand eq 'run') {
  print "emulated-container-id\n";
  exit 0;
}
if ($subcommand eq 'exec') {
  my (undef, undef, undef, $command) = @ARGV;
  if ($command =~ /\btc\s/) {
    exit 1 if $ENV{OVERNET_BURNER_TEST_NET_FAIL};
    print "qdisc netem 8001: root refcnt 2 limit 1000 delay 100ms  20ms\n";
    exit 0;
  }
  if ($command =~ /\bip\s+-o\s+route\b/) {
    print "default via 172.18.0.1 dev eth0\n";
    exit 0;
  }
  exec '/bin/sh', '-c', remap($command) or die "exec: $!";
}
if ($subcommand eq 'cp') {
  my ($src, $dst) = @ARGV;
  $dst =~ s/\A[^:]+://;
  $dst = remap($dst);
  open my $in, '<', $src or die "open $src: $!";
  my $content = do { local $/; <$in> };
  close $in or die "close $src: $!";
  open my $out, '>', $dst or die "open $dst: $!";
  print {$out} remap($content) or die "print $dst: $!";
  close $out or die "close $dst: $!";
  exit 0;
}
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";

  return $path;
}

sub _fake_worker_source {
  return <<'PERL';
#!/usr/bin/env perl
use strict;
use warnings;
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
    started_at     => '2026-07-03T18:00:00Z',
    finished_at    => '2026-07-03T18:00:00.001Z',
    duration_ms    => 1,
    status         => 'success',
);
open my $stream, '>>', "$input->{run_dir}/$input->{metric_stream}" or die "stream: $!";
print {$stream} JSON::PP->new->canonical(1)->encode(\%metric), "\n" or die "print: $!";
close $stream or die "close stream: $!";
exit 0;
PERL
}

sub _write_fake_rex {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-rex');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
my $log = $ENV{OVERNET_BURNER_TEST_REX_LOG} or die "OVERNET_BURNER_TEST_REX_LOG is required\n";
open my $fh, '>>', $log or die "open $log: $!";
print {$fh} join("\0", @ARGV), "\n";
close $fh or die "close $log: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _write_fake_worker {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-worker');
  _spew($path, _fake_worker_source());
  chmod 0755, $path or die "chmod: $!";
  return $path;
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

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
