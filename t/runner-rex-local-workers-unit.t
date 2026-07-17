use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;
use Time::HiRes ();

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::ContainerEngine;
use Overnet::Burner::Guest::Container;
use Overnet::Burner::Guest::Virtual;
use Overnet::Burner::Runner;
use Overnet::Burner::Runner::RexLocalWorkers;
use Overnet::Burner::RunLedger;

package Overnet::Burner::Test::ScriptedGuest {
  use Moo;

  has name          => (is => 'ro', default => 'scripted-guest');
  has role          => (is => 'ro', default => 'workers');
  has transport     => (is => 'ro', default => 'ssh');
  has clock_stdout  => (is => 'ro');
  has reachable_now => (is => 'ro', default => 0);
  has read_dies     => (is => 'ro', default => 1);

  no Moo;

  sub run_command {
    my ($self) = @_;
    return {stdout => $self->clock_stdout, stderr => q{}, exit_code => 0};
  }

  sub reachable { my ($self) = @_; return $self->reachable_now }

  sub read_file {
    my ($self) = @_;
    die "scripted read failure\n" if $self->read_dies;
    return;
  }
  sub destroy {1}
}

package Overnet::Burner::Test::ReapingGuest {
  use Moo;

  has name        => (is => 'ro', default => 'reaping-guest');
  has role        => (is => 'ro', default => 'workers');
  has transport   => (is => 'ro', default => 'exec');
  has signals     => (is => 'ro', default => sub { [] });
  has fail_signal => (is => 'ro', default => 0);

  no Moo;

  sub signal {
    my ($self, $handle, $signal) = @_;
    push @{$self->signals}, "$handle:$signal";
    die "scripted signal failure\n" if $self->fail_signal;
    return 1;
  }

  # Report a clean exit so the runner reaps the worker after the first pass.
  sub try_reap {0}
  sub destroy  {1}
}

my $tmp         = tempdir(CLEANUP => 1);
my $fake_rex    = _write_fake_rex($tmp);
my $fake_worker = _write_fake_worker($tmp);

local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');
local $ENV{OVERNET_BURNER_WORKER}       = "$^X $fake_worker";

subtest 'local workers complete, skip unknown roles, and aggregate streams' => sub {
  my $scenario_path = _write_workers_scenario(File::Spec->catfile($tmp, 'workers.yml'));
  my ($runner, $error, $ledger) = _run_lifecycle(
    scenario_path => $scenario_path,
    run_id        => 'local-green',
    plan_mutator  => sub {
      my ($plan) = @_;
      push @{$plan->{observers}},
        {id => 'mystic-001', role => 'mystic', ordinal => 2, seed => 1, metric_stream => 'metrics/mystic-001.jsonl'};
    },
  );
  is $error, undef, 'the lifecycle completes' or diag($error);

  my %fields = $runner->summary_fields;
  is [sort map {"$_->{actor_id}:$_->{exit_code}"} @{$fields{worker_results}}],
    ['object-reader-001:0', 'observer-001:0', 'publisher-001:0', 'query-reader-001:0', 'subscriber-001:0'],
    'every launched worker exited cleanly';
  is $fields{chaos_results}, [], 'no chaos hooks ran';

  my $run_dir = $runner->{run_dir};
  ok -s File::Spec->catfile($run_dir, 'metrics.jsonl'), 'the collected streams are aggregated';
  ok -e File::Spec->catfile($run_dir, 'guests.json'),   'the guest ledger is written';
  my $clocks = _read_json(File::Spec->catfile($run_dir, 'clocks.json'));
  is $clocks->{guests}[0]{offset_ms}, 0, 'a local guest shares the controller clock';

  my @events  = @{_read_jsonl(File::Spec->catfile($run_dir, 'logs', 'runner.jsonl'))};
  my ($skip)  = grep { ($_->{status} || q{}) eq 'skipped_no_worker' } @events;
  ok $skip, 'a role without a reference worker is recorded as skipped';
  is $skip->{actor_id}, 'mystic-001', 'the skipped actor is named';

  ok $runner->teardown_on_signal, 'signal teardown after an orderly run is a quiet no-op';
};

subtest 'worker exit behaviors fail the run with named workers' => sub {
  my $scenario_path = _write_workers_scenario(
    File::Spec->catfile($tmp, 'one-worker.yml'),
    publishers  => 1,
    subscribers => 0,
    duration    => 1,
  );

  {
    local $ENV{OVERNET_BURNER_TEST_WORKER_MODE} = 'fail';
    my (undef, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'exit-before-ready');
    like $error, qr/worker\ publisher-001\ exited\ before\ becoming\ ready/mx,
      'a worker that dies before readiness names itself';
  }

  {
    local $ENV{OVERNET_BURNER_TEST_WORKER_MODE} = 'exit-dirty';
    my ($runner, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'exit-dirty');
    like $error, qr/worker\ publisher-001\ did\ not\ complete\ cleanly/mx,
      'a worker that exits non-zero after readiness fails the run';
    my %fields = $runner->summary_fields;
    is $fields{worker_results}[0]{exit_code}, 3, 'the dirty exit code is recorded';
  }
};

