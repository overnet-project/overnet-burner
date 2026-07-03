package Overnet::Burner::Config;

use strictures 2;

use Carp    qw(croak);
use English qw(-no_match_vars);
use JSON    ();
use YAML::PP;

use Overnet::Burner::TopologyProvider;
use Overnet::Burner::Util qw(clone_json json_text read_file);

our $VERSION = '0.001';

sub load_file {
  my ($class, $path) = @_;

  my $text = read_file($path);

  my $config;
  my $loaded = eval {
    $config = YAML::PP->new(boolean => 'perl', schema => ['Core'],)->load_string($text);
    1;
  };
  if (!$loaded) {
    croak "$path: $EVAL_ERROR";
  }

  if (!defined $config) {
    $config = {};
  }
  $config = $class->normalize($config);
  $class->validate($config);

  return $config;
}

sub normalize {
  my ($class, $config) = @_;

  my $copy = clone_json($config);

  _require_mapping_ref($copy, 'root');
  _require_optional_mapping($copy, 'run');
  _require_optional_mapping($copy, 'topology');
  _require_optional_mapping($copy, 'workload');
  _require_optional_mapping($copy, 'thresholds');
  _require_optional_mapping($copy, 'workload.object_reads');

  _normalize_topology($copy);
  _normalize_workload($copy);

  $copy->{chaos}      ||= [];
  $copy->{thresholds} ||= {};

  $copy->{provision} ||= {};
  for my $group (qw(relays workers)) {
    $copy->{provision}{$group} ||= {};
    if (!exists $copy->{provision}{$group}{how}) {
      $copy->{provision}{$group}{how} = 'local';
    }
    if (($copy->{provision}{$group}{how} || q{}) eq 'container') {
      $copy->{provision}{$group}{engine}  ||= 'auto';
      $copy->{provision}{$group}{count}   ||= 1;
      $copy->{provision}{$group}{network} ||= 'host';
    }
  }

  return $copy;
}

sub _normalize_topology {
  my ($copy) = @_;

  $copy->{topology} ||= {};
  for my $role (qw(publishers subscribers query_readers object_readers observers)) {
    $copy->{topology}{$role} ||= {};
    if (!exists $copy->{topology}{$role}{count}) {
      $copy->{topology}{$role}{count} = 0;
    }
  }

  return 1;
}

sub _normalize_workload {
  my ($copy) = @_;

  $copy->{workload}                        ||= {};
  $copy->{workload}{subscription_filters}  ||= [];
  $copy->{workload}{query_filters}         ||= [];
  $copy->{workload}{object_reads}          ||= {};
  $copy->{workload}{object_reads}{objects} ||= [];
  if (!exists $copy->{workload}{query_rate_per_second}) {
    $copy->{workload}{query_rate_per_second} = 1;
  }
  if (!exists $copy->{workload}{object_reads}{rate_per_second}) {
    $copy->{workload}{object_reads}{rate_per_second} = 1;
  }
  $copy->{workload}{observer} ||= {};
  if (!exists $copy->{workload}{observer}{probe_interval_seconds}) {
    $copy->{workload}{observer}{probe_interval_seconds} = 1;
  }

  return 1;
}

sub validate {
  my ($class, $config) = @_;

  _require_string($config, 'run.name');
  _require_positive_integer($config, 'run.duration');
  _require_integer($config, 'run.seed');
  _require_positive_integer($config, 'topology.relays.count');
  _require_string($config, 'topology.relays.provider');
  Overnet::Burner::TopologyProvider->from_relay_config($config->{topology}{relays},);
  _validate_relay_endpoints($config);
  _require_nonnegative_number($config, 'workload.publish_rate_per_second');
  _require_nonnegative_number($config, 'workload.query_rate_per_second');

  for my $path (
    qw(
    topology.publishers.count
    topology.subscribers.count
    topology.query_readers.count
    topology.object_readers.count
    topology.observers.count
    )
  ) {
    _require_nonnegative_integer($config, $path);
  }
  _require_hash($config, 'workload.observer');
  _require_positive_number($config, 'workload.observer.probe_interval_seconds');

  _require_array($config, 'workload.subscription_filters');
  _require_array($config, 'workload.query_filters');
  _require_hash($config, 'workload.object_reads');
  _require_nonnegative_number($config, 'workload.object_reads.rate_per_second');
  _validate_object_read_references($config);
  _validate_workload_phase($config, 'warmup');
  _validate_workload_phase($config, 'cooldown');
  _validate_chaos($config);
  _validate_provision($config);
  _require_hash($config, 'thresholds');

  return 1;
}

