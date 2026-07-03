package Overnet::Burner::Worker::ProvenanceForger;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

use JSON        ();
use Time::HiRes qw(time);

use Overnet::Burner::Provenance ();

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

# Map a verification verdict to the abuse defense members. The forged
# population is caught only when the verification boundary resolves it to
# forged; rendering it authoritative is the forgery succeeding, and the
# permissionless unverified/unresolvable outcomes are defended (not shown
# as authoritative) but not a correct positive detection.
my %VERDICT_DEFENSE = (
  forged         => {defended => 1, defended_correct => 1},
  unverified     => {defended => 1, defended_correct => 0},
  unresolvable   => {defended => 1, defended_correct => 0},
  authoritative  => {defended => 0, defended_correct => 0},
  not_applicable => {defended => 0, defended_correct => 0},
);

my %DEFAULTS = (
  protocol          => 'irc',
  origin            => 'irc.libera.chat/#overnet',
  authority_origin  => 'irc.libera.chat',
  origin_match      => 'prefix',
  external_identity => 'victim',
  origin_separator  => q{/},
);

no Moo;

sub expected_role {
  return 'provenance_forger';
}

sub abuse_operation {
  return 'forge_publish';
}

sub default_rate {
  return 5;
}

sub build_event {
  my ($self, $key, $sequence) = @_;

  my $config = $self->_forge_config;
  my $origin = $config->{origin};
  my $oid    = "$config->{protocol}:$origin";

  return $key->create_event(
    kind    => 7800,
    content => $JSON->encode(
      {
        provenance => {
          type              => 'adapted',
          protocol          => $config->{protocol},
          origin            => $origin,
          external_identity => $config->{external_identity},
          limitations       => ['unsigned', 'no_edit_history', 'synthetic_identity'],
        },
        body => {text => "overnet-burner forged provenance $sequence", sequence => $sequence, sent_at => time * 1000},
      }
    ),
    tags => [
      ['overnet_v',   '0.1.0'],
      ['overnet_et',  'chat.message'],
      ['overnet_ot',  'chat.channel'],
      ['overnet_oid', $oid],
      ['v',           '0.1.0'],
      ['t',           'chat.message'],
      ['o',           'chat.channel'],
      ['d',           $oid],
    ],
  );
}

sub perform_abuse {
  my ($self, %args) = @_;

  # Build the forged event, remember it for verification, and publish it so
  # the run exercises the relay carrying it: the relay is a dumb carrier,
  # never the defense, so acceptance here is expected and not measured.
  my $event = $self->build_event($args{key}, $args{sequence});
  $self->{forged_event} = $event;

  return $self->publish_event($args{client}, $event, $args{pending});
}

sub classify_abuse {
  my ($self, %args) = @_;

  my $verdict = $self->_verify_forged_event;
  my $defense = $VERDICT_DEFENSE{$verdict} || {defended => 0, defended_correct => 0};

  my $classification = {
    status         => 'success',
    outcome        => $verdict,
    error_category => undef,
    duplicate      => 0,
  };

  return ($classification, $defense);
}

sub _verify_forged_event {
  my ($self) = @_;

  my $event = $self->{forged_event};
  if (!$event) {
    return 'unresolvable';
  }

  my $result = Overnet::Burner::Provenance::verify_event(
    {pubkey => $event->pubkey, content => $event->content, created_at => $event->created_at},
    $self->_anchor_records, {origin_separator => $self->_forge_config->{origin_separator}},
  );

  return $result->{outcome};
}

sub _anchor_records {
  my ($self) = @_;

  if (!$self->{anchor_records}) {
    my $config = $self->_forge_config;
    $self->{anchor_records} = [
      {
        body => {
          protocol     => $config->{protocol},
          origin       => $config->{authority_origin},
          origin_match => $config->{origin_match},
          pubkeys      => [$self->_authority_key->pubkey_hex],
        },
      },
    ];
  }

  return $self->{anchor_records};
}

sub _authority_key {
  my ($self) = @_;

  if (!$self->{authority_key}) {
    my $input = $self->input;

    # The legitimate adapter identity the consumer anchors. The forger does
    # not sign with this key, so verifying its forged event against this
    # anchor must resolve to forged.
    $self->{authority_key} = $self->derive_key($input->{seed}, "$input->{worker_id}:provenance-authority");
  }

  return $self->{authority_key};
}

sub _forge_config {
  my ($self) = @_;

  if (!$self->{forge_config}) {
    my $abuse    = $self->input->{workload}{abuse};
    my $override = ref $abuse eq 'HASH' && ref $abuse->{provenance_forger} eq 'HASH' ? $abuse->{provenance_forger} : {};
    $self->{forge_config} = {%DEFAULTS};
    for my $field (keys %DEFAULTS) {
      if (defined $override->{$field}) {
        $self->{forge_config}{$field} = $override->{$field};
      }
    }
  }

  return $self->{forge_config};
}

1;

=head1 NAME

Overnet::Burner::Worker::ProvenanceForger - forged-provenance abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::ProvenanceForger;

  Overnet::Burner::Worker::ProvenanceForger->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<provenance_forger> abuse role
under the contract in F<docs/abuse.md>. It publishes adapted events that
claim an external origin the worker is not authoritative for: each event
carries adapted provenance for a target origin but is signed by the
worker's own identity rather than the adapter identity an authority record
binds to that origin.

Unlike the relay-facing abuse roles, its defense does not live at the
relay. A relay is a dumb carrier and accepts the forged event (Overnet core
specification section 7.7); the forgery is meant to be caught at the
consumer-side provenance verification boundary (section 7.9). The worker
therefore measures the verification outcome, not the relay acknowledgement:
it verifies each forged event with the reference oracle
L<Overnet::Burner::Provenance> against the authority record a consumer would
hold, and records C<forged> as the correct defense and C<authoritative> as
the forgery succeeding.

The target origin, protocol, and the authority record's origin scope are
configurable through C<workload.abuse.provenance_forger>; the defaults forge
an IRC channel origin against a network-scoped authority record.

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 build_event

=head2 perform_abuse

=head2 classify_abuse

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a forged event resolved as
authoritative is a metric event recording a defense failure, not a worker
failure.

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