subtest 'a worker that ignores TERM is killed and fails the run' => sub {
  my $scenario_path = _write_workers_scenario(
    File::Spec->catfile($tmp, 'hang.yml'),
    publishers  => 1,
    subscribers => 0,
    duration    => 1,
  );

  # exec drops the /bin/sh wrapper so the signals reach the worker itself,
  # which ignores TERM and therefore exercises the KILL escalation.
  local $ENV{OVERNET_BURNER_WORKER}           = "exec $^X $fake_worker";
  local $ENV{OVERNET_BURNER_TEST_WORKER_MODE} = 'hang-ignore-term';
  my ($runner, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'hang-kill');
  like $error, qr/worker\ publisher-001\ did\ not\ complete\ cleanly/mx,
    'a worker that had to be killed fails the run';
  my %fields = $runner->summary_fields;
  is $fields{worker_results}[0]{signal}, 9, 'the kill signal is recorded on the worker result';
  ok !exists $fields{worker_results}[0]{exit_code}, 'a signalled worker records no exit code';
};

subtest 'a worker that never becomes ready times out' => sub {
  my $scenario_path = _write_workers_scenario(
    File::Spec->catfile($tmp, 'no-ready.yml'),
    publishers  => 1,
    subscribers => 0,
    duration    => 1,
  );

  local $ENV{OVERNET_BURNER_TEST_WORKER_MODE} = 'no-ready';
  my (undef, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'never-ready');
  like $error, qr/worker\ publisher-001\ was\ not\ ready\ within/mx, 'the readiness timeout names the worker';
};

subtest 'runs without launchable workers or endpoints' => sub {
  my $no_workers_path = File::Spec->catfile($tmp, 'no-workers.yml');
  _write_yaml($no_workers_path, <<'YAML');
run:
  name: workers-none
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "exit 0"
      health: "exit 0"
      stop: "exit 0"
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
  my (undef, $error) = _run_lifecycle(scenario_path => $no_workers_path, run_id => 'no-workers');
  is $error, undef, 'a run without launchable workers completes' or diag($error);

  my $no_endpoints_path = _write_workers_scenario(
    File::Spec->catfile($tmp, 'no-endpoints.yml'),
    publishers  => 1,
    subscribers => 0,
    endpoints   => q{},
  );
  my (undef, $endpoint_error) = _run_lifecycle(scenario_path => $no_endpoints_path, run_id => 'no-endpoints');
  like $endpoint_error, qr/topology\.relays\.endpoints\ is\ required/mx, 'launching workers requires endpoints';
};

