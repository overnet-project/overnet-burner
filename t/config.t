use strictures 2;

use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;

my $repo          = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";

my $scenario = Overnet::Burner::Config->load_file($scenario_path);

is $scenario->{run}{name},                         'single-relay-baseline', 'loads scenario name';
is $scenario->{topology}{relays}{count},           1,                       'loads relay count';
is $scenario->{topology}{relays}{provider},        'generic-relay',         'loads provider name';
is $scenario->{workload}{publish_rate_per_second}, 10,                      'loads workload rate';

my $normalized_a = Overnet::Burner::Config->normalized_json($scenario);
my $normalized_b = Overnet::Burner::Config->normalized_json(Overnet::Burner::Config->load_file($scenario_path),);

is $normalized_a, $normalized_b, 'normalized config is deterministic';

my $decoded = JSON::decode_json($normalized_a);
is $decoded->{run}{seed},                  12345,           'normalized config keeps seed';
is $decoded->{topology}{relays}{provider}, 'generic-relay', 'normalized config keeps provider';

my $tmp                = tempdir(CLEANUP => 1);
my $standard_yaml_path = "$tmp/standard-yaml.yml";

open my $standard_fh, '>', $standard_yaml_path
  or die "open $standard_yaml_path: $!";
print {$standard_fh} <<'YAML';
---
run:
  name: standard-yaml
  duration: 60
  seed: 12345 # deterministic scenario seed
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 1
YAML
close $standard_fh or die "close $standard_yaml_path: $!";

my $standard_yaml = Overnet::Burner::Config->load_file($standard_yaml_path);
is $standard_yaml->{run}{seed}, 12345, 'loads standard YAML document markers and comments';

my $invalid_path = "$tmp/invalid.yml";

open my $fh, '>', $invalid_path or die "open $invalid_path: $!";
print {$fh} <<'YAML';
run:
  name: broken
  duration: 60
topology:
  relays:
    count: 1
workload:
  publish_rate_per_second: 1
YAML
close $fh or die "close $invalid_path: $!";

eval { Overnet::Burner::Config->load_file($invalid_path) };
like $@, qr/missing\ required\ field:\ run\.seed/mx, 'invalid scenario fails validation';

for my $case (
  [
    'root sequence',
    <<'YAML',
- run
- topology
YAML
    qr/root\ must\ be\ a\ mapping/mx,
  ],
  [
    'run sequence',
    <<'YAML',
run: []
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 1
YAML
    qr/run\ must\ be\ a\ mapping/mx,
  ],
  [
    'topology sequence',
    <<'YAML',
run:
  name: broken
  duration: 60
  seed: 12345
topology: []
workload:
  publish_rate_per_second: 1
YAML
    qr/topology\ must\ be\ a\ mapping/mx,
  ],
  [
    'workload sequence',
    <<'YAML',
run:
  name: broken
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
workload: []
YAML
    qr/workload\ must\ be\ a\ mapping/mx,
  ],
  [
    'thresholds sequence',
    <<'YAML',
run:
  name: broken
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 1
thresholds: []
YAML
    qr/thresholds\ must\ be\ a\ mapping/mx,
  ],
  [
    'object reads sequence',
    <<'YAML',
run:
  name: broken
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 1
  object_reads: []
YAML
    qr/workload\.object_reads\ must\ be\ a\ mapping/mx,
  ],
  [
    'chaos scalar entry',
    <<'YAML',
run:
  name: broken
  duration: 60
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 1
chaos:
  - 5
YAML
    qr/chaos\[0\]\ must\ be\ a\ mapping/mx,
  ],
) {
  my ($name, $yaml, $pattern) = @{$case};
  my $path = "$tmp/non-mapping-$name.yml";
  $path =~ s/\ /-/gmx;

  _write_yaml($path, $yaml);
  eval { Overnet::Burner::Config->load_file($path) };
  like $@, $pattern, "$name reports a clean mapping error";
}

subtest 'topology.relays.endpoints are validated when present' => sub {
  my $valid = "$tmp/relay-endpoints-valid.yml";
  _write_yaml($valid, <<'YAML');
run:
  name: endpoints-valid
  duration: 60
  seed: 1
topology:
  relays:
    count: 2
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:7001
      - ws://127.0.0.1:7002
  publishers:
    count: 1
  subscribers:
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0
workload:
  publish_rate_per_second: 1
YAML
  my $config = Overnet::Burner::Config->load_file($valid);
  is $config->{topology}{relays}{endpoints}, ['ws://127.0.0.1:7001', 'ws://127.0.0.1:7002'], 'valid endpoints load';
  my $normalized = JSON::decode_json(Overnet::Burner::Config->normalized_json($config));
  is $normalized->{topology}{relays}{endpoints}, ['ws://127.0.0.1:7001', 'ws://127.0.0.1:7002'],
    'normalized config preserves endpoints';

  my @rejections = (
    ['non-array',     "endpoints: ws://one",        qr/topology\.relays\.endpoints\ must\ be\ an\ array/mx],
    ['empty-entry',   "endpoints:\n      - ''",     qr/endpoints\[0\]\ must\ be\ a\ non-empty\ string/mx],
    ['mapping-entry', "endpoints:\n      - {u: x}", qr/endpoints\[0\]\ must\ be\ a\ non-empty\ string/mx],
  );
  for my $case (@rejections) {
    my ($name, $endpoints_yaml, $pattern) = @{$case};
    my $path = "$tmp/relay-endpoints-$name.yml";
    _write_yaml($path, <<"YAML");
run:
  name: endpoints-invalid
  duration: 60
  seed: 1
topology:
  relays:
    count: 1
    provider: generic-relay
    $endpoints_yaml
  publishers:
    count: 1
  subscribers:
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0
workload:
  publish_rate_per_second: 1
YAML
    eval { Overnet::Burner::Config->load_file($path) };
    like $@, $pattern, "$name endpoints are rejected";
  }

  my $mismatch = "$tmp/relay-endpoints-mismatch.yml";
  _write_yaml($mismatch, <<'YAML');
run:
  name: endpoints-mismatch
  duration: 60
  seed: 1
topology:
  relays:
    count: 2
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:7001
  publishers:
    count: 1
  subscribers:
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0
workload:
  publish_rate_per_second: 1
YAML
  eval { Overnet::Burner::Config->load_file($mismatch) };
  like $@, qr/one\ endpoint\ per\ relay/mx, 'endpoint count must match relay count';
};

done_testing;

sub _write_yaml {
  my ($path, $yaml) = @_;

  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $yaml;
  close $fh or die "close $path: $!";
  return;
}
