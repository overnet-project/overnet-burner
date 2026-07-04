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