subtest 'the worker command is resolved and pre-flighted' => sub {
  my $scenario_path = File::Spec->catfile($tmp, 'missing-command.yml');
  _write_yaml($scenario_path, <<'YAML');
run:
  name: workers-missing-command
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: local
    worker: overnet-burner-worker-not-on-path-xyzzy
YAML
  my (undef, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'missing-command');
  like $error, qr/overnet-burner-worker-not-on-path-xyzzy.*was\ not\ found/mxs,
    'an unresolvable worker command fails before launch';
  like $error, qr/OVERNET_BURNER_WORKER/mx, 'the failure points at the environment override';

  my $runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'command-edges.yml')),
    run_id        => 'command-edges',
  );
  $runner->prepare;
  $runner->{worker_command} = q{''};
  ok $runner->_verify_worker_command_resolves([{id => 'publisher-001'}]),
    'a command without a program name is not pre-flighted';
  $runner->_destroy_constructed_guests;

  is(Overnet::Burner::Runner::RexLocalWorkers::_command_program(q{'/opt/my tool/worker' --flag}),
    '/opt/my tool/worker', 'a single-quoted program is unquoted');
  is(Overnet::Burner::Runner::RexLocalWorkers::_command_program(q{'it'\''s here' run}),
    q{it's here}, 'escaped single quotes are unwrapped');
  is(Overnet::Burner::Runner::RexLocalWorkers::_command_program(q{"my \"tool\"" run}),
    q{my "tool"}, 'a double-quoted program is unquoted');
  is(Overnet::Burner::Runner::RexLocalWorkers::_command_program('plain-worker --flag'),
    'plain-worker', 'a bare program is the first word');
  is(Overnet::Burner::Runner::RexLocalWorkers::_command_program(undef), undef, 'no command has no program');
  is(Overnet::Burner::Runner::RexLocalWorkers::_shell_quote(q{it's}), q{'it'\''s'}, 'shell quoting escapes quotes');
  is(Overnet::Burner::Runner::RexLocalWorkers::_shell_quote(undef), q{''}, 'undef quotes to an empty string');

  is $runner->_default_worker_command(undef), 'overnet-burner worker',
    'without a local guest the default worker command is the installed CLI';
  is(Overnet::Burner::Runner::RexLocalWorkers::_assigned_relays(['ws://a', 'ws://b'], 2),
    ['ws://b', 'ws://a'], 'relay assignment rotates by ordinal');
  is $runner->_total_duration_seconds, 2, 'the total duration comes from the plan run';
  local $runner->{plan} = {run => {duration_seconds => 7}};
  is $runner->_total_duration_seconds, 7, 'the duration falls back to the plain run duration';
  is [$runner->_worker_actors], [], 'a plan without actor roles has no workers';
  is $runner->_relay_endpoints,     [], 'a plan without relays declares no endpoints';
  is $runner->_resolve_chaos_hooks, [], 'a plan without chaos hooks resolves none';
  ok $runner->_await_worker_exits(undef), 'waiting for exits with nothing launched returns at once';
  ok $runner->collect, 'collect without declared metric streams still records its event';
};

subtest 'lifecycle chaos hooks drive the topology provider' => sub {
  my $provider_log  = File::Spec->catfile($tmp, 'chaos-provider.log');
  my $scenario_path = File::Spec->catfile($tmp, 'chaos.yml');
  _write_yaml($scenario_path, <<"YAML");
run:
  name: workers-chaos
  duration: 2
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
  - at: 0
    action: stop
    target: relay:1
  - at: 0
    action: start
    target: relay:1
  - at: 1
    action: restart
    target: relay:1
YAML

  my ($runner, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'chaos-lifecycle');
  is $error, undef, 'the chaos run completes' or diag($error);

  my %fields = $runner->summary_fields;
  is [map {"$_->{hook_id}:$_->{status}"} @{$fields{chaos_results}}],
    ['chaos-001:completed', 'chaos-002:completed', 'chaos-003:completed'],
    'every lifecycle hook completed in order';
  my @provider_ops = grep {length} split /\n/, _slurp($provider_log);
  is \@provider_ops,
    [qw(start health stop start health stop start health stop)],
    'stop, start, and restart hooks each ran their lifecycle steps';
};

subtest 'failing and unresolvable chaos hooks fail the run' => sub {
  my $counter       = File::Spec->catfile($tmp, 'chaos-start-count');
  my $scenario_path = File::Spec->catfile($tmp, 'chaos-fail.yml');
  _write_yaml($scenario_path, <<"YAML");
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

  my ($runner, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'chaos-fail');
  like $error, qr/chaos\ hook\ chaos-001\ [(]start\ relay:1[)]\ failed/mx, 'a failing hook names itself';
  my %fields = $runner->summary_fields;
  is $fields{chaos_results}[0]{status}, 'failed', 'the failed hook is recorded';
  like $fields{chaos_results}[0]{error}, qr/provider\ command\ failed/mx, 'the hook error names the provider failure';

  my $plain = _write_workers_scenario(File::Spec->catfile($tmp, 'chaos-targets.yml'));
  my (undef, $relay_error) = _run_lifecycle(
    scenario_path => $plain,
    run_id        => 'chaos-bad-relay',
    plan_mutator  => sub {
      my ($plan) = @_;
      $plan->{chaos_hooks} = [{id => 'chaos-001', action => 'restart', target => 'relay:9', at_seconds => 0, ordinal => 1}];
    },
  );
  like $relay_error, qr/chaos\ hook\ chaos-001\ targets\ relay:9/mx,
    'a lifecycle hook without provider commands is rejected';

  my (undef, $net_error) = _run_lifecycle(
    scenario_path => $plain,
    run_id        => 'chaos-bad-net',
    plan_mutator  => sub {
      my ($plan) = @_;
      $plan->{chaos_hooks} =
        [{id => 'chaos-001', action => 'net-delay', target => 'worker-guest:9', at_seconds => 0, ordinal => 1, delay_ms => 10}];
    },
  );
  like $net_error, qr/not\ a\ container\ guest\ on\ a\ per-run\ network/mx,
    'a network hook without a container guest is rejected';
};

subtest 'container guests run network chaos through the engine' => sub {
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = File::Spec->catfile($tmp, 'engine-argv.log');
  local $ENV{OVERNET_BURNER_DOCKER}          = _write_emulating_engine($tmp);
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

  my $scenario_path = File::Spec->catfile($tmp, 'net-chaos.yml');
  _write_yaml($scenario_path, <<"YAML");
run:
  name: workers-net-chaos
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://relay.example:7447
  publishers:
    count: 2
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: container
    image: example.test/worker:fake
    count: 2
    network: bridge
    worker: "$^X $fake_worker"
  relays:
    how: container
    image: example.test/relay:fake
    count: 1
chaos:
  - at: 0
    action: heal
    target: worker-guest:2
  - at: 0
    action: net-delay
    target: worker-guest:1
    delay_ms: 100
    jitter_ms: 20
  - at: 0
    action: heal
    target: worker-guest:1
  - at: 0
    action: partition
    target: worker-guest:1
  - at: 0
    action: heal
    target: worker-guest:1
  - at: 0
    action: net-loss
    target: worker-guest:2
    loss_percent: 5
  - at: 0
    action: net-delay
    target: worker-guest:2
    delay_ms: 50
YAML

  my ($runner, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'net-chaos');
  is $error, undef, 'the container chaos run completes' or diag($error);

  my %fields   = $runner->summary_fields;
  my @statuses = map {"$_->{action}:$_->{status}"} @{$fields{chaos_results}};
  is \@statuses,
    [
    'heal:completed',      'net-delay:completed', 'heal:completed', 'partition:completed',
    'heal:completed',      'net-loss:completed',  'net-delay:completed',
    ],
    'every network hook completed';
  ok length $fields{chaos_results}[1]{evidence}, 'network hooks record post-action evidence';

  my $guests = _read_json(File::Spec->catfile($runner->{run_dir}, 'guests.json'));
  is [map { $_->{transport} } @{$guests->{guests}}], ['container', 'container'], 'workers ran on container guests';
  is $guests->{guests}[0]{cap_add}, ['NET_ADMIN'], 'netem chaos grants NET_ADMIN to the worker containers';
  ok $guests->{network}{name}, 'a per-run bridge network is recorded';
  my $relay_guests = _read_json(File::Spec->catfile($runner->{run_dir}, 'relay-guests.json'));
  is $relay_guests->{network}{name}, $guests->{network}{name},
    'the relay containers reuse the per-run network';

  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'docker');
  my $noisy_guest = Overnet::Burner::Guest::Container->new(
    name      => 'noisy-guest',
    role      => 'workers',
    engine    => $engine,
    container => 'noisy-container',
    image     => 'example.test/worker:fake',
  );
  my $ran = eval { $runner->_exec_net_command($noisy_guest, 'echo boom; exit 7'); 1 };
  my $noisy_error = $@;
  ok !$ran, 'a failing network command fails';
  like $noisy_error, qr/noisy-guest\ could\ not\ run:.*boom/mxs, 'the failure carries the command output';

  local $ENV{OVERNET_BURNER_TEST_NET_FAIL} = 1;
  my (undef, $net_fail_error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'net-chaos-fail');
  like $net_fail_error, qr/chaos\ hook\ chaos-002\ [(]net-delay\ worker-guest:1[)]\ failed/mx,
    'a network action the guest cannot run fails its hook';
};

subtest 'container relays and managed images provision through the engine' => sub {
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = File::Spec->catfile($tmp, 'relay-engine-argv.log');
  local $ENV{OVERNET_BURNER_DOCKER}          = _write_emulating_engine($tmp);
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

  my $scenario_path = File::Spec->catfile($tmp, 'container-relays.yml');
  _write_yaml($scenario_path, <<"YAML");
run:
  name: workers-container-relays
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "exit 0"
      health: "exit 0"
      stop: "exit 0"
    endpoints:
      - ws://relay-001:7447
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: container
    image: example.test/worker:fake
    count: 1
    worker: "$^X $fake_worker"
  relays:
    how: container
    image: example.test/relay:fake
    count: 1
YAML

  my ($runner, $error) = _run_lifecycle(scenario_path => $scenario_path, run_id => 'container-relays');
  is $error, undef, 'the container relay run completes' or diag($error);

  my $relay_guests = _read_json(File::Spec->catfile($runner->{run_dir}, 'relay-guests.json'));
  is $relay_guests->{guests}[0]{transport}, 'container',   'relays ran on container guests';
  is $relay_guests->{guests}[0]{alias},     'relay-001',   'relay containers get their actor alias';
  is $relay_guests->{placement}{'relay-001'}, 'relay-guest-001', 'relay actors are placed on relay guests';

  my $relay_guest = $runner->_relay_guest_for('relay-001');
  is $relay_guest->name, 'relay-guest-001', 'provider commands target the relay container guest';
  is $runner->_relay_guest_for('relay-999')->name, 'local', 'unknown relays fall back to the controller host';
};

subtest 'connect provisioning records operator guests without constructing them' => sub {
  my $scenario_path = File::Spec->catfile($tmp, 'connect.yml');
  _write_yaml($scenario_path, <<'YAML');
run:
  name: workers-connect
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: connect
    hardware:
      memory: 256MB
    guests:
      - address: 127.0.0.1
        user: burner
        port: 9
        key: /nonexistent/id_ed25519
  relays:
    how: connect
    guests:
      - address: 127.0.0.1
        user: burner
        port: 9
YAML

  my $runner = _make_runner(scenario_path => $scenario_path, run_id => 'connect-prepare');
  ok $runner->prepare, 'prepare records connect guests';

  my $guests = _read_json(File::Spec->catfile($runner->{run_dir}, 'guests.json'));
  is $guests->{guests}[0],
    {
    name      => 'worker-guest-001',
    role      => 'workers',
    transport => 'ssh',
    address   => '127.0.0.1',
    user      => 'burner',
    port      => 9,
    key       => '/nonexistent/id_ed25519',
    },
    'the worker guest record carries the operator credentials';
  my $relay_guests = _read_json(File::Spec->catfile($runner->{run_dir}, 'relay-guests.json'));
  is $relay_guests->{guests}[0]{name}, 'relay-guest-001', 'relay connect guests are recorded';

  my $clocks = _read_json(File::Spec->catfile($runner->{run_dir}, 'clocks.json'));
  is [map { $_->{offset_ms} } @{$clocks->{guests}}], [undef, undef],
    'unreachable remote clocks are recorded as unverified';

  ok $runner->_destroy_constructed_guests, 'destroying operator guests is a no-op';

  is [$runner->_connect_guests({}, 'relays')], [], 'a connect spec without guests yields none';
  my ($bare_guest) = $runner->_connect_guests({guests => [{address => 'relay.example'}]}, 'relays');
  is $bare_guest->name, 'relay-guest-001', 'a bare connect guest is still named';
  ok !defined $bare_guest->user, 'a bare connect guest has no user';

  _write_yaml(
    File::Spec->catfile($runner->{run_dir}, 'config.normalized.json'),
    JSON->new->canonical(1)->encode({provision => {relays => {how => 'exotic'}}}),
  );
  ok $runner->_provision_relay_guests, 'an unknown relay provisioning method constructs no guests';
};

subtest 'remote clocks are measured when the guest answers' => sub {
  my $runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'clock-probe.yml')),
    run_id        => 'clock-probe',
  );
  my $nanoseconds = int(1e6 * (1000 * Time::HiRes::time()));
  $runner->{worker_guests} = [
    Overnet::Burner::Test::ScriptedGuest->new(name => 'probe-guest', clock_stdout => "$nanoseconds\n"),
  ];
  $runner->_capture_guest_clocks;

  my $clocks = _read_json(File::Spec->catfile($runner->{run_dir}, 'clocks.json'));
  ok defined $clocks->{guests}[0]{offset_ms},     'an answering remote guest gets a measured offset';
  ok defined $clocks->{guests}[0]{round_trip_ms}, 'the probe round trip is recorded';
};

subtest 'virtual provisioning drives the faked toolchain' => sub {
  my $image = File::Spec->catfile($tmp, 'guest-image.qcow2');
  _write_yaml($image, "fake image\n");
  my $scenario_path = File::Spec->catfile($tmp, 'virtual.yml');
  _write_yaml($scenario_path, <<"YAML");
run:
  name: workers-virtual
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://relay.example:7447
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: virtual
    image: $image
    count: 1
YAML

  local $ENV{OVERNET_BURNER_SSH_KEYGEN}           = _write_fake_keygen($tmp);
  local $ENV{OVERNET_BURNER_GENISOIMAGE}          = _write_fake_genisoimage($tmp);
  local $ENV{OVERNET_BURNER_QEMU}                 = _write_fake_qemu($tmp);
  local $ENV{OVERNET_BURNER_QEMU_ACCEL}           = 'tcg';
  local $ENV{OVERNET_BURNER_VIRTUAL_BOOT_TIMEOUT} = 1;

  my $runner   = _make_runner(scenario_path => $scenario_path, run_id => 'virtual-boot');
  my $prepared = eval { $runner->prepare; 1 };
  my $error    = $@;
  ok !$prepared, 'an unreachable virtual guest fails provisioning';

  # Whether the reachability probe times out or the controller has no ssh
  # client at all, the failure must name the guest that never came up.
  like $error, qr/worker-guest-001/mx, 'the provisioning failure names the guest';

  my $guest_dir = File::Spec->catdir($runner->{run_dir}, 'virtual', 'worker-guest-001');
  like _slurp(File::Spec->catfile($guest_dir, 'user-data')), qr/ssh_authorized_keys/mx,
    'the cloud-init user data authorizes the generated key';
  like _slurp(File::Spec->catfile($guest_dir, 'meta-data')), qr/local-hostname:\ worker-guest-001/mx,
    'the cloud-init meta data names the guest';
  ok $runner->_destroy_constructed_guests, 'an unbooted virtual guest destroys quietly';

  $runner->{worker_guests} = [Overnet::Burner::Test::ScriptedGuest->new(reachable_now => 1)];
  ok $runner->_await_guests_reachable, 'reachable guests pass the boot wait';

  $runner->{worker_guests} = [Overnet::Burner::Test::ScriptedGuest->new(name => 'stuck-guest')];
  my $waited = eval { $runner->_await_guests_reachable; 1 };
  ok !$waited, 'a guest that never answers times out';
  like $@, qr/stuck-guest\ did\ not\ become\ reachable\ within\ 1s/mx, 'the boot timeout names the stuck guest';

  my $missing_runner = _make_runner(scenario_path => $scenario_path, run_id => 'virtual-missing-image');
  unlink $image or die "unlink $image: $!";
  my $missing = eval { $missing_runner->prepare; 1 };
  like $@, qr/does\ not\ exist\ or\ is\ unreadable/mx, 'a missing image is rejected before any tooling runs';
  ok !$missing, 'provisioning fails without the image';
  _write_yaml($image, "fake image\n");

  for my $case (
    ['OVERNET_BURNER_SSH_KEYGEN',  qr/could\ not\ generate\ a\ guest\ ssh\ key/mx,   'keygen'],
    ['OVERNET_BURNER_GENISOIMAGE', qr/could\ not\ build\ the\ cloud-init\ seed/mx,   'genisoimage'],
    ['OVERNET_BURNER_QEMU',        qr/could\ not\ launch\ burner-.*worker-guest/mx,  'qemu'],
  ) {
    my ($env, $pattern, $label) = @{$case};
    local $ENV{$env} = '/bin/false';
    my $failing = _make_runner(scenario_path => $scenario_path, run_id => "virtual-$label-fail");
    my $ok      = eval { $failing->prepare; 1 };
    ok !$ok, "a failing $label fails provisioning";
    like $@, $pattern, "the $label failure is reported";

    if ($label eq 'qemu') {
      # The launch can leave a partially-started qemu behind, so the guest must
      # already be registered when the launch fails or failure cleanup cannot
      # destroy it.
      ok scalar @{$failing->{worker_guests}} >= 1,
        'a virtual guest is registered before its launch, so a failed launch is still reapable';
    }
  }

  my $raw_image = File::Spec->catfile($tmp, 'guest-image.img');
  _write_yaml($raw_image, "raw fake image\n");
  my $raw_scenario = File::Spec->catfile($tmp, 'virtual-raw.yml');
  _write_yaml($raw_scenario, <<"YAML");
run:
  name: workers-virtual-raw
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://relay.example:7447
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: virtual
    image: $raw_image
    count: 1
YAML
  local $ENV{OVERNET_BURNER_QEMU}       = '/bin/false';
  local $ENV{OVERNET_BURNER_QEMU_ACCEL} = 'kvm';
  my $raw_runner = _make_runner(scenario_path => $raw_scenario, run_id => 'virtual-raw-kvm');
  my $raw_ok     = eval { $raw_runner->prepare; 1 };
  ok !$raw_ok, 'a raw image with kvm acceleration still reaches the launcher';
  like $@, qr/could\ not\ launch/mx, 'the raw kvm launch failure is reported';

  my $vm_guest = Overnet::Burner::Guest::Virtual->new(
    name      => 'worker-guest-001',
    role      => 'workers',
    address   => '127.0.0.1',
    port      => 2222,
    user      => 'burner',
    key       => '/keys/id_ed25519',
    pid_file  => File::Spec->catfile($tmp, 'missing.pid'),
    image     => $image,
    memory_mb => 512,
    cpus      => 2,
    accel     => 'tcg',
  );
  my $record = Overnet::Burner::Runner::RexLocalWorkers::_guest_record($vm_guest);
  is $record->{method},    'virtual', 'a virtual guest records its provisioning method';
  is $record->{memory_mb}, 512,       'a virtual guest records its memory allowance';
  is $record->{accel},     'tcg',     'a virtual guest records its acceleration';
  is $record->{address},   '127.0.0.1', 'a virtual guest is also an ssh guest';
};

subtest 'cleanup and collect survive failed worker log pulls' => sub {
  my $runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'log-pull.yml')),
    run_id        => 'log-pull',
  );
  $runner->prepare;
  $runner->{worker_log_files}{'phantom-001'} = ['/never/pulled.stdout'];
  $runner->{actor_guests}{'phantom-001'}     = Overnet::Burner::Test::ScriptedGuest->new(name => 'dying-guest');

  ok $runner->cleanup_after_lifecycle_failure(failed_phase => 'observe'),
    'cleanup succeeds even when worker logs cannot be pulled';
  ok $runner->collect, 'collect succeeds even when worker logs cannot be pulled';

  my @events = @{_read_jsonl(File::Spec->catfile($runner->{run_dir}, 'logs', 'runner.jsonl'))};
  my @pull_failures = grep { ($_->{status} || q{}) eq 'worker_log_pull_failed' } @events;
  is [map { $_->{phase} } @pull_failures], ['cleanup', 'collect'],
    'both phases record the failed log pull';

  $runner->{worker_log_files} = {'quiet-001' => ['/never/written.stdout']};
  $runner->{actor_guests}{'quiet-001'} =
    Overnet::Burner::Test::ScriptedGuest->new(name => 'quiet-guest', read_dies => 0);
  ok $runner->_pull_worker_logs, 'a remote log that was never written is skipped';

  my $fresh_runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'fresh-defaults.yml')),
    run_id        => 'fresh-defaults',
  );
  ok $fresh_runner->_pull_worker_logs, 'pulling logs before any launch is a no-op';
  ok $fresh_runner->_destroy_constructed_guests, 'destroying before provisioning is a no-op';
  ok $fresh_runner->_capture_guest_clocks, 'capturing clocks before provisioning records no guests';
  is _read_json(File::Spec->catfile($fresh_runner->{run_dir}, 'clocks.json'))->{guests}, [],
    'the clock ledger is empty before provisioning';

  my $cleanup_scenario = File::Spec->catfile($tmp, 'cleanup-fail.yml');
  _write_yaml($cleanup_scenario, <<'YAML');
