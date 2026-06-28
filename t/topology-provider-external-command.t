use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test::More;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::RexBundle;
use Overnet::Burner::RunLedger;
use Overnet::Burner::TopologyProvider;

my $repo = "$FindBin::Bin/..";
my $bin = "$repo/bin/overnet-burner";
my $tmp = tempdir(CLEANUP => 1);

my $command = {
    start  => 'python -m pyovernet.relay --config {config}',
    stop   => 'pkill -f pyovernet.relay',
    health => 'curl -fsS http://127.0.0.1:{port}/health',
};

my $scenario_path = File::Spec->catfile($tmp, 'external-command.yml');
_write_yaml($scenario_path, _scenario_yaml($command));

my $scenario = Overnet::Burner::Config->load_file($scenario_path);
is $scenario->{topology}{relays}{provider}, 'external-command',
    'loads external-command provider name';
is_deeply $scenario->{topology}{relays}{command}, $command,
    'loads external-command descriptor';

my $provider = Overnet::Burner::TopologyProvider->from_relay_config(
    $scenario->{topology}{relays},
);
is_deeply $provider,
    {
    name    => 'external-command',
    command => $command,
    },
    'topology provider abstraction returns canonical descriptor';

my $normalized = JSON::decode_json(Overnet::Burner::Config->normalized_json($scenario));
is_deeply $normalized->{topology}{relays}{command}, $command,
    'normalized config preserves external-command descriptor';

for my $case (
    ['start',  undef, 'missing required field: topology.relays.command.start'],
    ['stop',   '',    'invalid field: topology.relays.command.stop must be a non-empty string'],
    ['health', [],    'invalid field: topology.relays.command.health must be a non-empty string'],
) {
    my ($field, $value, $pattern) = @{$case};
    my %bad_command = %{$command};
    if (defined $value) {
        $bad_command{$field} = $value;
    }
    else {
        delete $bad_command{$field};
    }

    my $bad_path = File::Spec->catfile($tmp, "missing-$field.yml");
    _write_yaml($bad_path, _scenario_yaml(\%bad_command));

    eval { Overnet::Burner::Config->load_file($bad_path) };
    like $@, qr/\Q$pattern\E/, "external-command validates command.$field";
}

my $bad_command_shape = File::Spec->catfile($tmp, 'bad-command-shape.yml');
_write_yaml(
    $bad_command_shape,
    _scenario_yaml('python -m pyovernet.relay --config {config}'),
);
eval { Overnet::Burner::Config->load_file($bad_command_shape) };
like $@, qr/topology\.relays\.command must be a mapping/,
    'external-command command descriptor must be a mapping';

my $generic_path = "$repo/scenarios/single-relay-baseline.yml";
my $generic_scenario = Overnet::Burner::Config->load_file($generic_path);
ok !exists $generic_scenario->{topology}{relays}{command},
    'generic-relay still does not require a command descriptor';

my $unknown_provider = File::Spec->catfile($tmp, 'unknown-provider.yml');
_write_yaml($unknown_provider, _scenario_yaml($command, provider => 'python-relay'));
eval { Overnet::Burner::Config->load_file($unknown_provider) };
like $@, qr/unknown topology provider: python-relay/,
    'rejects unsupported topology provider names';

my $plan_a = Overnet::Burner::Plan->build($scenario);
my $plan_b = Overnet::Burner::Plan->build($scenario);
is_deeply $plan_a, $plan_b, 'external-command plan is deterministic';

is_deeply $plan_a->{topology_provider},
    {
    name    => 'external-command',
    command => $command,
    },
    'plan records external-command descriptor under topology_provider';
ok !exists $plan_a->{provider},
    'external-command plan does not use ambiguous root provider field';

is $plan_a->{relays}[0]{topology_provider}, 'external-command',
    'relay actor records topology provider name';
is_deeply $plan_a->{relays}[0]{topology_provider_descriptor},
    { command => $command },
    'relay actor records provider descriptor for Rex rendering';
ok !exists $plan_a->{relays}[0]{provider},
    'relay actor does not use ambiguous provider field';

