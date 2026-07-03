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
is $standard_yaml->{run}{seed},                       12345, 'loads standard YAML document markers and comments';
is $standard_yaml->{workload}{query_rate_per_second}, 1,     'workload query rate defaults to one per second';
is $scenario->{workload}{query_rate_per_second},      1,     'baseline scenario gets the default query rate';
is $standard_yaml->{workload}{object_reads}, {rate_per_second => 1, objects => []},
  'workload object reads default to one per second over no objects';
is $scenario->{workload}{object_reads}{objects}, [{type => 'chat.channel', id => 'irc:local:#overnet'}],
  'baseline scenario keeps its object read references';

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
  [
    'negative query rate',
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
  query_rate_per_second: -1
YAML
    qr/workload\.query_rate_per_second\ must\ be\ a\ non-negative\ number/mx,
  ],
  [
    'negative object read rate',
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
  object_reads:
    rate_per_second: -1
YAML
    qr/workload\.object_reads\.rate_per_second\ must\ be\ a\ non-negative\ number/mx,
  ],
  [
    'object read reference without id',
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
  object_reads:
    objects:
      - type: chat.channel
YAML
    qr/workload\.object_reads\.objects\[0\]\.id\ must\ be\ a\ non-empty\ string/mx,
  ],
  [
    'chaos hook with unknown action',
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
  - at: 10
    action: melt
    target: relay:1
YAML
    qr/chaos\[0\]\.action\ must\ be\ one\ of\ restart,\ start,\ stop/mx,
  ],
  [
    'chaos hook with a reserved action',
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
  - at: 10
    action: net-delay
    target: relay:1
YAML
    qr/chaos\[0\]\.action\ net-delay\ is\ reserved\ for\ a\ future\ version/mx,
  ],
  [
    'chaos hook scheduled past the run duration',
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
  - at: 60
    action: restart
    target: relay:1
YAML
    qr/chaos\[0\]\.at\ must\ be\ inside\ the\ run\ duration/mx,
  ],
  [
    'chaos hook targeting a relay that does not exist',
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
  - at: 10
    action: restart
    target: relay:2
YAML
    qr/chaos\[0\]\.target\ must\ name\ a\ configured\ relay/mx,
  ],
  [
    'chaos hook with a malformed target',
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
  - at: 10
    action: restart
    target: relay-001
YAML
    qr/chaos\[0\]\.target\ must\ name\ a\ configured\ relay\ as\ relay:<ordinal>/mx,
  ],
) {
  my ($name, $yaml, $pattern) = @{$case};
  my $path = "$tmp/non-mapping-$name.yml";
  $path =~ s/\ /-/gmx;

  _write_yaml($path, $yaml);
  eval { Overnet::Burner::Config->load_file($path) };
  like $@, $pattern, "$name reports a clean mapping error";
}

subtest 'workload phases load and validate' => sub {
  my $valid = "$tmp/phases-valid.yml";
  _write_yaml($valid, <<'YAML');
run:
  name: phases-valid
  duration: 60
  seed: 1
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
workload:
  publish_rate_per_second: 10
  warmup:
    duration: 10
    publish_rate_per_second: 2
  cooldown:
    duration: 5
    publish_rate_per_second: 0
chaos:
  - at: 65
    action: restart
    target: relay:1
YAML
  my $config = Overnet::Burner::Config->load_file($valid);
  is $config->{workload}{warmup}{duration},   10, 'warmup loads';
  is $config->{workload}{cooldown}{duration}, 5,  'cooldown loads';

  my @rejections = (
    [
      'warmup without duration',
      "warmup:\n    publish_rate_per_second: 2",
      qr/missing\ required\ field:\ workload\.warmup\.duration/mx,
    ],
    [
      'negative warmup rate',
      "warmup:\n    duration: 10\n    publish_rate_per_second: -1",
      qr/workload\.warmup\.publish_rate_per_second\ must\ be\ a\ non-negative\ number/mx,
    ],
    ['cooldown as a sequence', 'cooldown: []', qr/workload\.cooldown\ must\ be\ a\ mapping/mx,],
  );
  for my $case (@rejections) {
    my ($name, $phase_yaml, $pattern) = @{$case};
    my $path = "$tmp/phases-$name.yml";
    $path =~ s/\ /-/gmx;
    _write_yaml($path, <<"YAML");
run:
  name: phases-invalid
  duration: 60
  seed: 1
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 10
  $phase_yaml
YAML
    eval { Overnet::Burner::Config->load_file($path) };
    like $@, $pattern, "$name is rejected";
  }

  my $chaos_past_total = "$tmp/phases-chaos-late.yml";
  _write_yaml($chaos_past_total, <<'YAML');
run:
  name: phases-chaos-late
  duration: 60
  seed: 1
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 10
  warmup:
    duration: 10
chaos:
  - at: 70
    action: restart
    target: relay:1
YAML
  eval { Overnet::Burner::Config->load_file($chaos_past_total) };
  like $@, qr/chaos\[0\]\.at\ must\ be\ inside\ the\ run\ duration\ \(0\ <=\ at\ <\ 70\)/mx,
    'chaos offsets are validated against the total workload window';
};