run:
  name: workers-cleanup-fail
  duration: 1
  seed: 12345
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "exit 0"
      health: "exit 0"
      stop: "exit 43"
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
YAML
  my $failing_cleanup = _make_runner(scenario_path => $cleanup_scenario, run_id => 'cleanup-fail');
  $failing_cleanup->prepare;
  $failing_cleanup->{topology_provider_started}{'relay-001'} = 1;
  $failing_cleanup->{topology_provider_needs_stop} = 1;
  my $cleaned = eval { $failing_cleanup->cleanup_after_lifecycle_failure(failed_phase => 'observe'); 1 };
  ok !$cleaned, 'a failing provider stop still fails cleanup';
  like $@, qr/provider\ command/mx, 'the provider stop failure propagates after guest teardown';
};

subtest 'failure and signal cleanup terminate and reap still-running workers' => sub {
  # A worker launched before the run failed (or was interrupted) is tracked in
  # worker_pids. Both the lifecycle-failure and signal teardown paths must send
  # it TERM and reap it, otherwise local worker processes are orphaned and keep
  # generating load into the next run.
  my $runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'leak-cleanup.yml')),
    run_id        => 'leak-cleanup',
  );
  $runner->prepare;
  my $guest = Overnet::Burner::Test::ReapingGuest->new;
  $runner->{actor_guests}{'publisher-001'} = $guest;
  $runner->{worker_pids}{'publisher-001'}  = 4242;

  ok $runner->cleanup_after_lifecycle_failure(failed_phase => 'observe'),
    'lifecycle-failure cleanup succeeds';
  is $runner->{worker_pids}, {},
    'a still-running worker is reaped, not left tracked, on failure cleanup';
  is $guest->signals, ['4242:TERM'],
    'the running worker is sent TERM during failure cleanup';

  my $sig_runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'leak-signal.yml')),
    run_id        => 'leak-signal',
  );
  $sig_runner->prepare;
  my $sig_guest = Overnet::Burner::Test::ReapingGuest->new;
  $sig_runner->{actor_guests}{'publisher-001'} = $sig_guest;
  $sig_runner->{worker_pids}{'publisher-001'}  = 7373;

  ok $sig_runner->teardown_on_signal, 'signal teardown succeeds';
  is $sig_runner->{worker_pids}, {},
    'a still-running worker is reaped on signal teardown';
  is $sig_guest->signals, ['7373:TERM'],
    'the running worker is sent TERM during signal teardown';

  # A guest whose signal fails must not stop the worker being reaped or the
  # cleanup from completing: teardown is best-effort per guest.
  my $fail_runner = _make_runner(
    scenario_path => _write_workers_scenario(File::Spec->catfile($tmp, 'leak-signal-fail.yml')),
    run_id        => 'leak-signal-fail',
  );
  $fail_runner->prepare;
  $fail_runner->{actor_guests}{'publisher-001'} = Overnet::Burner::Test::ReapingGuest->new(fail_signal => 1);
  $fail_runner->{worker_pids}{'publisher-001'}  = 5555;

  ok $fail_runner->cleanup_after_lifecycle_failure(failed_phase => 'observe'),
    'cleanup succeeds even when a guest signal fails';
  is $fail_runner->{worker_pids}, {},
    'the worker is still reaped when its signal fails';
};

