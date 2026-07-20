use strictures 2;

use File::Find qw(find);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::RexBundle;
use Overnet::Burner::RunLedger;

my $repo          = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario      = Overnet::Burner::Config->load_file($scenario_path);
my $tmp           = tempdir(CLEANUP => 1);

my $ledger_a = _ledger("$tmp/a", 'rex-render-a');
my $ledger_b = _ledger("$tmp/b", 'rex-render-b');
my $plan_a   = Overnet::Burner::RunLedger->load_plan($ledger_a->{run_dir});
my $plan_b   = Overnet::Burner::RunLedger->load_plan($ledger_b->{run_dir});

my $plan_topology_provider = $plan_a->{topology_provider} || {};
is $plan_topology_provider->{name}, 'generic-relay', 'source plan records topology provider';
ok !exists $plan_a->{provider}, 'source plan does not use ambiguous provider field';

my $bundle_a = Overnet::Burner::RexBundle->render(
  run_dir => $ledger_a->{run_dir},
  plan    => $plan_a,
);
my $bundle_b = Overnet::Burner::RexBundle->render(
  run_dir => $ledger_b->{run_dir},
  plan    => $plan_b,
);

is $bundle_a->{relative_dir}, 'artifacts/rex', 'renderer reports run-local Rex bundle path';
is $bundle_a->{files},
  [
  'Rexfile',                       'actor-hosts.json',
  'actors/object-reader-001.json', 'actors/publisher-001.json',
  'actors/query-reader-001.json',  'actors/relay-001.json',
  'actors/subscriber-001.json',    'artifact-collection.json',
  'bundle.json',                   'chaos-hooks.json',
  'inventory/hosts.json',          'lifecycle.json',
  'topology-provider.json',
  ],
  'renderer reports stable bundle file list';

my $bundle_dir = File::Spec->catdir($ledger_a->{run_dir}, 'artifacts', 'rex');
for my $path (@{$bundle_a->{files}}) {
  ok -e File::Spec->catfile($bundle_dir, $path), "writes $path";
}

my $index = _read_json(File::Spec->catfile($bundle_dir, 'bundle.json'));
is $index,
  {
  bundle => {
    name    => 'overnet-burner-rex',
    version => 1,
  },
  execution => {
    remote_execution => 'not_performed',
  },
  files       => $bundle_a->{files},
  source_plan => {
    path         => 'plan.json',
    plan_version => 1,
    scenario     => 'single-relay-baseline',
  },
  },
  'bundle index records source plan and render-only execution state';

my $hosts = _read_json(File::Spec->catfile($bundle_dir, 'inventory', 'hosts.json'));
is $hosts,
  {
  groups => {
    all            => ['host-001'],
    object_readers => ['host-001'],
    observers      => [],
    publishers     => ['host-001'],
    query_readers  => ['host-001'],
    relays         => ['host-001'],
    subscribers    => ['host-001'],
    sync_bridges   => [],
    syncers        => [],
  },
  hosts => [
    {
      id       => 'host-001',
      hostname => 'localhost',
    },
  ],
  },
  'inventory contains deterministic host groups';

my $assignments = _read_json(File::Spec->catfile($bundle_dir, 'actor-hosts.json'));
is [map { $_->{actor_id} } @{$assignments->{assignments}}], [
  qw(
    relay-001
    publisher-001
    subscriber-001
    query-reader-001
    object-reader-001
  )
  ],
  'assignments preserve plan actor order';
is [map { $_->{host_id} } @{$assignments->{assignments}}],
  [('host-001') x 5],
  'assignments target the stable logical host';

my $relay_config = _read_json(File::Spec->catfile($bundle_dir, 'actors', 'relay-001.json'));
is $relay_config->{actor}{id},                'relay-001',     'per-actor config records actor id';
is $relay_config->{actor}{role},              'relay',         'per-actor config records actor role';
is $relay_config->{actor}{topology_provider}, 'generic-relay', 'per-actor config records topology provider';
ok !exists $relay_config->{actor}{provider}, 'per-actor config does not use ambiguous provider field';
is $relay_config->{host_id}, 'host-001', 'per-actor config records host';
ok !exists $relay_config->{metric_stream}, 'relay actor config declares no metric stream';
is $relay_config->{env}{OVERNET_BURNER_ACTOR_ID}, 'relay-001', 'per-actor config includes actor env';
is $relay_config->{env}{OVERNET_BURNER_ROLE},     'relay',     'per-actor config includes role env';
is $relay_config->{env}{OVERNET_BURNER_TOPOLOGY_PROVIDER}, 'generic-relay',
  'per-actor config keeps topology provider distinct from Rex';

