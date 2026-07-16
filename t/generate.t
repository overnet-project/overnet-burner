use strictures 2;

use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Generator;

my $repo = "$FindBin::Bin/..";

my %ABUSE_SINGULAR = (
  flooders             => 'flooder',
  malformed_publishers => 'malformed_publisher',
  replayers            => 'replayer',
  subscription_abusers => 'subscription_abuser',
  sybils               => 'sybil',
  connection_floods    => 'connection_flood',
);

subtest 'the default profile is valid and self-describing' => sub {
  my $default = Overnet::Burner::Generator->default_profile;
  ok(Overnet::Burner::Generator->validate_profile($default), 'default profile validates');

  my $normalized = Overnet::Burner::Generator->normalize_profile($default);
  is $normalized, $default, 'the default profile is already normalized (normalize is idempotent on it)';

  my $empty = Overnet::Burner::Generator->load_profile_data({});
  is $empty, $default, 'an empty profile normalizes to the built-in default';

  my $shipped = Overnet::Burner::Generator->load_profile("$repo/profiles/local-smoke.yml");
  is $shipped, $default, 'profiles/local-smoke.yml is exactly the built-in default';
};

subtest 'generation is deterministic in the seed' => sub {
  my $a = Overnet::Burner::Generator->generate(seed => 7);
  my $b = Overnet::Burner::Generator->generate(seed => 7);
  is $a,              $b, 'same seed yields an identical scenario';
  is $a->{run}{seed}, 7,  'the generated scenario carries the generation seed';

  my $yaml_a = Overnet::Burner::Generator->scenario_yaml($a);
  my $yaml_b = Overnet::Burner::Generator->scenario_yaml(Overnet::Burner::Generator->generate(seed => 7));
  is $yaml_a, $yaml_b, 'serialized output is byte-identical for the same seed';

  my %seen;
  $seen{Overnet::Burner::Generator->scenario_yaml(Overnet::Burner::Generator->generate(seed => $_))}++ for 1 .. 20;
  ok keys %seen > 1, 'different seeds explore different scenarios';
};

subtest 'every generated scenario passes validation' => sub {
  for my $profile_arg (
    undef,
    Overnet::Burner::Generator->load_profile("$repo/profiles/local-smoke.yml"),
    Overnet::Burner::Generator->load_profile("$repo/profiles/local-resilience.yml"),
    Overnet::Burner::Generator->load_profile("$repo/profiles/local-containers-smoke.yml"),
  ) {
    for my $seed (1 .. 60) {
      my $scenario = Overnet::Burner::Generator->generate(
        seed => $seed,
        defined $profile_arg ? (profile => $profile_arg) : (),
      );
      my $ok = eval { Overnet::Burner::Config->validate(Overnet::Burner::Config->normalize($scenario)); 1 };
      ok $ok, "seed $seed generates a valid scenario" or diag($@);
    }
  }
};

subtest 'the default profile stays inside its envelope' => sub {
  for my $seed (1 .. 60) {
    my $scenario = Overnet::Burner::Generator->generate(seed => $seed);

    is $scenario->{topology}{relays}{count},    1,               "seed $seed uses one relay";
    is $scenario->{topology}{relays}{provider}, 'generic-relay', "seed $seed uses the generic relay provider";
    is $scenario->{topology}{relays}{endpoints}, ['ws://127.0.0.1:7777'],
      "seed $seed carries the default local relay endpoint";

    my $duration = $scenario->{run}{duration};
    ok $duration >= 5 && $duration <= 30, "seed $seed duration $duration within [5,30]";

    my $rate = $scenario->{workload}{publish_rate_per_second};
    ok $rate >= 1 && $rate <= 50, "seed $seed publish rate $rate within [1,50]";

    for my $role (qw(publishers subscribers query_readers object_readers observers)) {
      my $count = $scenario->{topology}{$role}{count} // 0;
      my ($lo, $hi) = $role eq 'observers' ? (0, 1) : $role =~ /readers/ ? (0, 2) : (0, 3);
      ok $count >= $lo && $count <= $hi, "seed $seed $role count $count within [$lo,$hi]";
    }

    is $scenario->{chaos}, undef, "seed $seed default profile emits no chaos";
    for my $abuse (keys %ABUSE_SINGULAR) {
      is $scenario->{topology}{$abuse}, undef, "seed $seed default profile emits no $abuse";
    }
  }
};

