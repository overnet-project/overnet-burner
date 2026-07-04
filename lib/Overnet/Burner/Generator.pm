package Overnet::Burner::Generator;

use strictures 2;

use Carp        qw(croak);
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use YAML::PP;

use Overnet::Burner::Util qw(clone_json read_file);

our $VERSION = '0.001';

my @HONEST_ROLES   = qw(publishers subscribers query_readers object_readers observers);
my %ABUSE_SINGULAR = (
  flooders             => 'flooder',
  malformed_publishers => 'malformed_publisher',
  replayers            => 'replayer',
  subscription_abusers => 'subscription_abuser',
  sybils               => 'sybil',
  connection_floods    => 'connection_flood',
);
my %GENERATABLE_ROLE = map { $_ => 1 } @HONEST_ROLES, keys %ABUSE_SINGULAR;

my %RANGE_DEFAULT = (
  publish_rate_per_second       => [1, 50],
  query_rate_per_second         => [1, 10],
  object_read_rate_per_second   => [1, 5],
  abuse_publish_rate_per_second => [1, 200],
);
my %LIFECYCLE_ACTION = map { $_ => 1 } qw(restart stop start);
my %PROVISION_METHOD = (local => 1);

sub default_profile {
  return {
    duration => {min => 5, max => 30},
    relays   => {
      min       => 1,
      max       => 1,
      provider  => 'generic-relay',
      endpoints => ['ws://127.0.0.1:7777'],
    },
    roles => {
      publishers     => {min => 0, max => 3},
      subscribers    => {min => 0, max => 3},
      query_readers  => {min => 0, max => 2},
      object_readers => {min => 0, max => 2},
      observers      => {min => 0, max => 1},
    },
    workload => {
      publish_rate_per_second       => {min => 1, max => 50},
      query_rate_per_second         => {min => 1, max => 10},
      object_read_rate_per_second   => {min => 1, max => 5},
      abuse_publish_rate_per_second => {min => 1, max => 200},
    },
    chaos     => {max_hooks => 0,         actions => [qw(restart stop start)]},
    provision => {workers   => ['local'], relays  => ['local']},
  };
}

sub load_profile {
  my ($class, $path) = @_;

  my $text = read_file($path);
  my $raw;
  if (!eval { $raw = YAML::PP->new(schema => ['Core'])->load_string($text); 1 }) {
    croak "$path: $EVAL_ERROR";
  }
  if (!defined $raw) {
    $raw = {};
  }

  return $class->load_profile_data($raw);
}

sub load_profile_data {
  my ($class, $raw) = @_;

  my $profile = $class->normalize_profile($raw);
  $class->validate_profile($profile);

  return $profile;
}

sub normalize_profile {
  my ($class, $raw) = @_;

  if (ref $raw ne 'HASH') {
    croak "profile must be a mapping\n";
  }
  my $profile = clone_json($raw);

  $profile->{duration} = _fill_range($profile->{duration}, 5, 30);
  $profile->{relays}   = _fill_range($profile->{relays},   1, 1);
  if (!exists $profile->{relays}{provider}) {
    $profile->{relays}{provider} = 'generic-relay';
  }
  my $default_relays = default_profile()->{relays};
  if ( !exists $profile->{relays}{endpoints}
    && $profile->{relays}{min} == $default_relays->{min}
    && $profile->{relays}{max} == $default_relays->{max}) {
    $profile->{relays}{endpoints} = clone_json($default_relays->{endpoints});
  }

  if (!exists $profile->{roles}) {
    $profile->{roles} = clone_json(default_profile()->{roles});
  } else {
    _require_mapping($profile->{roles}, 'roles');
    for my $role (keys %{$profile->{roles}}) {
      $profile->{roles}{$role} = _fill_role_bounds($profile->{roles}{$role});
    }
  }

  $profile->{workload} ||= {};
  _require_mapping($profile->{workload}, 'workload');
  for my $key (keys %RANGE_DEFAULT) {
    my ($lo, $hi) = @{$RANGE_DEFAULT{$key}};
    if (exists $profile->{workload}{$key}) {
      $profile->{workload}{$key} = _fill_range($profile->{workload}{$key}, $lo, $hi);
    } else {
      $profile->{workload}{$key} = {min => $lo, max => $hi};
    }
  }

  $profile->{chaos} ||= {};
  _require_mapping($profile->{chaos}, 'chaos');
  if (!exists $profile->{chaos}{max_hooks}) {
    $profile->{chaos}{max_hooks} = 0;
  }
  $profile->{chaos}{actions} ||= [qw(restart stop start)];

  $profile->{provision} ||= {};
  _require_mapping($profile->{provision}, 'provision');
  for my $group (qw(workers relays)) {
    $profile->{provision}{$group} ||= ['local'];
  }

  return $profile;
}