my $lifecycle = _read_json(File::Spec->catfile($bundle_dir, 'lifecycle.json'));
is [map { $_->{phase} } @{$lifecycle->{commands}}],
  [qw(bootstrap deploy start warmup run chaos collect cleanup)],
  'lifecycle plan contains Rex orchestration phases';
is [map { $_->{execution} } @{$lifecycle->{commands}}], [('planned') x 8], 'lifecycle plan is render-only';

my $topology_provider = _read_json(File::Spec->catfile($bundle_dir, 'topology-provider.json'),);
is $topology_provider,
  {
  topology_provider => {
    name => 'generic-relay',
  },
  relays => [
    {
      actor_id => 'relay-001',
    },
  ],
  },
  'topology provider artifact keeps generic-relay descriptor simple';

my $chaos_hooks = _read_json(File::Spec->catfile($bundle_dir, 'chaos-hooks.json'));
is $chaos_hooks, {hooks => []}, 'chaos schedule is rendered';

my $collection = _read_json(File::Spec->catfile($bundle_dir, 'artifact-collection.json'));
is [map { $_->{actor_id} } @{$collection->{metric_streams}}], [
  qw(
    publisher-001
    subscriber-001
    query-reader-001
    object-reader-001
  )
  ],
  'artifact collection plan records worker metric streams';

my $rexfile = _read_file(File::Spec->catfile($bundle_dir, 'Rexfile'));
like $rexfile,   qr/^\#\ Generated\ by\ overnet-burner\ Rex\ bundle\ renderer\./mx, 'Rexfile is clearly generated';
like $rexfile,   qr/task\ 'bootstrap'/mx,                                           'Rexfile has bootstrap task stub';
like $rexfile,   qr/task\ 'cleanup'/mx,                                             'Rexfile has cleanup task stub';
like $rexfile,   qr/task\ 'bootstrap',\ sub\ \{/mx,          'Rexfile renders lifecycle tasks as local Rex tasks';
unlike $rexfile, qr/task\ 'bootstrap',\ group\ =>\ 'all'/mx, 'Rexfile lifecycle tasks do not force SSH to localhost';
unlike $rexfile, qr/--provider\ rex/mx,                      'Rexfile does not treat Rex as a provider';

is _bundle_files($ledger_a->{run_dir}), _bundle_files($ledger_b->{run_dir}),
  'rendered bundle files are deterministic across run directories';

my $chaos_scenario = JSON::decode_json(Overnet::Burner::Config->normalized_json($scenario));
$chaos_scenario->{chaos} = [
  {
    at     => 30,
    action => 'restart',
    target => 'relay-001',
  },
];
my $chaos_dir = "$tmp/chaos-run";
mkdir $chaos_dir or die "mkdir $chaos_dir: $!";
mkdir File::Spec->catdir($chaos_dir, 'artifacts')
  or die "mkdir $chaos_dir/artifacts: $!";
Overnet::Burner::RexBundle->render(
  run_dir => $chaos_dir,
  plan    => Overnet::Burner::Plan->build($chaos_scenario),
);
my $rendered_chaos = _read_json(File::Spec->catfile($chaos_dir, 'artifacts', 'rex', 'chaos-hooks.json'),);
is $rendered_chaos->{hooks}[0]{id},         'chaos-001', 'renders chaos hook id from plan';
is $rendered_chaos->{hooks}[0]{at_seconds}, 30,          'renders chaos hook schedule from plan';
is $rendered_chaos->{hooks}[0]{action},     'restart',   'renders chaos hook action from plan';

done_testing;

sub _ledger {
  my ($runs_dir, $run_id) = @_;

  return Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => $runs_dir,
    run_id        => $run_id,
    now           => sub {'2026-06-27T14:00:00Z'},
    host_facts    => {
      hostname => 'builder-host',
      os       => 'linux',
      arch     => 'x86_64',
    },
    repo_sha    => 'abc123',
    rex_version => undef,
  );
}

sub _bundle_files {
  my ($run_dir) = @_;

  my $bundle_dir = File::Spec->catdir($run_dir, 'artifacts', 'rex');
  my %files;
  find(
    sub {
      return unless -f $_;
      my $path     = $File::Find::name;
      my $relative = File::Spec->abs2rel($path, $bundle_dir);
      $files{$relative} = _read_file($path);
    },
    $bundle_dir,
  );

  return \%files;
}

sub _read_json {
  my ($path) = @_;

  return JSON::decode_json(_read_file($path));
}

sub _read_file {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  return <$fh>;
}