subtest 'managed local-container profiles generate high-level scenarios' => sub {
  my $profile = Overnet::Burner::Generator->load_profile_data(
    {
      environment => {kind => 'local-containers'},
      duration    => {min  => 2, max => 2},
      relays      => {min  => 2, max => 2},
      roles       => {
        publishers  => {min => 1, max => 1},
        subscribers => {min => 1, max => 1},
      },
    }
  );

  my $scenario = Overnet::Burner::Generator->generate(seed => 42, profile => $profile);
  is $scenario->{environment}, {kind => 'local-containers'}, 'the generated scenario carries the managed environment';
  is $scenario->{topology}{relays}, {count => 2},            'relay wiring is left to environment normalization';
  ok !exists $scenario->{topology}{relays}{provider},  'the generator does not hard-code the managed provider';
  ok !exists $scenario->{topology}{relays}{endpoints}, 'the generator does not hard-code managed endpoints';
  ok !exists $scenario->{topology}{relays}{command},   'the generator does not hard-code managed commands';

  my $config = Overnet::Burner::Config->normalize($scenario);
  ok eval { Overnet::Burner::Config->validate($config); 1 }, 'the generated managed scenario validates';
  is $config->{topology}{relays}{provider}, 'external-command', 'normalization selects the managed relay provider';
  is $config->{topology}{relays}{endpoints}, ['ws://relay-001:7447', 'ws://relay-002:7447'],
    'normalization synthesizes managed relay endpoints';
  is $config->{provision}{relays}{how},  'container', 'managed relays are container provisioned';
  is $config->{provision}{workers}{how}, 'container', 'managed workers are container provisioned';
};

subtest 'profiles carry relay execution wiring into generated scenarios' => sub {
  my $command = {
    start  => 'echo start',
    health => 'echo health',
    stop   => 'echo stop',
  };
  my $profile = Overnet::Burner::Generator->load_profile_data(
    {
      duration => {min => 2, max => 2},
      relays   => {
        min       => 2,
        max       => 2,
        provider  => 'external-command',
        command   => $command,
        endpoints => ['ws://127.0.0.1:7001', 'ws://127.0.0.1:7002'],
      },
      roles => {
        publishers  => {min => 1, max => 1},
        subscribers => {min => 1, max => 1},
      },
      chaos => {max_hooks => 1, actions => ['restart']},
    }
  );

  my $scenario = Overnet::Burner::Generator->generate(seed => 42, profile => $profile);
  is $scenario->{topology}{relays}{provider}, 'external-command',
    'the generated scenario uses the profiled relay provider';
  is $scenario->{topology}{relays}{command}, $command, 'the generated scenario carries provider lifecycle commands';
  is $scenario->{topology}{relays}{endpoints},
    ['ws://127.0.0.1:7001', 'ws://127.0.0.1:7002'],
    'the generated scenario carries one endpoint per generated relay';

  ok eval { Overnet::Burner::Config->validate(Overnet::Burner::Config->normalize($scenario)); 1 },
    'the generated external-command scenario validates';
};

subtest 'external-command profiles can generate lifecycle chaos' => sub {
  my $profile = Overnet::Burner::Generator->load_profile_data(
    {
      duration => {min => 5, max => 5},
      relays   => {
        min      => 2,
        max      => 2,
        provider => 'external-command',
        command  => {
          start  => 'echo start',
          health => 'echo health',
          stop   => 'echo stop',
        },
        endpoints => ['ws://127.0.0.1:7001', 'ws://127.0.0.1:7002'],
      },
      roles => {
        publishers => {min => 1, max => 1},
      },
      chaos => {max_hooks => 2, actions => [qw(restart stop start)]},
    }
  );

  my $scenario = Overnet::Burner::Generator->generate(seed => 1, profile => $profile);
  is $scenario->{topology}{relays}{provider}, 'external-command',
    'the lifecycle-chaos scenario uses an executable relay provider';
  ok @{$scenario->{chaos} || []}, 'seed 1 generates at least one lifecycle hook';
  for my $hook (@{$scenario->{chaos}}) {
    ok $hook->{at} >= 0 && $hook->{at} < $scenario->{run}{duration},
      "chaos hook at $hook->{at} stays inside the run duration";
    like $hook->{action}, qr/\A(?:restart|stop|start)\z/mx, 'chaos hook uses a relay lifecycle action';
    my ($ordinal) = $hook->{target} =~ /\Arelay:([0-9]+)\z/mx;
    ok defined $ordinal && $ordinal >= 1 && $ordinal <= $scenario->{topology}{relays}{count},
      'chaos hook targets a generated relay';
  }
  ok eval { Overnet::Burner::Config->validate(Overnet::Burner::Config->normalize($scenario)); 1 },
    'the generated lifecycle-chaos scenario validates';
};

