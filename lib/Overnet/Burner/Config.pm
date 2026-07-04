package Overnet::Burner::Config;

use strictures 2;

use Carp    qw(croak);
use English qw(-no_match_vars);
use JSON    ();
use YAML::PP;

use Overnet::Burner::Hardware ();
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
    my $how = $copy->{provision}{$group}{how} || q{};
    if ($how eq 'container') {
      $copy->{provision}{$group}{engine}  ||= 'auto';
      $copy->{provision}{$group}{network} ||= 'host';
    }
    if (($how eq 'container' || $how eq 'virtual') && !exists $copy->{provision}{$group}{count}) {
      $copy->{provision}{$group}{count} = 1;
    }
  }

  return $copy;
}

sub _normalize_topology {
  my ($copy) = @_;

  $copy->{topology} ||= {};
  for my $role (
    qw(publishers subscribers query_readers object_readers observers
    flooders malformed_publishers replayers subscription_abusers sybils connection_floods
    provenance_forgers)
  ) {
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
  $copy->{workload}{abuse} ||= {};

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
    topology.flooders.count
    topology.malformed_publishers.count
    topology.replayers.count
    topology.subscription_abusers.count
    topology.sybils.count
    topology.connection_floods.count
    topology.provenance_forgers.count
    )
  ) {
    _require_nonnegative_integer($config, $path);
  }
  _require_hash($config, 'workload.observer');
  _require_positive_number($config, 'workload.observer.probe_interval_seconds');
  _validate_abuse_workload($config);

  _require_array($config, 'workload.subscription_filters');
  _require_array($config, 'workload.query_filters');
  _require_hash($config, 'workload.object_reads');
  _require_nonnegative_number($config, 'workload.object_reads.rate_per_second');
  _validate_object_read_references($config);
  _validate_worker_workload_dependencies($config);
  _validate_workload_phase($config, 'warmup');
  _validate_workload_phase($config, 'cooldown');

  # provision before chaos: network hooks are validated against the
  # provisioned worker group, whose fields must already be known-good
  _validate_provision($config);
  _validate_chaos($config);
  _validate_guest_reachable_endpoints($config);
  _require_hash($config, 'thresholds');

  return 1;
}

sub _validate_abuse_workload {
  my ($config) = @_;

  my $abuse = _require_hash($config, 'workload.abuse');
  my %known = map { $_ => 1 }
    qw(flooder malformed_publisher replayer subscription_abuser sybil connection_flood provenance_forger);

  for my $role (sort keys %{$abuse}) {
    if (!$known{$role}) {
      croak "workload.abuse.$role is not a known abuse role"
        . " (flooder, malformed_publisher, replayer, subscription_abuser, sybil, connection_flood,"
        . " provenance_forger)\n";
    }
    _require_mapping_ref($abuse->{$role}, "workload.abuse.$role");
    if (exists $abuse->{$role}{publish_rate_per_second}) {
      _require_nonnegative_number($config, "workload.abuse.$role.publish_rate_per_second");
    }
  }

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
    relays  => {local => 1, connect => 1},
    workers => {local => 1, connect => 1, container => 1, virtual => 1},
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
    if ($how eq 'virtual') {
      _validate_provision_virtual($config, $group);
    }
    if (exists $spec->{hardware}) {
      Overnet::Burner::Hardware::validate_requirements($spec->{hardware}, "provision.$group.hardware",
        construct => ($how eq 'virtual' ? 1 : 0),);
    }
  }

  return 1;
}

sub _validate_provision_virtual {
  my ($config, $group) = @_;

  my $path = "provision.$group";
  my $spec = _value_at($config, $path);

  my $image = $spec->{image};
  if (!(defined $image && !ref($image) && length $image)) {
    croak "$path.image is required for how: virtual\n";
  }
  _require_positive_integer($config, "$path.count");
  for my $key (qw(network engine)) {
    if (exists $spec->{$key}) {
      croak "$path.$key is only valid for how: container\n";
    }
  }

  return 1;
}