sub _validate_provision {
  my ($config) = @_;

  my $provision = _require_hash($config, 'provision');
  my %known     = map { $_ => 1 } qw(relays workers);
  for my $group (sort keys %{$provision}) {
    if (!$known{$group}) {
      croak "provision groups must be relays or workers, not $group\n";
    }
  }

  my %implemented = (
    relays  => {local => 1},
    workers => {local => 1, connect => 1, container => 1},
  );
  my %designed = map { $_ => 1 } qw(local connect container virtual);

  for my $group (qw(relays workers)) {
    my $spec = _require_hash($config, "provision.$group");
    my $how  = $spec->{how};
    if (!(defined $how && !ref($how) && $designed{$how})) {
      croak "provision.$group.how must be one of connect, container, local, virtual\n";
    }
    if (!$implemented{$group}{$how}) {
      croak "provision.$group.how $how is not implemented yet\n";
    }

    if (exists $spec->{worker}) {
      my $worker = $spec->{worker};
      if (!(defined $worker && !ref($worker) && length $worker)) {
        croak "provision.$group.worker must be a non-empty string\n";
      }
    }

    if ($how eq 'connect') {
      _validate_provision_guests($config, $group);
    } elsif (exists $spec->{guests}) {
      croak "provision.$group.guests is only valid for how: connect\n";
    }

    if ($how eq 'container') {
      _validate_provision_container($config, $group);
    }
  }

  return 1;
}

sub _validate_provision_container {
  my ($config, $group) = @_;

  my $path = "provision.$group";
  my $spec = _value_at($config, $path);

  my $image = $spec->{image};
  if (!(defined $image && !ref($image) && length $image)) {
    croak "$path.image is required for how: container\n";
  }

  my %engines = map { $_ => 1 } qw(auto docker podman);
  my $engine  = $spec->{engine};
  if (!(defined $engine && !ref($engine) && $engines{$engine})) {
    croak "$path.engine must be one of auto, docker, podman\n";
  }

  _require_positive_integer($config, "$path.count");

  my $network = $spec->{network};
  if (!(defined $network && !ref($network) && length $network)) {
    croak "$path.network must be a non-empty string\n";
  }
  if ($network ne 'host') {
    croak "$path.network $network is not implemented yet for worker guests\n";
  }

  return 1;
}

sub _validate_provision_guests {
  my ($config, $group) = @_;

  my $path   = "provision.$group.guests";
  my $guests = _value_at($config, $path);
  if (!(ref $guests eq 'ARRAY' && @{$guests})) {
    croak "$path must list at least one guest\n";
  }

  for my $index (0 .. $#{$guests}) {
    _require_mapping_ref($guests->[$index], "$path\[$index\]");
    my $address = $guests->[$index]{address};
    if (!(defined $address && !ref($address) && length $address)) {
      croak "$path\[$index\].address must be a non-empty string\n";
    }
    for my $field (qw(user key)) {
      my $value = $guests->[$index]{$field};
      if (exists $guests->[$index]{$field} && !(defined $value && !ref($value) && length $value)) {
        croak "$path\[$index\].$field must be a non-empty string\n";
      }
    }
    if (exists $guests->[$index]{port}) {
      my $port = $guests->[$index]{port};
      if (ref $port || !defined $port || "$port" !~ /\A[1-9][0-9]*\z/mxs) {
        croak "$path\[$index\].port must be a positive integer\n";
      }
    }
  }

  return 1;
}