subtest 'profiles with variable relay counts use the matching endpoint prefix' => sub {
  my $profile = Overnet::Burner::Generator->load_profile_data(
    {
      duration => {min => 2, max => 2},
      relays   => {
        min       => 1,
        max       => 2,
        endpoints => ['ws://127.0.0.1:7001', 'ws://127.0.0.1:7002'],
      },
      roles => {
        publishers => {min => 1, max => 1},
      },
    }
  );

  for my $seed (1 .. 40) {
    my $scenario = Overnet::Burner::Generator->generate(seed => $seed, profile => $profile);
    is scalar @{$scenario->{topology}{relays}{endpoints}},
      $scenario->{topology}{relays}{count},
      "seed $seed emits one endpoint per generated relay";
  }
};

subtest 'reader roles always come with the workload they require' => sub {
  for my $seed (1 .. 60) {
    my $scenario = Overnet::Burner::Generator->generate(seed => $seed);
    my $topology = $scenario->{topology};
    my $workload = $scenario->{workload};

    if (($topology->{subscribers}{count} // 0) > 0) {
      ok ref $workload->{subscription_filters} eq 'ARRAY' && @{$workload->{subscription_filters}},
        "seed $seed declares subscription_filters for its subscribers";
    }
    if (($topology->{query_readers}{count} // 0) > 0) {
      ok ref $workload->{query_filters} eq 'ARRAY' && @{$workload->{query_filters}},
        "seed $seed declares query_filters for its query readers";
    }
    if (($topology->{object_readers}{count} // 0) > 0) {
      ok ref $workload->{object_reads}{objects} eq 'ARRAY' && @{$workload->{object_reads}{objects}},
        "seed $seed declares object_reads.objects for its object readers";
    }
  }
};

subtest 'the resilience profile exercises abuse without unsupported lifecycle chaos' => sub {
  my $profile = Overnet::Burner::Generator->load_profile("$repo/profiles/local-resilience.yml");

  my $saw_abuse = 0;
  for my $seed (1 .. 80) {
    my $scenario = Overnet::Burner::Generator->generate(seed => $seed, profile => $profile);
    is scalar @{$scenario->{topology}{relays}{endpoints}},
      $scenario->{topology}{relays}{count},
      "seed $seed carries one endpoint per relay";
    is $scenario->{chaos}, undef, "seed $seed local-resilience profile emits no lifecycle chaos";

    for my $abuse (sort keys %ABUSE_SINGULAR) {
      my $count = $scenario->{topology}{$abuse}{count} // 0;
      next if $count == 0;
      $saw_abuse = 1;
      my $singular = $ABUSE_SINGULAR{$abuse};
      my $rate     = $scenario->{workload}{abuse}{$singular}{publish_rate_per_second};
      ok defined $rate && $rate =~ /\A[0-9]/mx, "seed $seed gives $abuse a numeric abuse rate";
    }
  }
  ok $saw_abuse, 'the resilience profile produces abuse traffic across seeds';
};

subtest 'the managed local-containers profile produces valid managed scenarios' => sub {
  my $profile = Overnet::Burner::Generator->load_profile("$repo/profiles/local-containers-smoke.yml");

  for my $seed (1 .. 40) {
    my $scenario = Overnet::Burner::Generator->generate(seed => $seed, profile => $profile);
    is $scenario->{environment}{kind}, 'local-containers', "seed $seed uses the managed container environment";
    ok !exists $scenario->{topology}{relays}{endpoints}, "seed $seed leaves managed endpoints to config";

    my $ok = eval { Overnet::Burner::Config->validate(Overnet::Burner::Config->normalize($scenario)); 1 };
    ok $ok, "seed $seed managed scenario validates" or diag($@);
  }
};

subtest 'a generated scenario round-trips through the loader' => sub {
  my $tmp      = tempdir(CLEANUP => 1);
  my $scenario = Overnet::Burner::Generator->generate(seed => 99);
  my $path     = "$tmp/generated.yml";
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} Overnet::Burner::Generator->scenario_yaml($scenario);
  close $fh or die "close $path: $!";

  my $loaded = Overnet::Burner::Config->load_file($path);
  is $loaded->{run}{seed},                  99,              'the emitted YAML loads and keeps the seed';
  is $loaded->{topology}{relays}{provider}, 'generic-relay', 'the emitted YAML loads the topology';
};

subtest 'malformed profiles are rejected' => sub {
  my @cases = (
    ['duration min above max', {duration => {min => 30, max => 5}},       qr/duration\.min.*must\ not\ exceed.*max/mx],
    ['relays min above max',   {relays   => {min => 3, max => 1}},        qr/relays\.min.*must\ not\ exceed.*max/mx],
    ['unknown top-level key',  {galaxies => {min => 1}},                  qr/unknown\ profile\ field:\ galaxies/mx],
    ['unknown role',           {roles    => {gremlins => {max => 1}}},    qr/unknown\ generatable\ role:\ gremlins/mx],
    ['negative role max',      {roles    => {publishers => {max => -1}}}, qr/roles\.publishers\.max.*non-negative/mx],
    [
      'role min above max',
      {roles => {publishers => {min => 4, max => 2}}},
      qr/roles\.publishers\.min.*must\ not\ exceed.*max/mx
    ],
    ['unknown chaos action',     {chaos     => {actions   => ['melt']}},         qr/chaos\.actions.*melt.*lifecycle/mx],
    ['negative chaos max_hooks', {chaos     => {max_hooks => -1}},               qr/chaos\.max_hooks.*non-negative/mx],
    ['unknown provision method', {provision => {workers   => ['teleport']}},     qr/provision\.workers.*teleport/mx],
    ['non-integer bound',        {duration  => {min       => 'soon', max => 5}}, qr/duration\.min.*integer/mx],
    [
      'unknown environment kind',
      {environment => {kind => 'remote-containers'}},
      qr/environment\.kind.*local-containers/mx
    ],
    [
      'unknown environment field',
      {environment => {kind => 'local-containers', zone => 'dev'}},
      qr/environment\.zone.*known\ field/mx,
    ],
    [
      'managed profile with relay provider',
      {environment => {kind => 'local-containers'}, relays => {provider => 'generic-relay'}},
      qr/environment\.kind\ local-containers.*relays\.provider/mx,
    ],
    [
      'managed profile with relay endpoints',
      {environment => {kind => 'local-containers'}, relays => {endpoints => ['ws://127.0.0.1:7777']}},
      qr/environment\.kind\ local-containers.*relays\.endpoints/mx,
    ],
    [
      'managed profile with relay commands',
      {
        environment => {kind => 'local-containers'},
        relays      => {
          command => {
            start  => 'echo start',
            health => 'echo health',
            stop   => 'echo stop',
          },
        },
      },
      qr/environment\.kind\ local-containers.*relays\.command/mx,
    ],
    [
      'worker-capable profile without endpoints',
      {roles => {publishers => {max => 1}}, relays => {min => 1, max => 2}},
      qr/relays\.endpoints.*required.*worker/mx,
    ],
    [
      'too few relay endpoints',
      {
        roles  => {publishers => {max => 1}},
        relays => {min        => 1, max => 2, endpoints => ['ws://127.0.0.1:7001']},
      },
      qr/relays\.endpoints.*at\ least.*relays\.max/mx,
    ],
    [
      'external-command without commands',
      {roles => {}, relays => {provider => 'external-command'}},
      qr/relays\.command.*required.*external-command/mx,
    ],
    [
      'lifecycle chaos without lifecycle commands',
      {
        roles  => {},
        relays => {provider  => 'generic-relay'},
        chaos  => {max_hooks => 1, actions => ['restart']},
      },
      qr/lifecycle\ chaos.*external-command/mx,
    ],
    [
      'invalid environment engine',
      {environment => {kind => 'local-containers', engine => 'hypervisor'}},
      qr/environment\.engine\ must\ be/mx,
    ],
    [
      'empty environment image',
      {environment => {kind => 'local-containers', image => q{}}},
      qr/environment\.image\ must\ be\ a\ non-empty/mx,
    ],
    ['unknown relay field',   {roles => {}, relays => {galaxy   => 1}},        qr/unknown\ relay\ profile\ field/mx],
    ['invalid relay provider', {roles => {}, relays => {provider => 'weird'}}, qr/relays\.provider\ must\ be/mx],
    ['non-mapping profile',    ['not', 'a', 'map'],                            qr/profile\ must\ be\ a\ mapping/mx],
  );
  for my $case (@cases) {
    my ($name, $profile, $pattern) = @{$case};
    my $err;
    eval { Overnet::Burner::Generator->load_profile_data($profile); 1 } or $err = $@;
    like $err, $pattern, "$name is rejected";
  }
};

subtest 'a managed profile may pin its engine and image' => sub {
  my $profile = Overnet::Burner::Generator->load_profile_data(
    {environment => {kind => 'local-containers', engine => 'docker', image => 'burner:pinned'}});
  is $profile->{environment}{engine}, 'docker',        'a valid engine is accepted';
  is $profile->{environment}{image},  'burner:pinned', 'a valid image is accepted';
};

subtest 'a fractional workload range is drawn continuously, not collapsed to its floor' => sub {
  # workload ranges validate as numbers (numeric => 1), so a profile may declare
  # a fractional publish rate. Drawing such a range through integer modulo would
  # truncate the width to an integer and pin every draw to the range minimum,
  # making the declared maximum unreachable. Sweep seeds and require the drawn
  # rate to stay in bounds, vary, and actually rise above the floor.
  my $profile = Overnet::Burner::Generator->load_profile_data(
    {
      duration => {min => 2, max => 2},
      relays   => {min => 1, max => 1, endpoints => ['ws://127.0.0.1:7001']},
      roles    => {publishers => {min => 1, max => 1}},
      workload => {publish_rate_per_second => {min => 1.2, max => 1.8}},
    }
  );

  my %seen;
  my $above_floor = 0;
  for my $seed (1 .. 60) {
    my $scenario = Overnet::Burner::Generator->generate(seed => $seed, profile => $profile);
    my $rate     = $scenario->{workload}{publish_rate_per_second};
    ok $rate >= 1.2 && $rate <= 1.8, "seed $seed draws within the fractional range" if $seed <= 3;
    $seen{$rate}++;
    $above_floor++ if $rate > 1.2;
  }

  ok keys %seen > 1, 'the fractional range explores more than a single value';
  ok $above_floor > 0, 'some seed draws above the range floor, so the declared maximum is reachable';

  my @out_of_bounds = grep { $_ < 1.2 || $_ > 1.8 } keys %seen;
  is \@out_of_bounds, [], 'every drawn rate stays within the declared bounds';

  # A degenerate fractional range (min == max) has no width to draw across and
  # must return that exact value for every seed.
  my $pinned = Overnet::Burner::Generator->load_profile_data(
    {
      duration => {min => 2, max => 2},
      relays   => {min => 1, max => 1, endpoints => ['ws://127.0.0.1:7001']},
      roles    => {publishers => {min => 1, max => 1}},
      workload => {publish_rate_per_second => {min => 1.5, max => 1.5}},
    }
  );
  my %pinned_seen;
  $pinned_seen{Overnet::Burner::Generator->generate(seed => $_, profile => $pinned)->{workload}{publish_rate_per_second}}
    ++
    for 1 .. 5;
  is [sort keys %pinned_seen], [1.5], 'a degenerate fractional range returns its single value';
};

subtest 'load_profile reads YAML and tolerates an empty document' => sub {
  my $dir = tempdir(CLEANUP => 1);

  my $good = "$dir/good.yml";
  _spew($good, "roles:\n  publishers:\n    max: 1\nrelays:\n  min: 1\n  max: 1\n  endpoints:\n    - ws://127.0.0.1:7001\n");
  ok(Overnet::Burner::Generator->load_profile($good), 'a YAML profile loads');

  my $empty = "$dir/empty.yml";
  _spew($empty, q{});
  ok(Overnet::Burner::Generator->load_profile($empty), 'an empty YAML document loads as an empty profile');

  my $broken = "$dir/broken.yml";
  _spew($broken, "roles: [unterminated\n");
  like dies { Overnet::Burner::Generator->load_profile($broken) }, qr/broken\.yml/mx, 'malformed YAML names the file';
};

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print: $!";
  close $fh or die "close: $!";
  return;
}

done_testing;
