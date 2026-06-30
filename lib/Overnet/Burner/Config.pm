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

  $copy->{topology}                 ||= {};
  $copy->{topology}{publishers}     ||= {};
  $copy->{topology}{subscribers}    ||= {};
  $copy->{topology}{query_readers}  ||= {};
  $copy->{topology}{object_readers} ||= {};

  for my $role (qw(publishers subscribers query_readers object_readers)) {
    if (!exists $copy->{topology}{$role}{count}) {
      $copy->{topology}{$role}{count} = 0;
    }
  }

  $copy->{workload}                       ||= {};
  $copy->{workload}{subscription_filters} ||= [];
  $copy->{workload}{query_filters}        ||= [];
  $copy->{workload}{object_reads}         ||= {};
  $copy->{chaos}                          ||= [];
  $copy->{thresholds}                     ||= {};

  return $copy;
}

sub validate {
  my ($class, $config) = @_;

  _require_string($config, 'run.name');
  _require_positive_integer($config, 'run.duration');
  _require_integer($config, 'run.seed');
  _require_positive_integer($config, 'topology.relays.count');
  _require_string($config, 'topology.relays.provider');
  Overnet::Burner::TopologyProvider->from_relay_config($config->{topology}{relays},);
  _require_nonnegative_number($config, 'workload.publish_rate_per_second');

  for my $path (
    qw(
    topology.publishers.count
    topology.subscribers.count
    topology.query_readers.count
    topology.object_readers.count
    )
  ) {
    _require_nonnegative_integer($config, $path);
  }

  _require_array($config, 'workload.subscription_filters');
  _require_array($config, 'workload.query_filters');
  _require_hash($config, 'workload.object_reads');
  _require_array_of_mappings($config, 'chaos');
  _require_hash($config, 'thresholds');

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
