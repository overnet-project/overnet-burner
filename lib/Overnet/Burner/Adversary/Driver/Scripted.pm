package Overnet::Burner::Adversary::Driver::Scripted;

use strictures 2;
use Moo;

use Carp qw(croak);

our $VERSION = '0.001';

has actions => (is => 'ro', required => 1);

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  my $actions = $args{actions};
  if (ref($actions) ne 'ARRAY') {
    croak "actions must be an array reference\n";
  }
  for my $action (@{$actions}) {
    if (!(ref($action) eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
      croak "each scripted action must be an object with a type\n";
    }
  }

  return {actions => $actions};
}

sub next_actions {
  my ($self, $session) = @_;
  if ($self->{_emitted}) {
    return [];
  }
  $self->{_emitted} = 1;
  return [map { _copy($_) } @{$self->actions}];
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

Overnet::Burner::Adversary::Driver::Scripted - a driver that emits a fixed action sequence

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $driver = Overnet::Burner::Adversary::Driver::Scripted->new(
    actions => [ {type => 'publish_control', payload => {...}} ],
  );

=head1 DESCRIPTION

The simplest driver: it emits one fixed list of actions and then stops. A
driver is any object with a C<next_actions> method that takes the current
session and returns an array reference of actions (each an object with a
C<type> and optional C<payload>), or an empty list to end the session. The
runner does not care how a driver decides; a scripted driver replays a fixed
plan, while an adaptive driver would inspect the session's observations.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a scripted driver. Requires C<actions>, an array reference of action
objects.

=head2 next_actions

Returns the full action list on the first call and an empty list thereafter.
Takes the current session (ignored by this driver).

=head1 DIAGNOSTICS

Invalid actions are reported with C<croak>.

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
