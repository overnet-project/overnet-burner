package Overnet::Burner::Adversary::Arena::Recorded;

use strictures 2;
use Moo;

use Carp qw(croak);

our $VERSION = '0.001';

has baseline_ref => (is => 'ro');
has responses    => (is => 'ro');

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  my $baseline_ref = defined $args{baseline_ref} ? $args{baseline_ref} : 'recorded';
  if (ref($baseline_ref)) {
    croak "baseline_ref must be a scalar\n";
  }

  my $responses = defined $args{responses} ? $args{responses} : [];
  if (ref($responses) ne 'ARRAY') {
    croak "responses must be an array reference\n";
  }
  for my $batch (@{$responses}) {
    if (ref($batch) ne 'ARRAY') {
      croak "each response batch must be an array reference\n";
    }
    for my $observation (@{$batch}) {
      if (
        !(
             ref($observation) eq 'HASH'
          && defined $observation->{type}
          && !ref($observation->{type})
          && length $observation->{type}
        )
      ) {
        croak "each recorded observation must be an object with a type\n";
      }
    }
  }

  return {baseline_ref => $baseline_ref, responses => $responses};
}

sub reset {    ## no critic (ProhibitBuiltinHomonyms)
  my ($self) = @_;
  $self->{_cursor} = 0;
  return;
}

sub apply {
  my ($self, $action) = @_;
  if (!(ref($action) eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
    croak "apply expects an action object with a type\n";
  }

  my $cursor = $self->{_cursor} || 0;
  my $batch  = $cursor <= $#{$self->responses} ? $self->responses->[$cursor] : [];
  $self->{_cursor} = $cursor + 1;

  return [map { _copy($_) } @{$batch}];
}

sub _copy {
  my ($value) = @_;
  if (ref($value) eq 'HASH') {
    return {map { $_ => _copy($value->{$_}) } keys %{$value}};
  }
  if (ref($value) eq 'ARRAY') {
    return [map { _copy($_) } @{$value}];
  }
  return $value;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Arena::Recorded - a replay arena backed by recorded observations

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $arena = Overnet::Burner::Adversary::Arena::Recorded->new(
    baseline_ref => 'catalog',
    responses    => [
      [ {type => 'relay_outcome', payload => {accepted => 0}} ],
      [ {type => 'observed_capability', payload => {...}} ],
    ],
  );
  $arena->reset;
  my $observations = $arena->apply({type => 'publish_control', payload => {...}});

=head1 DESCRIPTION

An arena is the system-under-test boundary the runner drives: it accepts one
action and returns the observations that action produced. An arena is any
object with C<baseline_ref>, C<reset>, and C<apply> methods.

This recorded arena replays a fixed, positionally-aligned list of observation
batches: the first C<apply> returns the first batch, the second returns the
second, and so on. Once the recorded batches are exhausted, further C<apply>
calls return an empty observation list. It is the deterministic double a live
arena stands in for, and the substrate of the regression corpus: an attack's
transcript replays byte-for-byte without any live system under test.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a recorded arena. Takes an optional C<baseline_ref> (default
C<recorded>) and an optional C<responses> array reference of observation
batches (each an array reference of observation objects).

=head2 baseline_ref

Returns the opaque baseline reference the arena resets to.

=head2 reset

Rewinds the replay cursor to the first recorded batch.

=head2 apply

Takes one action object and returns the next recorded observation batch as an
array reference, advancing the cursor. Returns an empty list once the recorded
batches are exhausted.

=head1 DIAGNOSTICS

Invalid constructor arguments and malformed actions are reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Moo>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
