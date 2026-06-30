package Overnet::Burner::TopologyProvider;

use strictures 2;

use Carp qw(croak);
use JSON ();

use Overnet::Burner::Util qw(clone_json);

our $VERSION = '0.001';

my %SUPPORTED_PROVIDER = map { $_ => 1 } qw(generic-relay external-command);

sub from_relay_config {
  my ($class, $relays, %args) = @_;

  my $path = $args{path} || 'topology.relays';
  _require_mapping_ref($relays, $path);

  my $name = _require_member_string($relays, 'provider', "$path.provider");
  if (!$SUPPORTED_PROVIDER{$name}) {
    croak "unknown topology provider: $name\n";
  }

  my $provider = {name => $name,};

  if ($name eq 'external-command') {
    my $command = _require_member_mapping($relays, 'command', "$path.command");
    $provider->{command} = {
      health => _require_member_string($command, 'health', "$path.command.health"),
      start  => _require_member_string($command, 'start',  "$path.command.start"),
      stop   => _require_member_string($command, 'stop',   "$path.command.stop"),
    };
  }

  return _clone($provider);
}

sub relay_actor_descriptor {
  my ($class, $provider) = @_;

  my $descriptor = {};
  if (exists $provider->{command}) {
    $descriptor->{command} = _clone($provider->{command});
  }

  return $descriptor;
}

sub _require_member_mapping {
  my ($mapping, $key, $path) = @_;
  my $value = _required_member($mapping, $key, $path);
  _require_mapping_ref($value, $path);
  return $value;
}

sub _require_member_string {
  my ($mapping, $key, $path) = @_;
  my $value = _required_member($mapping, $key, $path);
  if (ref $value || !defined $value || $value eq q{}) {
    croak "invalid field: $path must be a non-empty string\n";
  }
  return $value;
}

sub _required_member {
  my ($mapping, $key, $path) = @_;

  if (!(ref $mapping eq 'HASH' && exists $mapping->{$key})) {
    croak "missing required field: $path\n";
  }

  return $mapping->{$key};
}

sub _require_mapping_ref {
  my ($value, $path) = @_;

  if (ref $value ne 'HASH') {
    croak "invalid field: $path must be a mapping\n";
  }
  return $value;
}

sub _clone {
  my ($value) = @_;

  return clone_json($value);
}

1;

=head1 NAME

Overnet::Burner::TopologyProvider - topology provider descriptors

=head1 DESCRIPTION

Normalizes topology provider configuration used by execution plans and Rex bundles.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $provider = Overnet::Burner::TopologyProvider->from_relay_config($relays);

=head1 SUBROUTINES/METHODS

=head2 from_relay_config

=head2 relay_actor_descriptor

=head1 DIAGNOSTICS

Invalid provider configuration is reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration is supplied by scenario topology data.

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