sub _validate_workload_phase {
  my ($config, $name) = @_;

  my $path  = "workload.$name";
  my $phase = _value_at($config, $path);
  if (!defined $phase) {
    return 1;
  }

  _require_mapping_ref($phase, $path);
  _require_positive_integer($config, "$path.duration");
  for my $rate (qw(publish_rate_per_second query_rate_per_second)) {
    if (exists $phase->{$rate}) {
      _require_nonnegative_number($config, "$path.$rate");
    }
  }
  if (exists $phase->{object_reads}) {
    _require_mapping_ref($phase->{object_reads}, "$path.object_reads");
    if (exists $phase->{object_reads}{rate_per_second}) {
      _require_nonnegative_number($config, "$path.object_reads.rate_per_second");
    }
  }

  return 1;
}

sub _total_duration {
  my ($config) = @_;

  my $total = $config->{run}{duration};
  for my $name (qw(warmup cooldown)) {
    my $phase = _value_at($config, "workload.$name");
    if (ref $phase eq 'HASH' && defined $phase->{duration}) {
      $total += $phase->{duration};
    }
  }

  return $total;
}

sub _validate_chaos {
  my ($config) = @_;

  my %actions     = map { $_ => 1 } qw(restart start stop);
  my %reserved    = map { $_ => 1 } qw(net-delay net-loss partition heal);
  my $duration    = _total_duration($config);
  my $relay_count = $config->{topology}{relays}{count};
  my $hooks       = _require_array_of_mappings($config, 'chaos');

  for my $index (0 .. $#{$hooks}) {
    my $hook = $hooks->[$index];

    my $at = $hook->{at};
    if (ref $at || !defined $at || "$at" !~ /\A\d+\z/mxs) {
      croak "chaos[$index].at must be a non-negative integer\n";
    }
    if ($at >= $duration) {
      croak "chaos[$index].at must be inside the run duration (0 <= at < $duration)\n";
    }

    my $action = $hook->{action};
    if (defined $action && !ref($action) && $reserved{$action}) {
      croak "chaos[$index].action $action is reserved for a future version\n";
    }
    if (!(defined $action && !ref($action) && $actions{$action})) {
      croak "chaos[$index].action must be one of restart, start, stop\n";
    }

    my $target = $hook->{target};
    my ($ordinal) =
      defined $target && !ref($target) ? $target =~ /\Arelay:([1-9][0-9]*)\z/mxs : ();
    if (!defined $ordinal) {
      croak "chaos[$index].target must name a configured relay as relay:<ordinal>\n";
    }
    if ($ordinal > $relay_count) {
      croak "chaos[$index].target must name a configured relay ($target of $relay_count)\n";
    }
  }

  return 1;
}

sub _validate_object_read_references {
  my ($config) = @_;

  my $objects = _require_array_of_mappings($config, 'workload.object_reads.objects');
  for my $index (0 .. $#{$objects}) {
    for my $field (qw(type id)) {
      my $value = $objects->[$index]{$field};
      if (!(defined $value && !ref($value) && length $value)) {
        croak "workload.object_reads.objects[$index].$field must be a non-empty string\n";
      }
    }
  }

  return 1;
}

sub normalized_json {
  my ($class, $config) = @_;

  return json_text($class->normalize($config));
}

sub _require_hash {
  my ($config, $path) = @_;
  my $value = _required_value($config, $path);
  _require_mapping_ref($value, $path);
  return $value;
}

sub _require_optional_mapping {
  my ($config, $path) = @_;
  my $value = _value_at($config, $path);

  if (!defined $value) {
    return;
  }

  _require_mapping_ref($value, $path);
  return $value;
}

