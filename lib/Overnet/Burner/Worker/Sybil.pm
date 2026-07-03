package Overnet::Burner::Worker::Sybil;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

our $VERSION = '0.001';

no Moo;

sub expected_role {
  return 'sybil';
}

sub abuse_operation {
  return 'sybil_publish';
}

sub default_rate {
  return 50;
}

sub build_event {
  my ($self, $key, $sequence) = @_;

  # A fresh, deterministic identity per event: the abuse is identity churn,
  # so each publish comes from a different pubkey. The worker's own key is
  # ignored.
  my $input    = $self->input;
  my $identity = $self->derive_key($input->{seed}, "$input->{worker_id}-sybil-$sequence");

  return $self->native_event($identity, $sequence, "overnet-burner sybil $sequence");
}

1;

=head1 NAME

Overnet::Burner::Worker::Sybil - identity-churn abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::Sybil;

  Overnet::Burner::Worker::Sybil->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<sybil> abuse role under the
contract in F<docs/abuse.md>. It publishes structurally valid events, each
from a fresh deterministic identity, to measure whether identity churn
evades the relay's limits. Its per-event defense model is the flooder's: a
rejection is a defense, correct when the relay uses a resource-protection
category. The sybil-specific question - does churning identities *evade* a
limit - is read comparatively, from the sybil worker's defended ratio
against a flooder's under the same relay: a per-connection or per-IP limit
resists churn (similar ratios), while a per-identity limit does not (a
lower sybil ratio).

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 build_event

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a rejected or limited publish
is a metric event, not a worker failure.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration arrives through the worker input document; see
F<docs/workers.md> and F<docs/abuse.md>.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
