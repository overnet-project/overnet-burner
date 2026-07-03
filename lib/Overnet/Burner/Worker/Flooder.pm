package Overnet::Burner::Worker::Flooder;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

use JSON        ();
use Time::HiRes qw(time);

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

no Moo;

sub expected_role {
  return 'flooder';
}

sub abuse_operation {
  return 'flood_publish';
}

sub default_rate {
  return 1000;
}

sub build_event {
  my ($self, $key, $sequence) = @_;

  return $key->create_event(
    kind    => 7800,
    content => $JSON->encode(
      {
        provenance => {type => 'native'},
        body       => {text => "overnet-burner flood $sequence", sequence => $sequence, sent_at => time * 1000},
      }
    ),
    tags => [
      ['overnet_v',   '0.1.0'],
      ['overnet_et',  'burner.publish'],
      ['overnet_ot',  'burner.workload'],
      ['overnet_oid', "burner-$self->{input}{run_id}-$self->{input}{worker_id}"],
      ['v',           '0.1.0'],
      ['t',           'burner.publish'],
      ['o',           'burner.workload'],
    ],
  );
}

1;

=head1 NAME

Overnet::Burner::Worker::Flooder - volume-abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::Flooder;

  Overnet::Burner::Worker::Flooder->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<flooder> abuse role under the
contract in F<docs/abuse.md>. It publishes structurally valid native
Overnet events far above any plausible rate limit and measures how the
relay responds: a rejection or limit is a defense (correct when the relay
uses a resource-protection category such as C<rate-limited:>), and an
accepted flood event is a defense failure. The abuse is the volume, not the
events, so every event it sends is valid.

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 build_event

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a throttled or rejected flood
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