done_testing;

sub _make_runner {
  my (%args) = @_;

  my $scenario = Overnet::Burner::Config->load_file($args{scenario_path});
  my $ledger   = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $args{scenario_path},
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => $args{run_id},
    host_facts    => {hostname => 'builder-host', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  my $plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});
  if ($args{plan_mutator}) {
    $args{plan_mutator}->($plan);
  }

  my $runner = Overnet::Burner::Runner->load(
    name    => 'rex-local-workers',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );

  return wantarray ? ($runner, $ledger) : $runner;
}

sub _run_lifecycle {
  my (%args) = @_;

  my ($runner, $ledger) = _make_runner(%args);
  my $completed = eval { $runner->run_lifecycle; 1 };
  my $error     = $completed ? undef : $@;

  return ($runner, $error, $ledger);
}

sub _write_workers_scenario {
  my ($path, %args) = @_;

  my $publishers  = $args{publishers}  // 1;
  my $subscribers = $args{subscribers} // 1;
  my $duration    = $args{duration}    // 2;
  my $endpoints   = exists $args{endpoints} ? $args{endpoints} : "    endpoints:\n      - ws://127.0.0.1:59999\n";
  my $readers     = $subscribers ? <<'READERS' : q{};
  query_readers:
    count: 1
  object_readers:
    count: 1
  observers:
    count: 1
READERS

  _write_yaml($path, <<"YAML");
run:
  name: workers-unit
  duration: $duration
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
$endpoints
  publishers:
    count: $publishers
  subscribers:
    count: $subscribers
$readers
workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
  query_filters:
    - kinds: [7800]
  object_reads:
    objects:
      - type: chat.channel
        id: irc:local:#overnet
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

my $mode = $ENV{OVERNET_BURNER_TEST_WORKER_MODE} || '';
die "fake worker failing on request\n" if $mode eq 'fail';

if ($mode ne 'no-ready') {
    open my $ready, '>', "$input->{run_dir}/$input->{ready_file}" or die "ready: $!";
    close $ready or die "close ready: $!";
}
if ($mode eq 'no-ready' || $mode eq 'hang-ignore-term') {
    $SIG{TERM} = 'IGNORE' if $mode eq 'hang-ignore-term';
    sleep 1 for 1 .. 120;
    exit 0;
}

my %metric = (
    metric_version => 1,
    run_id         => $input->{run_id},
    worker_id      => $input->{worker_id},
    host           => 'fake-host',
    role           => $input->{role},
    operation      => 'noop_probe',
    started_at     => '2026-07-13T12:00:00Z',
    finished_at    => '2026-07-13T12:00:00.001Z',
    duration_ms    => 1,
    status         => 'success',
);
open my $stream, '>>', "$input->{run_dir}/$input->{metric_stream}" or die "stream: $!";
print {$stream} JSON::PP->new->canonical(1)->encode(\%metric), "\n" or die "print: $!";
close $stream or die "close stream: $!";
exit 3 if $mode eq 'exit-dirty';
exit 0;
PERL
  chmod 0755, $path or die "chmod $path: $!";
  return $path;
}

