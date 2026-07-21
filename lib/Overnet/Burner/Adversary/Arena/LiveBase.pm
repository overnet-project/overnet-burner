package Overnet::Burner::Adversary::Arena::LiveBase;

use strictures 2;
use Moo;

use Carp            qw(croak);
use Digest::SHA     qw(sha256_hex);
use Crypt::PK::ECC  ();
use Net::Nostr::Key ();

our $VERSION = '0.001';

my $BASE_TIME = 1_750_000_000;

has seed => (is => 'ro');

# The generic live-arena skeleton an application author reuses: deterministic
# identity derivation, a monotonic session clock, a symbol table of created
# authority references, and the reset/apply loop. A concrete arena consumes this
# base, supplies its application's system under test (build_sut), a baseline_ref,
# and one _do_<action> handler per action type its application understands. The
# base owns everything that is not application-specific so a new application's
# arena is only its authority handlers.

sub reset {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
  my ($self) = @_;
  $self->{_keys}        = {};
  $self->{_grants}      = {};
  $self->{_clock}       = $BASE_TIME;
  $self->{_session_seq} = 0;
  $self->{_sut}         = $self->_build_sut;
  return;
}

sub apply {
  my ($self, $action) = @_;
  if (!(ref($action) eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
    croak "apply expects an action object with a type\n";
  }
  my $method = "_do_$action->{type}";
  if (!$self->can($method)) {
    croak "unknown live action: $action->{type}\n";
  }
  my $payload = defined $action->{payload} ? $action->{payload} : {};
  if (ref($payload) ne 'HASH') {
    croak "action payload must be an object\n";
  }
  return $self->$method($payload);
}

sub _sut {
  my ($self) = @_;
  return $self->{_sut} ||= $self->_build_sut;
}

sub _key {
  my ($self, $name) = @_;
  if (!(defined $name && !ref($name) && length $name)) {
    croak "identity name is required\n";
  }
  my $keys = $self->{_keys} ||= {};
  return $keys->{$name} ||= $self->_derive_key($name);
}

sub _derive_key {
  my ($self, $name) = @_;
  my $secret_hex = sha256_hex('overnet-burner:adversary:' . $self->seed . ":$name");
  my $pk         = Crypt::PK::ECC->new;
  $pk->import_key_raw(pack('H*', $secret_hex), 'secp256k1');
  my $der = $pk->export_key_der('private');
  return Net::Nostr::Key->new(privkey => \$der);
}

sub _base_time {
  return $BASE_TIME;
}

sub _next_time {
  my ($self) = @_;
  my $now    = $self->{_clock} ||= $BASE_TIME;
  $self->{_clock} = $now + 1;
  return $now;
}

sub _next_session {
  my ($self) = @_;
  my $next = ($self->{_session_seq} ||= 0) + 1;
  $self->{_session_seq} = $next;
  return "session-$next";
}

sub _grants {
  my ($self) = @_;
  return $self->{_grants} ||= {};
}

sub _resolve_authority {
  my ($self, $symbol) = @_;
  my $id = $self->_grants->{$symbol};
  if (!defined $id) {
    croak "unknown authority reference: $symbol\n";
  }
  return $id;
}

sub _relay_outcome {
  my ($self, $accepted, $reason) = @_;
  return $self->_observation('relay_outcome',
    {accepted => ($accepted ? 1 : 0), reason => (defined $reason ? $reason : q{})});
}

sub _observation {
  my ($self, $type, $payload) = @_;
  return {type => $type, payload => $payload};
}

sub _require_field {
  my ($self, $payload, $field) = @_;
  my $value = $payload->{$field};
  if (!(defined $value && !ref($value) && length $value)) {
    croak "$field is required\n";
  }
  return $value;
}

sub _require_kind {
  my ($self, $payload) = @_;
  my $kind = $payload->{kind};
  if (!(defined $kind && !ref($kind) && $kind =~ /\A[1-9][0-9]*\z/mxs)) {
    croak "kind must be a positive integer\n";
  }
  return $kind;
}

sub _default_scalar {
  my ($self, $value, $default) = @_;
  if (!defined $value) {
    return $default;
  }
  if (ref($value) || !length $value) {
    croak "expected a non-empty scalar\n";
  }
  return $value;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Arena::LiveBase - reusable skeleton for live adversary arenas

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  package My::Arena;
  use Moo;
  extends 'Overnet::Burner::Adversary::Arena::LiveBase';

  sub baseline_ref { 'live:My::Authority' }
  sub _build_sut   { My::Authority->new }
  sub _do_act      { my ($self, $payload) = @_; ...; return [$self->_relay_outcome(1)] }

=head1 DESCRIPTION

The application-neutral core of a live adversary arena. It provides the
reset/apply loop, deterministic per-identity keypair derivation from the arena
seed, a monotonic session clock, a symbol table of created authority references,
and the observation and validation helpers an authority handler needs. A
concrete arena for one Overnet authority application consumes this base and adds
only what is application-specific: a C<baseline_ref>, a C<_build_sut> that
constructs the application's system under test, and one C<_do_E<lt>actionE<gt>>
handler per action type. See L<Overnet::Burner::Adversary::Arena::Live> for the
reference (IRC hosted-channel) arena.

=head1 SUBROUTINES/METHODS

=head2 reset

Clears identity, grant, clock, and session state and rebuilds the system under
test through C<_build_sut>.

=head2 apply

Validates an action object and dispatches it to the C<_do_E<lt>typeE<gt>>
handler the concrete arena provides. Dies on a malformed action or an action
type the arena does not handle.

=head2 _key

Returns the derived L<Net::Nostr::Key> for an identity name, memoized per reset.

=head2 _derive_key

Derives a deterministic secp256k1 key for an identity name from the arena seed.

=head2 _next_time

Returns the next value of the monotonic session clock.

=head2 _next_session

Returns the next session label.

=head2 _base_time

Returns the fixed clock origin.

=head2 _grants

Returns the symbol table mapping authority reference names to created event ids.

=head2 _resolve_authority

Resolves an authority reference name to its event id. Dies on an unknown name.

=head2 _relay_outcome

Builds a C<relay_outcome> observation from a system-under-test decision.

=head2 _observation

Builds an observation object of a given type and payload.

=head2 _require_field

Returns a required non-empty scalar field of a payload. Dies if absent.

=head2 _require_kind

Returns a payload's C<kind> as a positive integer. Dies otherwise.

=head2 _default_scalar

Returns a value or a default, requiring a non-empty scalar when present.

=head1 DIAGNOSTICS

Malformed actions, unknown action types, missing fields, and unknown authority
references are reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Crypt::PK::ECC> and L<Net::Nostr::Key>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