subtest 'provision configuration validates' => sub {
  my $valid = "$tmp/provision-valid.yml";
  _write_yaml($valid, <<'YAML');
run:
  name: provision-valid
  duration: 60
  seed: 1
topology:
  relays:
    count: 1
    provider: generic-relay
  publishers:
    count: 1
workload:
  publish_rate_per_second: 1
provision:
  workers:
    how: connect
    guests:
      - address: load-1.example.net
        user: burner
        port: 2222
        key: /keys/burner
      - address: load-2.example.net
  relays:
    how: local
YAML
  my $config = Overnet::Burner::Config->load_file($valid);
  is $config->{provision}{workers}{how},              'connect', 'connect provisioning loads';
  is scalar @{$config->{provision}{workers}{guests}}, 2,         'connect guests load';
  is $config->{provision}{relays}{how},               'local',   'local provisioning loads';

  my $default = Overnet::Burner::Config->load_file($scenario_path);
  is $default->{provision}{workers}{how}, 'local', 'omitting provision means local for every group';
  is $default->{provision}{relays}{how},  'local', 'omitting provision means local for relays too';

  my @rejections = (
    [
      'unknown group',
      "provision:\n  gateways:\n    how: local",
      qr/provision\ groups\ must\ be\ relays\ or\ workers/mx,
    ],
    [
      'unknown how',
      "provision:\n  workers:\n    how: teleport",
      qr/provision\.workers\.how\ must\ be\ one\ of\ connect,\ container,\ local,\ virtual/mx,
    ],
    [
      'reserved how',
      "provision:\n  workers:\n    how: virtual",
      qr/provision\.workers\.how\ virtual\ is\ not\ implemented\ yet/mx,
    ],
    [
      'relay connect unimplemented',
      "provision:\n  relays:\n    how: connect\n    guests:\n      - address: r1",
      qr/provision\.relays\.how\ connect\ is\ not\ implemented\ yet/mx,
    ],
    [
      'connect without guests',
      "provision:\n  workers:\n    how: connect",
      qr/provision\.workers\.guests\ must\ list\ at\ least\ one\ guest/mx,
    ],
    [
      'guest without address',
      "provision:\n  workers:\n    how: connect\n    guests:\n      - user: burner",
      qr/provision\.workers\.guests\[0\]\.address\ must\ be\ a\ non-empty\ string/mx,
    ],
    [
      'local with guests',
      "provision:\n  workers:\n    how: local\n    guests:\n      - address: nope",
      qr/provision\.workers\.guests\ is\ only\ valid\ for\ how:\ connect/mx,
    ],
  );

  for my $case (@rejections) {
    my ($name, $provision_yaml, $pattern) = @{$case};
    my $path = "$tmp/provision-$name.yml";
    $path =~ s/\ /-/gmx;
    _write_yaml($path, <<"YAML");
run:
  name: provision-invalid
  duration: 60
  seed: 1
topology:
  relays:
    count: 1
    provider: generic-relay
workload:
  publish_rate_per_second: 1
$provision_yaml
YAML
    eval { Overnet::Burner::Config->load_file($path) };
    like $@, $pattern, "$name is rejected";
  }
};

subtest 'valid chaos hooks load' => sub {
  my $path = "$tmp/chaos-valid.yml";
  _write_yaml($path, <<'YAML');
run:
  name: chaos-valid
  duration: 60
  seed: 1
topology:
  relays:
    count: 2
    provider: generic-relay
  publishers:
    count: 1
workload:
  publish_rate_per_second: 1
chaos:
  - at: 10
    action: restart
    target: relay:2
  - at: 20
    action: stop
    target: relay:1
YAML
  my $config = Overnet::Burner::Config->load_file($path);
  is scalar @{$config->{chaos}},  2,         'chaos hooks load';
  is $config->{chaos}[0]{target}, 'relay:2', 'chaos target is preserved';
};

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