sub _write_emulating_engine {
  my ($dir) = @_;

  my $path = File::Spec->catfile($dir, 'emulating-engine');
  _write_yaml($path, <<'PERL');
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
  exit 1 if $ENV{OVERNET_BURNER_TEST_RUN_FAIL};
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
  chmod 0755, $path or die "chmod $path: $!";
  return $path;
}

sub _write_fake_keygen {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-keygen');
  _write_yaml($path, <<'PERL');
#!/usr/bin/env perl
use strictures 2;
my $key = $ARGV[-1];
open my $fh, '>', $key or die "open $key: $!";
print {$fh} "fake private key\n" or die "print: $!";
close $fh or die "close: $!";
open my $pub, '>', "$key.pub" or die "open $key.pub: $!";
print {$pub} "ssh-ed25519 AAAAFAKE burner\n" or die "print: $!";
close $pub or die "close: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod $path: $!";
  return $path;
}

sub _write_fake_genisoimage {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-genisoimage');
  _write_yaml($path, <<'PERL');
#!/usr/bin/env perl
use strictures 2;
my $output;
for my $index (0 .. $#ARGV - 1) {
    $output = $ARGV[$index + 1] if $ARGV[$index] eq '-output';
}
die "no -output argument\n" if !defined $output;
open my $fh, '>', $output or die "open $output: $!";
print {$fh} "fake iso\n" or die "print: $!";
close $fh or die "close: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod $path: $!";
  return $path;
}

sub _write_fake_qemu {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-qemu');
  _write_yaml($path, "#!/bin/sh\nexit 0\n");
  chmod 0755, $path or die "chmod $path: $!";
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

sub _write_yaml {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
