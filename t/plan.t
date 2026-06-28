use strictures 2;

use FindBin;
use JSON ();
use Test::More;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;

my $repo = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario = Overnet::Burner::Config->load_file($scenario_path);

my $plan_a = Overnet::Burner::Plan->build($scenario);
my $plan_b = Overnet::Burner::Plan->build($scenario);

is_deeply $plan_a, $plan_b, 'plan is deterministic for the same scenario';

is $plan_a->{plan_version}, 1, 'plan records version';
is $plan_a->{scenario}{name}, 'single-relay-baseline',
    'plan records scenario name';
is $plan_a->{run}{name}, 'single-relay-baseline', 'plan records run name';
is $plan_a->{run}{duration_seconds}, 60, 'plan records run duration';
is $plan_a->{run}{seed}, 12345, 'plan records run seed';
my $plan_topology_provider = $plan_a->{topology_provider} || {};
is $plan_topology_provider->{name}, 'generic-relay',
    'plan records topology provider';
ok !exists $plan_a->{provider}, 'plan does not use ambiguous provider field';

is_deeply [map { $_->{id} } @{ $plan_a->{relays} }], ['relay-001'],
    'plan expands relay count into stable ids';
is $plan_a->{relays}[0]{topology_provider}, 'generic-relay',
    'relay actor records topology provider';
ok !exists $plan_a->{relays}[0]{provider},
    'relay actor does not use ambiguous provider field';
is_deeply [map { $_->{id} } @{ $plan_a->{publishers} }], ['publisher-001'],
    'plan expands publisher count into stable ids';
is_deeply [map { $_->{id} } @{ $plan_a->{subscribers} }], ['subscriber-001'],
    'plan expands subscriber count into stable ids';
is_deeply [map { $_->{id} } @{ $plan_a->{query_readers} }], ['query-reader-001'],
    'plan expands query reader count into stable ids';
is_deeply [map { $_->{id} } @{ $plan_a->{object_readers} }], ['object-reader-001'],
    'plan expands object reader count into stable ids';

for my $actor (
    @{ $plan_a->{relays} },
    @{ $plan_a->{publishers} },
    @{ $plan_a->{subscribers} },
    @{ $plan_a->{query_readers} },
    @{ $plan_a->{object_readers} },
) {
    ok $actor->{seed} =~ /\A\d+\z/, "$actor->{id} has deterministic actor seed";
    is $actor->{metric_stream}, "metrics/$actor->{id}.jsonl",
        "$actor->{id} records metric stream path";
}

is scalar @{ $plan_a->{workload}{phases} }, 1,
    'plan creates a default workload phase';
my $phase = $plan_a->{workload}{phases}[0];
is $phase->{id}, 'phase-001', 'phase has stable id';
is $phase->{name}, 'main', 'phase has stable name';
is $phase->{start_seconds}, 0, 'phase starts at zero';
is $phase->{duration_seconds}, 60, 'phase uses scenario duration';
is $phase->{publish_rate_per_second}, 10, 'phase records publish rate';
is_deeply $phase->{subscription_filters},
    $scenario->{workload}{subscription_filters},
    'phase records subscription filters';
is_deeply $phase->{query_filters}, $scenario->{workload}{query_filters},
    'phase records query filters';
is_deeply $phase->{object_reads}, $scenario->{workload}{object_reads},
    'phase records object read workload';

for my $actor_id (
    qw(
    relay-001
    publisher-001
    subscriber-001
    query-reader-001
    object-reader-001
    )
) {
    ok $phase->{actor_seeds}{$actor_id} =~ /\A\d+\z/,
        "phase has seed for $actor_id";
}

my %streams = map { $_->{actor_id} => $_ }
    grep { exists $_->{actor_id} } @{ $plan_a->{metric_streams} };
for my $actor_id (
    qw(
    relay-001
    publisher-001
    subscriber-001
    query-reader-001
    object-reader-001
    )
) {
    is $streams{$actor_id}{path}, "metrics/$actor_id.jsonl",
        "metric stream exists for $actor_id";
}

is_deeply $plan_a->{chaos_hooks}, [], 'plan includes empty chaos hook list';

my $changed_seed = JSON::decode_json(Overnet::Burner::Config->normalized_json($scenario));
$changed_seed->{run}{seed} = 98765;
my $changed_plan = Overnet::Burner::Plan->build($changed_seed);
isnt $changed_plan->{publishers}[0]{seed}, $plan_a->{publishers}[0]{seed},
    'actor seed changes when scenario seed changes';
isnt $changed_plan->{workload}{phases}[0]{actor_seeds}{'publisher-001'},
    $phase->{actor_seeds}{'publisher-001'},
    'phase actor seed changes when scenario seed changes';

my $multi = JSON::decode_json(Overnet::Burner::Config->normalized_json($scenario));
$multi->{topology}{relays}{count} = 2;
$multi->{topology}{publishers}{count} = 2;
my $multi_plan = Overnet::Burner::Plan->build($multi);
is_deeply [map { $_->{id} } @{ $multi_plan->{relays} }],
    [qw(relay-001 relay-002)],
    'plan expands multiple relays';
is_deeply [map { $_->{id} } @{ $multi_plan->{publishers} }],
    [qw(publisher-001 publisher-002)],
    'plan expands multiple publishers';

my $chaos = JSON::decode_json(Overnet::Burner::Config->normalized_json($scenario));
$chaos->{chaos} = [
    {
        at     => 15,
        action => 'restart',
        target => 'relay-001',
    },
];
my $chaos_plan = Overnet::Burner::Plan->build($chaos);
is scalar @{ $chaos_plan->{chaos_hooks} }, 1, 'plan expands chaos hooks';
is $chaos_plan->{chaos_hooks}[0]{id}, 'chaos-001', 'chaos hook has stable id';
is $chaos_plan->{chaos_hooks}[0]{at_seconds}, 15,
    'chaos hook records scheduled time';
is $chaos_plan->{chaos_hooks}[0]{action}, 'restart',
    'chaos hook records action';
is $chaos_plan->{chaos_hooks}[0]{target}, 'relay-001',
    'chaos hook records target';
ok $chaos_plan->{chaos_hooks}[0]{seed} =~ /\A\d+\z/,
    'chaos hook has deterministic seed';

my $json_a = Overnet::Burner::Plan->canonical_json($plan_a);
my $json_b = Overnet::Burner::Plan->canonical_json($plan_b);
is $json_a, $json_b, 'canonical plan JSON is deterministic';
is_deeply JSON::decode_json($json_a), $plan_a, 'canonical plan JSON decodes to plan';

done_testing;
