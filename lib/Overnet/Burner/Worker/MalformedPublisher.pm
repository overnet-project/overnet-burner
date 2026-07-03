package Overnet::Burner::Worker::MalformedPublisher;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

use JSON        ();
use Time::HiRes qw(time);

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

# A syntactically valid but cryptographically wrong signature: correct
# length and alphabet, so it reaches the relay's signature check rather than
# a parser, and fails there.
my $BAD_SIGNATURE = '0' x 128;

no Moo;

sub expected_role {
  return 'malformed_publisher';
}

sub abuse_operation {
  return 'malformed_publish';
}

sub default_rate {
  return 5;
}

sub build_event {
  my ($self, $key, $sequence) = @_;

  my $event = $key->create_event(
    kind    => 7800,
    content => $JSON->encode(
      {
        provenance => {type => 'native'},
        body       => {text => "overnet-burner malformed $sequence", sequence => $sequence, sent_at => time * 1000},
      }
    ),
    tags => [['overnet_v', '0.1.0'], ['overnet_et', 'burner.publish'], ['v', '0.1.0'], ['t', 'burner.publish']],
  );

  # The id is computed from the signed fields and is unchanged; only the
  # signature is corrupted, so the event stays well-formed JSON and a
  # conformant relay must reject it as invalid input rather than accept it.
  $event->sig($BAD_SIGNATURE);

  return $event;
}

1;

=head1 NAME

Overnet::Burner::Worker::MalformedPublisher - invalid-input abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::MalformedPublisher;

  Overnet::Burner::Worker::MalformedPublisher->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<malformed_publisher> abuse role
under the contract in F<docs/abuse.md>. It submits events with a corrupted
signature - well-formed JSON that reaches and fails the relay's signature
verification - and measures the response: a conformant relay rejects them as
invalid input (the correct defense), while accepting a malformed event, or
rejecting it as an internal failure, is a defense gap the metric records.

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 build_event

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a rejected malformed event is a
metric event, not a worker failure.

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