sub _require_mapping_ref {
  my ($value, $path) = @_;

  if (ref $value ne 'HASH') {
    croak "invalid field: $path must be a mapping\n";
  }
  return $value;
}

sub _require_array {
  my ($config, $path) = @_;
  my $value = _required_value($config, $path);
  if (ref $value ne 'ARRAY') {
    croak "invalid field: $path must be an array\n";
  }
  return $value;
}

sub _require_array_of_mappings {
  my ($config, $path) = @_;
  my $value = _require_array($config, $path);
  my $index = 0;

  for my $item (@{$value}) {
    _require_mapping_ref($item, "$path\[$index\]");
    $index++;
  }

  return $value;
}

sub _validate_relay_endpoints {
  my ($config) = @_;

  my $relays = $config->{topology}{relays};
  if (!exists $relays->{endpoints}) {
    return 1;
  }

  my $endpoints = $relays->{endpoints};
  if (ref($endpoints) ne 'ARRAY') {
    croak "topology.relays.endpoints must be an array\n";
  }
  for my $index (0 .. $#{$endpoints}) {
    my $endpoint = $endpoints->[$index];
    if (!(defined $endpoint && !ref($endpoint) && length $endpoint)) {
      croak "topology.relays.endpoints[$index] must be a non-empty string\n";
    }
  }
  if (@{$endpoints} != $relays->{count}) {
    croak "topology.relays.endpoints must list one endpoint per relay\n";
  }

  return 1;
}

sub _require_string {
  my ($config, $path) = @_;
  my $value = _required_value($config, $path);
  if (ref $value || !defined $value || $value eq q{}) {
    croak "invalid field: $path must be a non-empty string\n";
  }
  return $value;
}

sub _require_integer {
  my ($config, $path) = @_;
  my $value = _required_value($config, $path);
  if (ref $value || !defined $value || "$value" !~ /^-?\d+\z/mxs) {
    croak "invalid field: $path must be an integer\n";
  }
  return $value;
}

sub _require_positive_integer {
  my ($config, $path) = @_;
  my $value = _require_integer($config, $path);
  if (!($value > 0)) {
    croak "invalid field: $path must be positive\n";
  }
  return $value;
}

sub _require_nonnegative_integer {
  my ($config, $path) = @_;
  my $value = _require_integer($config, $path);
  if (!($value >= 0)) {
    croak "invalid field: $path must be non-negative\n";
  }
  return $value;
}

sub _require_positive_number {
  my ($config, $path) = @_;
  my $value = _require_nonnegative_number($config, $path);
  if (!($value > 0)) {
    croak "invalid field: $path must be positive\n";
  }
  return $value;
}

sub _require_nonnegative_number {
  my ($config, $path) = @_;
  my $value = _required_value($config, $path);
  if ( ref $value
    || !defined $value
    || "$value" !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)\z/mxs
    || $value < 0) {
    croak "invalid field: $path must be a non-negative number\n";
  }
  return $value;
}

sub _required_value {
  my ($config, $path) = @_;
  my $value = _value_at($config, $path);
  if (!defined $value) {
    croak "missing required field: $path\n";
  }
  return $value;
}

sub _value_at {
  my ($config, $path) = @_;
  my $value = $config;

  for my $part (split /\./mxs, $path) {
    if (ref $value ne 'HASH') {
      return;
    }
    if (!exists $value->{$part}) {
      return;
    }
    $value = $value->{$part};
  }

  return $value;
}

1;

=head1 NAME

Overnet::Burner::Config - scenario configuration loading and validation

=head1 DESCRIPTION

Loads, normalizes, validates, and serializes overnet-burner scenario configuration.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $scenario = Overnet::Burner::Config->load_file($path);

=head1 SUBROUTINES/METHODS

=head2 load_file

=head2 normalize

=head2 validate

=head2 normalized_json

=head1 DIAGNOSTICS

Invalid scenario input is reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration is supplied as scenario YAML.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
