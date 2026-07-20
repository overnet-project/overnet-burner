use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::Worker::SyncBridge;

# The sync bridge is an honest topology role that needs two relays: a scenario
# that places it must normalize, validate, plan into placed actors carrying the
# sync_bridge workload on every phase, and a real SyncBridge must read its pacing
# from that phase. A single-relay bridge is a validation error.

my $scenario = Overnet::Burner::Config->normalize(
  {
    run      => {name => 'bridge-wiring', duration => 30, seed => 7},
    topology => {
      relays       => {count => 2, provider => 'generic-relay', endpoints => ['ws://127.0.0.1:7777', 'ws://127.0.0.1:7778']},
      sync_bridges => {count => 1},
    },
    workload => {
      publish_rate_per_second => 1,
      sync_bridge => {interval_seconds => 0.5, timeout_seconds => 4, filters => [{kinds => [7800]}]},
    },
  },
);

ok lives { Overnet::Burner::Config->validate($scenario) }, 'a two-relay bridge scenario validates';

my $one_relay = Overnet::Burner::Config->normalize(
  {
    run      => {name => 'bridge-solo', duration => 30, seed => 7},
    topology => {relays => {count => 1, provider => 'generic-relay', endpoints => ['ws://127.0.0.1:7777']}, sync_bridges => {count => 1}},
    workload => {publish_rate_per_second => 1},
  },
);
like dies { Overnet::Burner::Config->validate($one_relay) }, qr/at least 2/,
  'a sync bridge without a second relay is a validation error';

my $plan = Overnet::Burner::Plan->build($scenario);

is [map { $_->{id} } @{$plan->{sync_bridges}}], ['sync-bridge-001'],
  'the plan expands the sync_bridge count into stable ids';
is $plan->{sync_bridges}[0]{role}, 'sync_bridge', 'a planned bridge carries the sync_bridge role';

my ($phase) = @{$plan->{workload}{phases}};
is $phase->{sync_bridge},
  {interval_seconds => 0.5, timeout_seconds => 4, filters => [{kinds => [7800]}]},
  'the sync_bridge workload rides on every planned phase';

my $worker = Overnet::Burner::Worker::SyncBridge->new(
  input => {
    input_version    => 1,
    run_id           => 'run-bridge-wiring',
    run_dir          => '/tmp/bridge-wiring',
    worker_id        => 'sync-bridge-001',
    role             => 'sync_bridge',
    seed             => 7,
    duration_seconds => 30,
    metric_stream    => 'metrics/sync-bridge-001.jsonl',
    ready_file       => 'workers/sync-bridge-001/ready',
    endpoints        => {relays => ['ws://127.0.0.1:7777', 'ws://127.0.0.1:7778']},
    phases           => $plan->{workload}{phases},
  },
);
is $worker->_sync_interval, 0.5, 'the bridge reads its interval from the planned phase';
is $worker->_sync_timeout,  4,   'the bridge reads its timeout from the planned phase';
is $worker->_sync_filter, {kinds => [7800]}, 'the bridge reads its filter from the planned phase';

# The shipped example scenario is a real, plannable sync-pair run.
my $example = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/sync-pair.yml");
my $example_plan = Overnet::Burner::Plan->build($example);
is [map { $_->{id} } @{$example_plan->{sync_bridges}}], ['sync-bridge-001'],
  'the sync-pair example scenario plans a bridge';

done_testing;