sub _fill_range {
  my ($range, $default_min, $default_max) = @_;

  $range ||= {};
  _require_mapping($range, 'range');
  my %filled = %{$range};
  if (!exists $filled{min}) {
    $filled{min} = $default_min;
  }
  if (!exists $filled{max}) {
    $filled{max} = $default_max;
  }

  return \%filled;
}

sub _fill_role_bounds {
  my ($bounds) = @_;

  $bounds ||= {};
  _require_mapping($bounds, 'role bounds');
  my %filled = %{$bounds};
  if (!exists $filled{min}) {
    $filled{min} = 0;
  }
  if (!exists $filled{max}) {
    $filled{max} = $filled{min};
  }

  return \%filled;
}

sub _require_mapping {
  my ($value, $label) = @_;

  if (ref $value ne 'HASH') {
    croak "$label must be a mapping\n";
  }
  return $value;
}

sub validate_profile {
  my ($class, $profile) = @_;

  my %known = map { $_ => 1 } qw(duration relays roles workload chaos provision);
  for my $key (sort keys %{$profile}) {
    if (!$known{$key}) {
      croak "unknown profile field: $key\n";
    }
  }

  _validate_bound_range($profile->{duration}, 'duration', floor => 1);
  _validate_bound_range($profile->{relays},   'relays',   floor => 1);
  _validate_relay_profile($profile->{relays});

  for my $role (sort keys %{$profile->{roles}}) {
    if (!$GENERATABLE_ROLE{$role}) {
      croak "unknown generatable role: $role\n";
    }
    _validate_bound_range($profile->{roles}{$role}, "roles.$role", floor => 0);
  }

  for my $key (sort keys %{$profile->{workload}}) {
    if (!$RANGE_DEFAULT{$key}) {
      croak "unknown workload range: workload.$key\n";
    }
    _validate_bound_range($profile->{workload}{$key}, "workload.$key", floor => 0, numeric => 1);
  }

  _validate_chaos_profile($profile->{chaos});
  _validate_provision_profile($profile->{provision});
  _validate_profile_execution_wiring($profile);

  return 1;
}

sub _validate_relay_profile {
  my ($relays) = @_;

  my %known = map { $_ => 1 } qw(min max provider endpoints command);
  for my $key (sort keys %{$relays}) {
    if (!$known{$key}) {
      croak "unknown relay profile field: relays.$key\n";
    }
  }

  my $provider = $relays->{provider};
  if (!(defined $provider && !ref($provider) && ($provider eq 'generic-relay' || $provider eq 'external-command'))) {
    croak "relays.provider must be generic-relay or external-command\n";
  }

  if (exists $relays->{endpoints}) {
    _validate_relay_endpoints($relays);
  }
  if (exists $relays->{command}) {
    _validate_relay_command($relays->{command}, 'relays.command');
  }
  if ($provider eq 'external-command' && !exists $relays->{command}) {
    croak "relays.command is required when relays.provider is external-command\n";
  }
  if ($provider ne 'external-command' && exists $relays->{command}) {
    croak "relays.command is only valid when relays.provider is external-command\n";
  }

  return 1;
}

sub _validate_relay_endpoints {
  my ($relays) = @_;

  my $endpoints = $relays->{endpoints};
  if (ref $endpoints ne 'ARRAY') {
    croak "relays.endpoints must be a list\n";
  }
  for my $index (0 .. $#{$endpoints}) {
    my $endpoint = $endpoints->[$index];
    if (!(defined $endpoint && !ref($endpoint) && length $endpoint)) {
      croak "relays.endpoints[$index] must be a non-empty string\n";
    }
  }
  if (@{$endpoints} < $relays->{max}) {
    croak "relays.endpoints must provide at least relays.max endpoints\n";
  }

  return 1;
}

sub _validate_relay_command {
  my ($command, $path) = @_;

  _require_mapping($command, $path);
  my %known = map { $_ => 1 } qw(start health stop);
  for my $key (sort keys %{$command}) {
    if (!$known{$key}) {
      croak "unknown relay command field: $path.$key\n";
    }
  }
  for my $key (qw(start health stop)) {
    my $value = $command->{$key};
    if (!(defined $value && !ref($value) && length $value)) {
      croak "$path.$key must be a non-empty string\n";
    }
  }

  return 1;
}

