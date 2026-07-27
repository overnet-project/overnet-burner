use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;

my $tmp = tempdir(CLEANUP => 1);

subtest 'local-containers environment expands to managed relay and worker provisioning' => sub {
  my $scenario = _write_scenario(
    'managed.yml',
    <<'YAML',
environment:
  kind: local-containers
  engine: docker
run:
  name: managed-local-containers
  duration: 60
  seed: 12345
topology:
  relays:
    count: 2
  publishers:
    count: 2
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
YAML
  );

  my $config = Overnet::Burner::Config->load_file($scenario);

  is $config->{environment}, {kind => 'local-containers', engine => 'docker'},
    'the managed environment is retained in normalized config';
  is $config->{topology}{relays}{provider}, 'external-command',
    'managed local containers use provider lifecycle commands';
  is $config->{topology}{relays}{endpoints}, ['ws://relay-001:7447', 'ws://relay-002:7447'],
    'relay endpoints are synthesized as stable container-network aliases';
  like $config->{topology}{relays}{command}{start}, qr/overnet-relay\.pl/mx,
    'relay start command uses the reference relay command';
  like $config->{topology}{relays}{command}{health}, qr/relay-health\.json/mx,
    'relay health command checks the managed relay health file';
  like $config->{topology}{relays}{command}{stop}, qr/relay\.pid/mx,
    'relay stop command targets the managed relay pid file';

  is $config->{provision}{relays}{how},           'container', 'relays are container provisioned';
  is $config->{provision}{relays}{engine},        'docker',    'relay provisioning uses the environment engine';
  is $config->{provision}{relays}{network},       'bridge',    'relay containers use the run bridge network';
  is $config->{provision}{relays}{count},         2,           'relay container count follows topology';
  is $config->{provision}{relays}{managed_image}, 'reference', 'relay image is burner-managed';

  is $config->{provision}{workers}{how},           'container', 'workers are container provisioned';
  is $config->{provision}{workers}{engine},        'docker',    'worker provisioning uses the environment engine';
  is $config->{provision}{workers}{network},       'bridge',    'worker containers use the run bridge network';
  is $config->{provision}{workers}{count},         3,           'worker container count follows worker actors';
  is $config->{provision}{workers}{managed_image}, 'reference', 'worker image is burner-managed';
  is $config->{provision}{workers}{worker}, 'overnet-burner worker',
    'workers use the installed reference worker command inside the managed image';
};

subtest 'external-relays environment points workers at deployed endpoints' => sub {
  my $scenario = _write_scenario(
    'external.yml',
    <<'YAML',
environment:
  kind: external-relays
  relays:
    - ws://relay-a.example:7448
    - ws://relay-b.example:7447
run:
  name: external-relays-smoke
  duration: 60
  seed: 12345
topology:
  publishers:
    count: 2
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
YAML
  );

  my $config = Overnet::Burner::Config->load_file($scenario);

  is $config->{environment},
    {kind => 'external-relays', relays => ['ws://relay-a.example:7448', 'ws://relay-b.example:7447']},
    'the external-relays environment is retained in normalized config';
  is $config->{topology}{relays}{provider}, 'generic-relay',
    'external relays use the no-lifecycle generic-relay provider';
  is $config->{topology}{relays}{endpoints}, ['ws://relay-a.example:7448', 'ws://relay-b.example:7447'],
    'the deployed relay endpoints are used verbatim as worker targets';
  is $config->{topology}{relays}{count}, 2, 'the relay count follows the number of deployed endpoints';
  ok !exists $config->{topology}{relays}{command},
    'no relay lifecycle commands are synthesized for an external deployment';

  is $config->{provision}{relays}{how}, 'local',
    'burner does not provision the externally deployed relays';
  is $config->{provision}{workers}{how}, 'local',
    'workers default to the local runner unless the scenario asks otherwise';
};

subtest 'external-relays honors an explicit topology override' => sub {
  my $scenario = _write_scenario(
    'external-override.yml',
    <<'YAML',
environment:
  kind: external-relays
  relays:
    - ws://relay-a.example:7448
run:
  name: external-relays-override
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:7448
  publishers:
    count: 1
workload:
  publish_rate_per_second: 1
YAML
  );

  my $config = Overnet::Burner::Config->load_file($scenario);
  is $config->{topology}{relays}{endpoints}, ['ws://127.0.0.1:7448'],
    'an explicit topology.relays.endpoints wins over the environment shorthand';
};

subtest 'external-relays rejects invalid deployments' => sub {
  my @rejections = (
    [
      'empty relay list',
      "environment:\n  kind: external-relays\n  relays: []",
      qr/environment\.relays\ must\ list\ at\ least\ one\ relay\ endpoint/mx,
    ],
    [
      'non-websocket endpoint',
      "environment:\n  kind: external-relays\n  relays:\n    - http://relay.example:7448",
      qr/environment\.relays\[0\]\ must\ be\ a\ ws:\/\/\ or\ wss:\/\/\ endpoint/mx,
    ],
    [
      'unknown field',
      "environment:\n  kind: external-relays\n  relays:\n    - ws://relay:7448\n  engine: docker",
      qr/environment\.engine\ is\ not\ a\ known\ field\ for\ external-relays/mx,
    ],
    [
      'managed relay provider',
      "environment:\n  kind: external-relays\n  relays:\n    - ws://relay:7448\n"
        . "topology:\n  relays:\n    count: 1\n    provider: external-command\n"
        . "    command:\n      start: s\n      stop: t\n      health: h\n    endpoints:\n      - ws://relay:7448",
      qr/external-relays\ requires\ topology\.relays\.provider\ generic-relay/mx,
    ],
  );

  for my $case (@rejections) {
    my ($name, $body, $pattern) = @{$case};
    my $path = "external-invalid-$name.yml";
    $path =~ s/\ /-/gmx;
    my $scenario = _write_scenario(
      $path, <<"YAML");
$body
run:
  name: external-invalid
  duration: 60
  seed: 1
workload:
  publish_rate_per_second: 1
YAML

    my $error;
    eval { Overnet::Burner::Config->load_file($scenario); 1 } or $error = $@;
    like $error, $pattern, "$name is rejected";
  }
};

subtest 'unknown managed environments are rejected' => sub {
  my $scenario = _write_scenario(
    'unknown.yml',
    <<'YAML',
environment:
  kind: moon-base
run:
  name: bad-environment
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 5
YAML
  );

  my $error;
  eval { Overnet::Burner::Config->load_file($scenario); 1 } or $error = $@;
  like $error, qr/environment[.]kind\ must\ be\ one\ of\ local-containers/mx,
    'the validation error names supported managed environments';
};

done_testing;

sub _write_scenario {
  my ($basename, $content) = @_;
  my $path = File::Spec->catfile($tmp, $basename);
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return $path;
}
