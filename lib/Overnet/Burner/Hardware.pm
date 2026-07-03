package Overnet::Burner::Hardware;

use strictures 2;

use Carp     qw(croak);
use Exporter qw(import);
use POSIX    qw(ceil uname);

our $VERSION   = '0.001';
our @EXPORT_OK = qw(
  host_architecture
  requirement_minimums
  validate_requirements
);

my %MEMORY_UNIT_MB = (
  MB  => 1_000_000 / 1_048_576,
  MiB => 1,
  GB  => 1_000_000_000 / 1_048_576,
  GiB => 1024,
);

sub host_architecture {
  return (uname())[4];
}

sub validate_requirements {
  my ($hardware, $path, %options) = @_;

  if (ref $hardware ne 'HASH') {
    croak "$path must be a mapping\n";
  }
  if (exists $hardware->{and} || exists $hardware->{or}) {
    croak "$path and/or groups are not implemented yet\n";
  }
  for my $key (sort keys %{$hardware}) {
    if ($key eq 'arch') {
      _validate_arch($hardware->{arch}, $path, $options{construct});
    } elsif ($key eq 'memory') {
      _parse_memory($hardware->{memory}, $path);
    } elsif ($key eq 'cpu') {
      _validate_cpu($hardware->{cpu}, $path);
    } else {
      croak "$path.$key is not an implemented hardware requirement (arch, memory, cpu.cores)\n";
    }
  }

  return 1;
}

sub requirement_minimums {
  my ($hardware) = @_;

  if (ref $hardware ne 'HASH') {
    return;
  }

  my %minimums;
  if (exists $hardware->{memory}) {
    $minimums{memory_mb} = _parse_memory($hardware->{memory}, 'hardware');
  }
  if (ref $hardware->{cpu} eq 'HASH' && exists $hardware->{cpu}{cores}) {
    $minimums{cpus} = _parse_cores($hardware->{cpu}{cores}, 'hardware');
  }

  return %minimums;
}

sub _validate_arch {
  my ($value, $path, $construct) = @_;

  if (ref $value || !defined $value || !length $value) {
    croak "$path.arch must be a non-empty string\n";
  }

  # Only a group that CONSTRUCTS guests is bound to the controller's
  # architecture; attached groups may truthfully declare what their
  # existing guests are.
  if (!$construct) {
    return 1;
  }
  my $host = host_architecture();
  if ($value ne $host) {
    croak "$path.arch $value does not match the host architecture $host"
      . " (only host-architecture guests are implemented)\n";
  }

  return 1;
}

sub _validate_cpu {
  my ($cpu, $path) = @_;

  if (ref $cpu ne 'HASH') {
    croak "$path.cpu must be a mapping\n";
  }
  for my $key (sort keys %{$cpu}) {
    if ($key ne 'cores') {
      croak "$path.cpu.$key is not an implemented hardware requirement (arch, memory, cpu.cores)\n";
    }
  }
  if (exists $cpu->{cores}) {
    _parse_cores($cpu->{cores}, $path);
  }

  return 1;
}

sub _parse_memory {
  my ($value, $path) = @_;

  my (undef, $number, $unit) = _parse_comparison($value, "$path.memory");
  if (!(defined $unit && exists $MEMORY_UNIT_MB{$unit})) {
    croak "$path.memory must include a unit (MB, MiB, GB, GiB)\n";
  }
  if ($number <= 0) {
    croak "$path.memory must be positive\n";
  }

  return ceil($number * $MEMORY_UNIT_MB{$unit});
}

sub _parse_cores {
  my ($value, $path) = @_;

  my (undef, $number, $unit) = _parse_comparison($value, "$path.cpu.cores");
  if (defined $unit || $number != int $number || $number < 1) {
    croak "$path.cpu.cores must be a positive integer\n";
  }

  return int $number;
}

sub _parse_comparison {
  my ($value, $path) = @_;

  if (ref $value || !defined $value) {
    croak "$path must be a number or a comparison like \">= 4\"\n";
  }
  my ($operator, $rest) = "$value" =~ /\A\s*(>=|<=|!=|=~|=|>|<)?\s*(.*?)\s*\z/mxs;
  my ($number,   $unit) = $rest    =~ /\A([0-9]+(?:[.][0-9]+)?)(?:\s*([A-Za-z]+))?\z/mxs;
  if (!defined $number) {
    croak "$path must be a number or a comparison like \">= 4\"\n";
  }
  if (defined $operator && length $operator && $operator ne q{=} && $operator ne q{>=}) {
    croak "$path operator $operator is not implemented yet (=, >=)\n";
  }

  return ($operator, $number, $unit);
}

1;

=head1 NAME

Overnet::Burner::Hardware - declarative hardware requirements (v1 subset)

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Hardware qw(requirement_minimums validate_requirements);

  validate_requirements($spec->{hardware}, 'provision.workers.hardware');
  my %minimums = requirement_minimums($spec->{hardware});

=head1 DESCRIPTION

Implements the decided v1 subset of the tmt-shaped hardware requirement
grammar from F<docs/provisioning.md>: the keys C<arch>, C<memory>, and
C<cpu.cores>, with values that are a plain number or a single C<=> /
C<< >= >> comparison. Memory values require a unit (C<MB>, C<MiB>, C<GB>,
C<GiB>) and convert upward to whole mebibytes so a guest constructed from
the minimum never has less than the requirement. The rest of the grammar -
C<and>/C<or> groups and the remaining comparison operators - is recognized
and rejected as not implemented yet, never misread. C<arch> must match the
host architecture because only host-architecture guests are constructed.

=head1 SUBROUTINES/METHODS

=head2 host_architecture

=head2 validate_requirements

=head2 requirement_minimums

Returns a hash with C<memory_mb> and C<cpus> minimums for the requirement
keys that are present; an empty hash when nothing is declared.

=head1 DIAGNOSTICS

Invalid or reserved requirement syntax is reported through exceptions
naming the offending field.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Comparison values are minimums: C<< memory: ">= 8 GB" >> constructs an
8 GB guest rather than searching an inventory for a bigger one.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
