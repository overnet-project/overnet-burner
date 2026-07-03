package Overnet::Burner::Worker::Replayer;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

use JSON        ();
use Time::HiRes qw(time);

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

no Moo;

sub expected_role {
  return 'replayer';
}

sub abuse_operation {
  return 'replay_submit';
}

sub default_rate {
  return 5;
}

sub build_event {
  my ($self, $key, $sequence) = @_;

  return $key->create_event(
    kind    => 7800,
    content => $JSON->encode(
      {
        provenance => {type => 'native'},
        body       => {text => "overnet-burner replay seed", sequence => 0, sent_at => time * 1000},
      }
    ),
    tags => [['overnet_v', '0.1.0'], ['overnet_et', 'burner.publish'], ['v', '0.1.0'], ['t', 'burner.publish']],
  );
}

sub perform_abuse {
  my ($self, %args) = @_;

  my $captured = $self->_captured_event(%args);

  return $self->publish_event($args{client}, $captured, $args{pending});
}

sub _captured_event {
  my ($self, %args) = @_;

  if (!$self->{captured_event}) {
    my $seed = $self->build_event($args{key}, $args{sequence});

    # Seed the relay with one genuine event, unmeasured: the replay abuse is
    # resubmitting an event the relay already accepted.
    $self->publish_event($args{client}, $seed, $args{pending});
    $self->{captured_event} = $seed;
  }

  return $self->{captured_event};
}

1;

=head1 NAME

Overnet::Burner::Worker::Replayer - replay-abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::Replayer;

  Overnet::Burner::Worker::Replayer->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<replayer> abuse role under the
contract in F<docs/abuse.md>. It publishes one genuine event to seed the
relay, then repeatedly resubmits that exact event and measures whether the
relay handles the replay idempotently: an explicit C<duplicate:>
acknowledgement or a rejection is a defense, while silently accepting the
replay as a fresh event is a defense failure the metric records.

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 build_event

=head2 perform_abuse

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a deduplicated or rejected
replay is a metric event, not a worker failure.

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