sub _validate_guest_reachable_endpoints {
  my ($config) = @_;

  my $workers = $config->{provision}{workers} || {};
  my $how     = $workers->{how}               || 'local';
  my $isolated =
    ($how eq 'container' && ($workers->{network} || q{}) eq 'bridge') || $how eq 'virtual';
  if (!$isolated) {
    return 1;
  }

  my $endpoints = $config->{topology}{relays}{endpoints};
  if (ref $endpoints ne 'ARRAY') {
    return 1;
  }
  for my $index (0 .. $#{$endpoints}) {
    my $endpoint = $endpoints->[$index];
    my ($host) = defined $endpoint && !ref $endpoint ? $endpoint =~ m{\Awss?://(\[[^\]]*\]|[^/:]+)}imxs : ();
    if (!defined $host) {
      next;
    }
    if ($host =~ /\A(?:127[.]|localhost\z|\[::1\]\z)/imxs) {
      croak "topology.relays.endpoints[$index] $endpoint is"
        . " not reachable from the provisioned worker guests (loopback is guest-local)\n";
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
  if ($network ne 'host' && $network ne 'bridge') {
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

  my %lifecycle   = map { $_ => 1 } qw(restart start stop);
  my %network     = map { $_ => 1 } qw(net-delay net-loss partition heal);
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
    if (!(defined $action && !ref($action) && ($lifecycle{$action} || $network{$action}))) {
      croak "chaos[$index].action must be one of restart, start, stop, net-delay, net-loss, partition, heal\n";
    }

    if ($network{$action}) {
      _validate_network_hook($config, $hook, $index);
      next;
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

sub _validate_network_hook {
  my ($config, $hook, $index) = @_;

  my $action  = $hook->{action};
  my $workers = $config->{provision}{workers} || {};
  if (!(($workers->{how} || q{}) eq 'container' && ($workers->{network} || q{}) eq 'bridge')) {
    croak "chaos[$index].action $action requires container-provisioned workers on a bridge network\n";
  }

  my $target = $hook->{target};
  my ($ordinal) =
    defined $target && !ref($target) ? $target =~ /\Aworker-guest:([1-9][0-9]*)\z/mxs : ();
  if (!defined $ordinal) {
    croak "chaos[$index].target must name a provisioned worker guest as worker-guest:<ordinal>\n";
  }
  my $count = $workers->{count} || 1;
  if ($ordinal > $count) {
    croak "chaos[$index].target must name a provisioned worker guest ($target of $count)\n";
  }

  _validate_network_hook_parameters($hook, $index);

  return 1;
}

sub _validate_network_hook_parameters {
  my ($hook, $index) = @_;

  my $action     = $hook->{action};
  my %parameters = (
    'net-delay' => {delay_ms     => 1, jitter_ms => 1},
    'net-loss'  => {loss_percent => 1},
    partition   => {},
    heal        => {},
  );
  for my $key (sort keys %{$hook}) {
    if ($key eq 'at' || $key eq 'action' || $key eq 'target') {
      next;
    }
    if (!$parameters{$action}{$key}) {
      croak "chaos[$index].$key is not a parameter of $action\n";
    }
  }

  if ($action eq 'net-delay') {
    _validate_netem_milliseconds($hook, $index, 'delay_ms');
    if (exists $hook->{jitter_ms}) {
      _validate_netem_milliseconds($hook, $index, 'jitter_ms');
    }
  }
  if ($action eq 'net-loss') {
    my $loss = $hook->{loss_percent};
    if ( ref $loss
      || !defined $loss
      || "$loss" !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/mxs
      || $loss <= 0
      || $loss > 100) {
      croak "chaos[$index].loss_percent must be a number greater than 0 and at most 100\n";
    }
  }

  return 1;
}

sub _validate_netem_milliseconds {
  my ($hook, $index, $field) = @_;

  my $value = $hook->{$field};
  if (ref $value || !defined $value || "$value" !~ /\A[1-9][0-9]*\z/mxs) {
    croak "chaos[$index].$field must be a positive integer\n";
  }

  return 1;
}

sub _validate_worker_workload_dependencies {
  my ($config) = @_;

  # Reader workers cannot run without the workload that tells them what to
  # read. A scenario that asks for the workers but omits the workload would
  # otherwise pass validation and only fail later at worker launch, so reject
  # the mismatch here where the operator can still see both sides of it.
  my @dependencies = (
    [subscribers    => 'workload.subscription_filters'],
    [query_readers  => 'workload.query_filters'],
    [object_readers => 'workload.object_reads.objects'],
  );

  for my $dependency (@dependencies) {
    my ($group, $path) = @{$dependency};
    my $count = $config->{topology}{$group}{count} || 0;
    if ($count <= 0) {
      next;
    }

    my $value = _value_at($config, $path);
    if (!(ref $value eq 'ARRAY' && @{$value})) {
      croak "topology.$group.count is $count but $path is empty;"
        . " declare $path or set topology.$group.count to 0\n";
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
