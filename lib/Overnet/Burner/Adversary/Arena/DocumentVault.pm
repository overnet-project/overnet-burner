package Overnet::Burner::Adversary::Arena::DocumentVault;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Adversary::Arena::LiveBase';

our $VERSION = '0.001';

my $WRITER_CAPABILITY = 'vault.writer';
my $KEY_SEPARATOR     = "\0";

has '+seed' => (default => sub {'1'});
has owner   => (is      => 'ro', default => sub {'owner'});
has scope   => (is      => 'ro', default => sub {'vault:reports'});

sub baseline_ref {
  my ($self) = @_;
  return 'live:Overnet::Burner::Adversary::Arena::DocumentVault';
}

# The reference document-vault authority: a scope has a single owner, and only
# the owner may delegate write access. The system under test is the derived
# writer set, built from the grants the owner actually signed - never from an
# action's claim. An attacker cannot mint a grant whose signer is the owner
# because it does not control the owner's deterministically derived key.
sub _build_sut {
  my ($self) = @_;
  return {
    owner   => $self->_key($self->owner)->pubkey_hex,
    writers => {},
  };
}

sub _do_new_identity {
  my ($self, $payload) = @_;
  $self->_key($self->_require_field($payload, 'name'));
  return [];
}

sub _do_publish_grant {
  my ($self, $payload) = @_;
  my $actor_key    = $self->_key($self->_require_field($payload, 'actor'));
  my $delegate_key = $self->_key($self->_require_field($payload, 'delegate'));

  my ($accepted, $reason) = $self->_submit_grant(
    {
      signer   => $actor_key->pubkey_hex,
      delegate => $delegate_key->pubkey_hex,
      scope    => $self->scope,
    }
  );

  return [$self->_relay_outcome($accepted, $reason)];
}

sub _do_observe_capability {
  my ($self, $payload) = @_;
  my $subject    = $self->_require_field($payload, 'subject');
  my $scope      = defined $payload->{scope}      ? $payload->{scope}      : $self->scope;
  my $capability = defined $payload->{capability} ? $payload->{capability} : $WRITER_CAPABILITY;

  # The observation is read from the authority's derived writer set, so it is an
  # independent answer to "does this subject hold write access" rather than a
  # restatement of the action's claim.
  if (!$self->_holds_writer($self->_key($subject)->pubkey_hex, $scope)) {
    return [];
  }
  return [$self->_observation('observed_capability', {subject => $subject, capability => $capability, scope => $scope})
  ];
}

sub _submit_grant {
  my ($self, $grant) = @_;
  my $sut = $self->_sut;

  if ($grant->{signer} ne $sut->{owner}) {
    return (0, 'grant not signed by the scope owner');
  }
  $sut->{writers}{_writer_key($grant->{scope}, $grant->{delegate})} = 1;
  return (1, q{});
}

sub _holds_writer {
  my ($self, $pubkey, $scope) = @_;
  return $self->_sut->{writers}{_writer_key($scope, $pubkey)} ? 1 : 0;
}

sub _writer_key {
  my ($scope, $pubkey) = @_;
  return "$scope$KEY_SEPARATOR$pubkey";
}

1;

=head1 NAME

Overnet::Burner::Adversary::Arena::DocumentVault - a live arena driving a document-vault authority

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $arena = Overnet::Burner::Adversary::Arena::DocumentVault->new(seed => '1');
  $arena->reset;
  $arena->apply({type => 'publish_grant', payload => {actor => 'owner', delegate => 'writer'}});
  my $observations = $arena->apply(
    {type => 'observe_capability', payload => {subject => 'writer', scope => 'vault:reports'}},
  );

=head1 DESCRIPTION

A second, deliberately non-IRC live arena: it drives a I<document-vault>
authority in which a document scope has a single owner and only the owner may
delegate write access to it. It exists to prove the adversary subsystem - the
runner, oracle, session, server, and profile registry - is genuinely
application-neutral rather than an IRC harness in disguise: the same generic
engine judges this authority's sessions unchanged, through the same neutral
observations (C<relay_outcome>, C<observed_capability>) and the same built-in
C<authorization> invariant.

Unlike L<Overnet::Burner::Adversary::Arena::Live>, which drives the real
hosted-channel relay dist, this arena embeds a small reference authority as its
system under test, so it needs only L<Net::Nostr::Key> (deterministic identity
derivation, inherited from L<Overnet::Burner::Adversary::Arena::LiveBase>) and
runs anywhere. The authority is faithful, not a mock: the writer set is derived
only from grants the owner actually signed, and an attacker cannot forge an
owner-signed grant because it does not control the owner's derived key.

=head2 Action vocabulary

Each action is C<< {type => ..., payload => {...}} >>:

=over

=item * C<new_identity> - C<name>: register a deterministic identity.

=item * C<publish_grant> - C<actor>, C<delegate>: C<actor> signs a grant
delegating write access to C<delegate>. The authority accepts it only when
C<actor> is the scope owner, and returns the decision as a C<relay_outcome>.

=item * C<observe_capability> - C<subject>, optional C<scope>, C<capability>:
probe whether C<subject> holds write access in the authority's derived state and
emit an C<observed_capability> only if it genuinely does.

=back

=head1 SUBROUTINES/METHODS

=head2 new

Creates a document-vault arena. Takes optional C<owner> (identity name of the
scope owner, default C<owner>), C<scope> (the vault scope, default
C<vault:reports>), and C<seed> (default C<1>).

=head2 baseline_ref

Returns the opaque baseline reference identifying the document-vault authority.

=head2 reset

Rebuilds the authority with the configured owner and an empty writer set and
clears the identity and session state. Inherited from
L<Overnet::Burner::Adversary::Arena::LiveBase>.

=head2 apply

Takes one action object, executes it against the authority, and returns an array
reference of observations derived from the authority's real decisions. Inherited
from L<Overnet::Burner::Adversary::Arena::LiveBase>.

=head1 DIAGNOSTICS

Unknown action types, unknown authority references, and malformed payloads are
reported with C<croak> (through the base arena).

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required; the authority is
embedded, so no external dist is needed.

=head1 DEPENDENCIES

Requires L<Moo> and L<Overnet::Burner::Adversary::Arena::LiveBase>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The authority models a single scope with a single owner; multi-scope and
ownership-transfer semantics are out of scope for this reference profile. Report
issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