my $canonical_a = Overnet::Burner::Plan->canonical_json($plan_a);
my $canonical_b = Overnet::Burner::Plan->canonical_json($plan_b);
is $canonical_a, $canonical_b, 'external-command canonical plan JSON is stable';
is_deeply JSON::decode_json($canonical_a), $plan_a,
    'external-command canonical plan JSON decodes to the plan';

my $ledger = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'runs'),
    run_id        => 'external-command-render',
    now           => sub { '2026-06-27T14:00:00Z' },
    host_facts    => {
        hostname => 'builder-host',
        os       => 'linux',
        arch     => 'x86_64',
    },
    repo_sha    => 'abc123',
    rex_version => undef,
);
my $stored_plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});
my $bundle = Overnet::Burner::RexBundle->render(
    run_dir => $ledger->{run_dir},
    plan    => $stored_plan,
);
ok((grep { $_ eq 'topology-provider.json' } @{ $bundle->{files} }),
    'Rex bundle includes topology provider artifact',
);

my $bundle_dir = File::Spec->catdir($ledger->{run_dir}, 'artifacts', 'rex');
my $topology_provider = _read_json(
    File::Spec->catfile($bundle_dir, 'topology-provider.json'),
);
is_deeply $topology_provider,
    {
    topology_provider => {
        name    => 'external-command',
        command => $command,
    },
    relays => [
        {
            actor_id  => 'relay-001',
            lifecycle => {
                health => {
                    command   => $command->{health},
                    execution => 'planned',
                },
                start => {
                    command   => $command->{start},
                    execution => 'planned',
                },
                stop => {
                    command   => $command->{stop},
                    execution => 'planned',
                },
            },
        },
    ],
    },
    'Rex bundle renders provider lifecycle commands as planned artifacts';

my $relay_actor = _read_json(
    File::Spec->catfile($bundle_dir, 'actors', 'relay-001.json'),
);
is_deeply $relay_actor->{actor}{topology_provider_descriptor},
    { command => $command },
    'per-actor Rex config carries external-command descriptor data';
ok !exists $relay_actor->{actor}{provider},
    'per-actor Rex config avoids ambiguous provider field';

my $cli_tmp = tempdir(CLEANUP => 1);
my $cli_run_id = 'external-command-cli';
my $render = `$^X $bin render-rex --scenario $scenario_path --runs-dir $cli_tmp --run-id $cli_run_id 2>&1`;
is $?, 0, 'CLI render-rex accepts external-command scenario';
unlike $render, qr/^fatal:/m,
    'CLI render-rex does not leak git stderr for scenarios outside git';
like $render,
    qr{^rendered Rex bundle: \Q$cli_tmp/$cli_run_id/artifacts/rex\E$}m,
    'CLI render-rex reports external-command bundle directory';

my $cli_bundle_dir = File::Spec->catdir(
    $cli_tmp,
    $cli_run_id,
    'artifacts',
    'rex',
);
ok -e File::Spec->catfile($cli_bundle_dir, 'topology-provider.json'),
    'CLI render-rex writes topology provider artifact';
my $cli_plan = _read_json(File::Spec->catfile($cli_tmp, $cli_run_id, 'plan.json'));
is_deeply $cli_plan->{topology_provider}{command}, $command,
    'CLI render-rex writes descriptor into plan.json';
ok !exists $cli_plan->{provider},
    'CLI render-rex plan avoids ambiguous root provider field';

done_testing;

sub _scenario_yaml {
    my ($command_value, %args) = @_;
    my $provider = $args{provider} || 'external-command';

    my $command_yaml;
    if (ref $command_value eq 'HASH') {
        $command_yaml = '';
        for my $field (qw(start stop health)) {
            next unless exists $command_value->{$field};
            my $value = ref $command_value->{$field} eq 'ARRAY'
                ? '[]'
                : $command_value->{$field};
            $command_yaml .= "      $field: $value\n";
        }
    }
    else {
        $command_yaml = "      $command_value\n";
    }

    return <<"YAML";
run:
  name: external-command-relay
  duration: 60
  seed: 24680

topology:
  relays:
    count: 1
    provider: $provider
    command:
$command_yaml
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
}

sub _write_yaml {
    my ($path, $yaml) = @_;

    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $yaml;
    close $fh or die "close $path: $!";
}

sub _read_json {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return JSON::decode_json(<$fh>);
}