sub _validate_profile_execution_wiring {
  my ($profile) = @_;

  if (_profile_may_launch_workers($profile) && !exists $profile->{relays}{endpoints}) {
    croak "relays.endpoints is required when generated worker roles can be launched\n";
  }

  if (_profile_may_generate_lifecycle_chaos($profile) && $profile->{relays}{provider} ne 'external-command') {
    croak "lifecycle chaos requires relays.provider external-command with lifecycle commands\n";
  }

  return 1;
}

sub _profile_may_launch_workers {
  my ($profile) = @_;

  for my $role (keys %{$profile->{roles}}) {
    if (($profile->{roles}{$role}{max} || 0) > 0) {
      return 1;
    }
  }

  return 0;
}

sub _profile_may_generate_lifecycle_chaos {
  my ($profile) = @_;

  return ($profile->{chaos}{max_hooks} || 0) > 0 && @{$profile->{chaos}{actions} || []};
}

sub _validate_bound_range {
  my ($range, $path, %opts) = @_;

  my $floor   = $opts{floor};
  my $numeric = $opts{numeric};
  my $min     = _validate_number($range->{min}, "$path.min", $numeric, $floor);
  my $max     = _validate_number($range->{max}, "$path.max", $numeric, $floor);
  if ($min > $max) {
    croak "$path.min ($min) must not exceed $path.max ($max)\n";
  }

  return 1;
}

sub _validate_number {
  my ($value, $path, $numeric, $floor) = @_;

  my $kind    = $numeric ? 'number'                             : 'integer';
  my $pattern = $numeric ? qr/\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/mxs : qr/\A-?\d+\z/mxs;
  if (ref $value || !defined $value || "$value" !~ $pattern) {
    my $article = $floor >= 1 ? 'a positive' : 'a non-negative';
    croak "$path must be $article $kind\n";
  }
  if ($floor >= 1 && !($value >= $floor)) {
    croak "$path must be a positive $kind\n";
  }
  if ($floor == 0 && $value < 0) {
    croak "$path must be a non-negative $kind\n";
  }

  return $value;
}

sub _validate_chaos_profile {
  my ($chaos) = @_;

  _validate_number($chaos->{max_hooks}, 'chaos.max_hooks', 0, 0);
  if (ref $chaos->{actions} ne 'ARRAY') {
    croak "chaos.actions must be a list\n";
  }
  for my $action (@{$chaos->{actions}}) {
    if (!(defined $action && !ref $action && $LIFECYCLE_ACTION{$action})) {
      my $shown = defined $action && !ref $action ? $action : 'entry';
      croak "chaos.actions $shown is not a relay lifecycle action (restart, stop, start)\n";
    }
  }

  return 1;
}

sub _validate_provision_profile {
  my ($provision) = @_;

  for my $group (qw(workers relays)) {
    my $methods = $provision->{$group};
    if (ref $methods ne 'ARRAY') {
      croak "provision.$group must be a list\n";
    }
    for my $method (@{$methods}) {
      if (!(defined $method && !ref $method && $PROVISION_METHOD{$method})) {
        my $shown = defined $method && !ref $method ? $method : 'entry';
        croak "provision.$group $shown is not an implemented provisioning method (local)\n";
      }
    }
  }

  return 1;
}

sub generate {
  my ($class, %args) = @_;

  my $seed = $args{seed};
  if (!(defined $seed && !ref $seed && "$seed" =~ /\A-?\d+\z/mxs)) {
    croak "seed must be an integer\n";
  }
  my $profile = $class->load_profile_data($args{profile} || $class->default_profile);

  my $duration = _draw($seed, 'duration', $profile->{duration});
  my $relays   = _draw($seed, 'relays',   $profile->{relays});

  my $relay_profile = $profile->{relays};
  my $relay_config  = {
    count    => $relays,
    provider => $relay_profile->{provider},
  };
  if (exists $relay_profile->{endpoints}) {
    $relay_config->{endpoints} = [@{$relay_profile->{endpoints}}[0 .. $relays - 1]];
  }
  if (exists $relay_profile->{command}) {
    $relay_config->{command} = clone_json($relay_profile->{command});
  }

  my $scenario = {
    run      => {name   => "random-$seed", duration => $duration, seed => 0 + $seed},
    topology => {relays => $relay_config},
    workload =>
      {publish_rate_per_second => _draw($seed, 'publish_rate', $profile->{workload}{publish_rate_per_second})},
  };

  _generate_roles($scenario, $seed, $profile);
  _generate_reader_workload($scenario, $seed, $profile);
  _generate_abuse_workload($scenario, $seed, $profile);
  _generate_chaos($scenario, $seed, $profile, $duration, $relays);

  return $scenario;
}

