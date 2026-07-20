use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::Worker::Syncer;

# The syncer is an honest topology role: a scenario that places syncers must
# normalize, validate, plan into placed actors, and carry the syncer workload
# on every phase, and a real Syncer must read its pacing from that phase.

my $scenario = Overnet::Burner::Config->normalize(
  {
    run      => {name => 'sync-wiring', duration => 30, seed => 7},
    topology => {
      relays  => {count => 1, provider => 'generic-relay', endpoints => ['ws://127.0.0.1:7777']},
      syncers => {count => 2},
    },
    workload => {
      publish_rate_per_second => 1,
      syncer => {interval_seconds => 0.5, timeout_seconds => 4, filters => [{kinds => [7800]}]},
    },
  },
);

ok lives { Overnet::Burner::Config->validate($scenario) }, 'a scenario that places syncers validates';

my $plan = Overnet::Burner::Plan->build($scenario);

is [map { $_->{id} } @{$plan->{syncers}}], ['syncer-001', 'syncer-002'],
  'the plan expands the syncer count into stable ids';
is $plan->{syncers}[0]{role}, 'syncer', 'a planned syncer carries the syncer role';
is $plan->{syncers}[0]{metric_stream}, 'metrics/syncer-001.jsonl',
  'a planned syncer records its metric stream path';

my ($phase) = @{$plan->{workload}{phases}};
is $phase->{syncer},
  {interval_seconds => 0.5, timeout_seconds => 4, filters => [{kinds => [7800]}]},
  'the syncer workload rides on every planned phase';

# The planned phase is exactly what the worker input carries, so a real Syncer
# built from it derives its pacing from the scenario, not from the defaults.
my $worker = Overnet::Burner::Worker::Syncer->new(
  input => {
    input_version    => 1,
    run_id           => 'run-sync-wiring',
    run_dir          => '/tmp/sync-wiring',
    worker_id        => 'syncer-001',
    role             => 'syncer',
    seed             => 7,
    duration_seconds => 30,
    metric_stream    => 'metrics/syncer-001.jsonl',
    ready_file       => 'workers/syncer-001/ready',
    endpoints        => {relays => ['ws://127.0.0.1:7777']},
    phases           => $plan->{workload}{phases},
  },
);
is $worker->_sync_interval, 0.5, 'the syncer reads its interval from the planned phase';
is $worker->_sync_timeout,  4,   'the syncer reads its timeout from the planned phase';
is $worker->_sync_filter, {kinds => [7800]}, 'the syncer reads its filter from the planned phase';

# The shipped example scenario is a real, plannable syncer run.
my $example = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/sync-single-relay.yml");
my $example_plan = Overnet::Burner::Plan->build($example);
is [map { $_->{id} } @{$example_plan->{syncers}}], ['syncer-001'],
  'the sync-single-relay example scenario plans a syncer';

done_testing;
