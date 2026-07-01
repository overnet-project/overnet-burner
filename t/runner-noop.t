use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Runner;
use Overnet::Burner::RunLedger;

my $repo          = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario      = Overnet::Burner::Config->load_file($scenario_path);
my $tmp           = tempdir(CLEANUP => 1);
my @times         = (
  '2026-06-27T14:00:00Z', '2026-06-27T14:00:01Z', '2026-06-27T14:00:02Z', '2026-06-27T14:00:03Z',
  '2026-06-27T14:00:04Z', '2026-06-27T14:00:05Z', '2026-06-27T14:00:06Z', '2026-06-27T14:00:07Z',
  '2026-06-27T14:00:08Z', '2026-06-27T14:00:09Z', '2026-06-27T14:00:10Z',
);

my $ledger = Overnet::Burner::RunLedger->create(
  scenario      => $scenario,
  scenario_path => $scenario_path,
  runs_dir      => "$tmp/runs",
  run_id        => 'noop-runner-001',
  now           => sub { shift @times },
  host_facts    => {
    hostname => 'builder-host',
    os       => 'linux',
    arch     => 'x86_64',
  },
  repo_sha    => 'abc123',
  rex_version => undef,
);
my $plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});

my $runner = Overnet::Burner::Runner->load(
  name    => 'noop',
  ledger  => $ledger,
  plan    => $plan,
  run_dir => $ledger->{run_dir},
);

is $runner->name, 'noop', 'loads noop runner by name';

my $base_runner = Overnet::Burner::Runner->new(
  {
    name    => 'noop',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  }
);
isa_ok $base_runner, ['Overnet::Burner::Runner'], 'base runner hashref constructor';

my $summary = $runner->run_lifecycle;

is $summary->{runner}, 'noop', 'summary records runner name';
is $summary->{phases},
  {
  prepare => 'completed',
  start   => 'completed',
  observe => 'completed',
  stop    => 'completed',
  collect => 'completed',
  },
  'summary records completed lifecycle phases';
is $summary->{actor_counts},
  {
  relays         => 1,
  publishers     => 1,
  subscribers    => 1,
  query_readers  => 1,
  object_readers => 1,
  total          => 5,
  },
  'summary records deterministic actor counts';

my $runner_log_path = File::Spec->catfile($ledger->{run_dir}, 'logs', 'runner.jsonl');
open my $log_fh, '<', $runner_log_path or die "open $runner_log_path: $!";
my @events = map { JSON::decode_json($_) } <$log_fh>;

is [map {"$_->{phase}:$_->{status}"} @events],
  [
  'prepare:started', 'prepare:completed', 'start:started', 'start:completed',
  'observe:started', 'observe:completed', 'stop:started',  'stop:completed',
  'collect:started', 'collect:completed',
  ],
  'runner log records lifecycle event order';

is $events[0]{runner},       'noop',                   'event records runner name';
is $events[0]{timestamp},    '2026-06-27T14:00:01Z',   'event timestamp comes from injected clock';
is $events[0]{actor_counts}, $summary->{actor_counts}, 'event records actor counts';

my $artifact_path = File::Spec->catfile($ledger->{run_dir}, 'artifacts', 'noop-runner.json',);
open my $artifact_fh, '<', $artifact_path or die "open $artifact_path: $!";
local $/ = undef;
my $artifact = JSON::decode_json(<$artifact_fh>);

is $artifact, $summary, 'noop runner writes deterministic summary artifact';

my $unknown = eval {
  Overnet::Burner::Runner->load(
    name    => 'missing',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );
  1;
};
ok !$unknown, 'rejects unknown runner';
like $@, qr/unknown\ runner:\ missing/mx, 'reports unknown runner name';

done_testing;