sub _generate_roles {
  my ($scenario, $seed, $profile) = @_;

  for my $role (@HONEST_ROLES, sort keys %ABUSE_SINGULAR) {
    if (!exists $profile->{roles}{$role}) {
      next;
    }
    my $count = _draw($seed, "role:$role", $profile->{roles}{$role});
    if ($count == 0) {
      next;
    }
    $scenario->{topology}{$role} = {count => $count};
  }

  return 1;
}

sub _generate_reader_workload {
  my ($scenario, $seed, $profile) = @_;

  my $topology = $scenario->{topology};
  my $workload = $scenario->{workload};

  if ($topology->{subscribers}) {
    $workload->{subscription_filters} = [{kinds => [7800]}];
  }
  if ($topology->{query_readers}) {
    $workload->{query_filters}         = [{kinds => [7800], limit => 100}];
    $workload->{query_rate_per_second} = _draw($seed, 'query_rate', $profile->{workload}{query_rate_per_second});
  }
  if ($topology->{object_readers}) {
    $workload->{object_reads} = {
      rate_per_second => _draw($seed, 'object_rate', $profile->{workload}{object_read_rate_per_second}),
      objects         => [{type => 'chat.channel', id => 'irc:local:#overnet'}],
    };
  }

  return 1;
}

sub _generate_abuse_workload {
  my ($scenario, $seed, $profile) = @_;

  for my $role (sort keys %ABUSE_SINGULAR) {
    if (!$scenario->{topology}{$role}) {
      next;
    }
    my $singular = $ABUSE_SINGULAR{$role};
    $scenario->{workload}{abuse}{$singular} =
      {publish_rate_per_second => _draw($seed, "abuse_rate:$role", $profile->{workload}{abuse_publish_rate_per_second}),
      };
  }

  return 1;
}

sub _generate_chaos {
  my ($scenario, $seed, $profile, $duration, $relays) = @_;

  my $max_hooks = $profile->{chaos}{max_hooks};
  my @actions   = @{$profile->{chaos}{actions}};
  if ($max_hooks <= 0 || !@actions) {
    return 1;
  }

  my $count = _draw_int($seed, 'chaos_count', 0, $max_hooks);
  if ($count == 0) {
    return 1;
  }

  my @hooks;
  for my $index (1 .. $count) {
    my $at      = _draw_int($seed, "chaos:$index:at", 0, $duration - 1);
    my $action  = $actions[_draw_int($seed, "chaos:$index:action", 0, $#actions)];
    my $ordinal = _draw_int($seed, "chaos:$index:target", 1, $relays);
    push @hooks, {at => $at, action => $action, target => "relay:$ordinal"};
  }
  $scenario->{chaos} = \@hooks;

  return 1;
}

sub _draw {
  my ($seed, $label, $range) = @_;

  return _draw_int($seed, $label, $range->{min}, $range->{max});
}

sub _draw_int {
  my ($seed, $label, $low, $high) = @_;

  if ($high <= $low) {
    return $low;
  }
  my $separator = chr 0;
  my $hex       = sha256_hex(join $separator, 'overnet-burner:generate', $seed, $label);
  my $draw      = hex substr($hex, 0, 8);

  return $low + ($draw % ($high - $low + 1));
}

sub scenario_yaml {
  my ($class, $scenario) = @_;

  return YAML::PP->new(schema => ['Core'])->dump_string($scenario);
}

1;

=head1 NAME

Overnet::Burner::Generator - deterministic random scenario generation

=head1 DESCRIPTION

Generates a random-but-reproducible scenario within a declared profile
envelope. The generated document is an ordinary scenario that always passes
C<Overnet::Burner::Config> validation. See F<docs/generate.md>.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $scenario = Overnet::Burner::Generator->generate(seed => 42);
  print Overnet::Burner::Generator->scenario_yaml($scenario);

=head1 SUBROUTINES/METHODS

=head2 default_profile

Return the built-in default generation profile.

=head2 load_profile

Read, normalize, and validate a profile document from a file.

=head2 load_profile_data

Normalize and validate an in-memory profile mapping.

=head2 normalize_profile

Fill a partial profile with defaults, returning a complete profile.

=head2 validate_profile

Validate a normalized profile, croaking on malformed input.

=head2 generate

Generate a scenario deterministically from a seed and optional profile.

=head2 scenario_yaml

Serialize a generated scenario to YAML.

=head1 DIAGNOSTICS

Malformed profiles and inputs are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

No environment configuration is required.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Container and virtual provisioning, network chaos, and the provenance_forger
role are not generated; see F<docs/generate.md>.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
