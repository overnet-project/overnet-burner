package Overnet::Burner::Adversary::Arena::Live;

use strictures 2;
use Moo;

use Carp            qw(croak);
use Digest::SHA     qw(sha256_hex);
use Crypt::PK::ECC  ();
use Net::Nostr::Key ();

our $VERSION = '0.001';

my $BASE_TIME     = 1_750_000_000;
my $GRANT_TTL     = 10_000_000;
my $OPERATOR_ROLE = 'irc.operator';
my $JOIN_KIND     = 9_021;
my $REMOVE_KIND   = 9_001;

has relay_url        => (is => 'ro');
has grant_kind       => (is => 'ro');
has group_id         => (is => 'ro');
has auth_scope       => (is => 'ro');
has snapshot_signers => (is => 'ro');
has seed             => (is => 'ro');
has store_factory    => (is => 'ro');

my %HANDLER = (
  new_identity       => \&_do_new_identity,
  publish_grant      => \&_do_publish_grant,
  publish_control    => \&_do_publish_control,
  publish_snapshot   => \&_do_publish_snapshot,
  join               => \&_do_join,
  observe_capability => \&_do_observe_capability,
  observe_state      => \&_do_observe_state,
);

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  my %built = (
    relay_url  => _default_scalar($args{relay_url},  'ws://127.0.0.1:7448'),
    group_id   => _default_scalar($args{group_id},   'localnet-overnet'),
    auth_scope => _default_scalar($args{auth_scope}, 'irc://irc.example/localnet'),
    seed       => _default_scalar($args{seed},       '1'),
  );

  my $grant_kind = defined $args{grant_kind} ? $args{grant_kind} : 14_142;
  if (!(!ref($grant_kind) && $grant_kind =~ /\A[1-9][0-9]*\z/mxs)) {
    croak "grant_kind must be a positive integer\n";
  }
  $built{grant_kind} = $grant_kind;

  my $signers = defined $args{snapshot_signers} ? $args{snapshot_signers} : [];
  if (ref($signers) ne 'ARRAY') {
    croak "snapshot_signers must be an array reference of identity names\n";
  }
  for my $name (@{$signers}) {
    if (!(defined $name && !ref($name) && length $name)) {
      croak "each snapshot signer must be a non-empty identity name\n";
    }
  }
  $built{snapshot_signers} = [@{$signers}];

  if (defined $args{store_factory}) {
    if (ref($args{store_factory}) ne 'CODE') {
      croak "store_factory must be a code reference returning a fresh relay store\n";
    }
    $built{store_factory} = $args{store_factory};
  }

  return \%built;
}

sub baseline_ref {
  my ($self) = @_;
  return 'live:Overnet::Authority::HostedChannel::Relay';
}

sub reset {    ## no critic (ProhibitBuiltinHomonyms)
  my ($self) = @_;
  $self->{_keys}        = {};
  $self->{_grants}      = {};
  $self->{_clock}       = $BASE_TIME;
  $self->{_session_seq} = 0;
  $self->{_relay}       = $self->_build_relay;
  return;
}

sub apply {
  my ($self, $action) = @_;
  if (!(ref($action) eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
    croak "apply expects an action object with a type\n";
  }
  my $handler = $HANDLER{$action->{type}};
  if (!$handler) {
    croak "unknown live action: $action->{type}\n";
  }
  my $payload = defined $action->{payload} ? $action->{payload} : {};
  if (ref($payload) ne 'HASH') {
    croak "action payload must be an object\n";
  }
  return $self->$handler($payload);
}

sub _do_new_identity {
  my ($self, $payload) = @_;
  $self->_key(_require_field($payload, 'name'));
  return [];
}

sub _do_publish_grant {
  my ($self, $payload) = @_;
  my $actor_key    = $self->_key(_require_field($payload, 'actor'));
  my $delegate_key = $self->_key(_require_field($payload, 'delegate'));

  my $grant = $self->_grant_event($actor_key, $delegate_key->pubkey_hex);
  my $relay = $self->_relay;
  my ($accepted, $reason) = $relay->on_event->($grant);
  if ($accepted) {
    $relay->store->store($grant);
  }
  if (defined $payload->{id}) {
    $self->_grants->{$payload->{id}} = $grant->id;
  }

  return [_relay_outcome($accepted, $reason)];
}

sub _do_publish_control {
  my ($self, $payload) = @_;
  my $signer_key   = $self->_key(_require_field($payload, 'signer'));
  my $actor_pubkey = $self->_key(_require_field($payload, 'actor'))->pubkey_hex;
  my $authority_id = $self->_resolve_authority(_require_field($payload, 'authority'));
  my $kind         = _require_kind($payload);

  my @tags = (
    ['h',                 $self->group_id],
    ['overnet_actor',     $actor_pubkey],
    ['overnet_authority', $authority_id],
    ['overnet_sequence',  (defined $payload->{sequence} ? "$payload->{sequence}" : '1')],
    $self->_role_tags($payload->{roles}),
  );

  my $event = $signer_key->create_event(
    kind       => $kind,
    created_at => (defined $payload->{created_at} ? $payload->{created_at} : $self->_next_time),
    content    => q{},
    tags       => \@tags,
  );

  return [$self->_ingest($event)];
}

sub _do_publish_snapshot {
  my ($self, $payload) = @_;
  my $signer_key = $self->_key(_require_field($payload, 'signer'));
  my $kind       = _require_kind($payload);

  my @tags = (['d', $self->group_id]);
  push @tags, $self->_role_tags($payload->{grants});
  push @tags, _ban_tags($payload->{bans});
  if ($payload->{closed}) {
    push @tags, ['closed'];
  }

  my $event = $signer_key->create_event(
    kind       => $kind,
    created_at => $self->_next_time,
    content    => q{},
    tags       => \@tags,
  );

  return [$self->_ingest($event, $payload->{force_store})];
}

sub _do_join {
  my ($self, $payload) = @_;
  my $actor = _require_field($payload, 'actor');
  my $scope = _require_field($payload, 'scope');

  my ($grant_id, $session_key) = $self->_provision_grant($actor);
  my @tags = (
    ['h',                 $self->group_id],
    ['overnet_actor',     $self->_key($actor)->pubkey_hex],
    ['overnet_authority', $grant_id],
    ['overnet_sequence',  '1'],
  );
  if (defined $payload->{mask}) {
    push @tags, ['overnet_irc_mask', $payload->{mask}];
  }

  my $event = $session_key->create_event(
    kind       => $JOIN_KIND,
    created_at => $self->_next_time,
    content    => q{},
    tags       => \@tags,
  );

  my $outcome  = $self->_ingest($event);
  my $admitted = $outcome->{payload}{accepted};

  return [$outcome, _observation('observed_admission', {subject => $actor, scope => $scope, admitted => $admitted}),];
}

sub _do_observe_capability {
  my ($self, $payload) = @_;
  my $subject    = _require_field($payload, 'subject');
  my $scope      = _require_field($payload, 'scope');
  my $capability = defined $payload->{capability} ? $payload->{capability} : $OPERATOR_ROLE;

  if (!$self->_probe_operator($subject)) {
    return [];
  }
  return [_observation('observed_capability', {subject => $subject, capability => $capability, scope => $scope})];
}

sub _do_observe_state {
  my ($self, $payload) = @_;
  my $scope    = _require_field($payload, 'scope');
  my $instance = _require_field($payload, 'instance');
  my $subjects = $payload->{subjects};
  if (!(ref($subjects) eq 'ARRAY' && @{$subjects})) {
    croak "subjects must be a non-empty array reference of identity names\n";
  }

  my @operators;
  for my $subject (@{$subjects}) {
    if (!(defined $subject && !ref($subject) && length $subject)) {
      croak "each subject must be a non-empty identity name\n";
    }
    if ($self->_probe_operator($subject)) {
      push @operators, $subject;
    }
  }

  # The derived operator set is read only from the live relay's own decisions
  # (via the probe), sorted into a canonical order so two instances that have
  # seen the same accepted events digest identically for the oracle.
  my @sorted = sort @operators;
  return [_observation('observed_state', {scope => $scope, instance => $instance, state => {operators => \@sorted}}),];
}

sub _ingest {
  my ($self, $event, $force_store) = @_;
  my $relay = $self->_relay;
  my ($accepted, $reason) = $relay->on_event->($event);
  if ($accepted || $force_store) {
    $relay->store->store($event);
  }
  return _relay_outcome($accepted, $reason);
}

# A read-only probe of derived authority state: provision a valid grant and
# session for the subject, then authorize (but never store) a remove-user
# operator action. The relay accepts it only if the subject genuinely holds
# operator in derived state, so acceptance is an independent, live-relay answer
# to "does this subject hold operator" - it never trusts the attacker's claim.
sub _probe_operator {
  my ($self,     $subject)     = @_;
  my ($grant_id, $session_key) = $self->_provision_grant($subject);
  my $subject_pubkey = $self->_key($subject)->pubkey_hex;

  my $event = $session_key->create_event(
    kind       => $REMOVE_KIND,
    created_at => $self->_next_time,
    content    => q{},
    tags       => [
      ['h',                 $self->group_id],
      ['overnet_actor',     $subject_pubkey],
      ['overnet_authority', $grant_id],
      ['overnet_sequence',  '1'],
      ['p',                 $subject_pubkey],
    ],
  );

  my ($accepted) = $self->_relay->on_event->($event);
  return $accepted ? 1 : 0;
}

sub _provision_grant {
  my ($self, $actor) = @_;
  my $actor_key   = $self->_key($actor);
  my $session_key = _derive_key($self->seed, "$actor/probe/" . $self->_next_session);

  my $grant = $self->_grant_event($actor_key, $session_key->pubkey_hex);
  my $relay = $self->_relay;
  $relay->on_event->($grant);
  $relay->store->store($grant);

  return ($grant->id, $session_key);
}

sub _grant_event {
  my ($self, $actor_key, $delegate_pubkey) = @_;
  my $expires_at = $BASE_TIME + $GRANT_TTL;
  return $actor_key->create_event(
    kind       => $self->grant_kind,
    created_at => $self->_next_time,
    content    => q{},
    tags       => [
      ['relay',      $self->relay_url],
      ['server',     $self->auth_scope],
      ['delegate',   $delegate_pubkey],
      ['session',    $self->_next_session],
      ['expires_at', "$expires_at"],
    ],
  );
}

sub _role_tags {
  my ($self, $roles) = @_;
  if (!defined $roles) {
    return ();
  }
  if (ref($roles) ne 'ARRAY') {
    croak "roles must be an array reference\n";
  }
  my @tags;
  for my $role (@{$roles}) {
    push @tags, $self->_role_tag($role);
  }
  return @tags;
}

sub _role_tag {
  my ($self, $role) = @_;
  if (ref($role) ne 'HASH') {
    croak "each role must be an object\n";
  }
  my $pubkey = $self->_key(_require_field($role, 'subject'))->pubkey_hex;
  if (defined $role->{role}) {
    return ['p', $pubkey, $role->{role}];
  }
  return ['p', $pubkey];
}

sub _relay {
  my ($self) = @_;
  return $self->{_relay} ||= $self->_build_relay;
}

sub _build_relay {
  my ($self) = @_;
  require Overnet::Authority::HostedChannel::Relay;

  my @signer_pubkeys;
  for my $name (@{$self->snapshot_signers}) {
    push @signer_pubkeys, $self->_key($name)->pubkey_hex;
  }

  my $store = $self->store_factory ? $self->store_factory->() : undef;

  return Overnet::Authority::HostedChannel::Relay::build_authoritative_relay(
    relay_url  => $self->relay_url,
    grant_kind => $self->grant_kind,
    (@signer_pubkeys ? (snapshot_pubkeys => \@signer_pubkeys) : ()),
    (defined $store  ? (store            => $store)           : ()),
  );
}

sub _key {
  my ($self, $name) = @_;
  if (!(defined $name && !ref($name) && length $name)) {
    croak "identity name is required\n";
  }
  my $keys = $self->{_keys} ||= {};
  return $keys->{$name} ||= _derive_key($self->seed, $name);
}

sub _derive_key {
  my ($seed, $name) = @_;
  my $secret_hex = sha256_hex("overnet-burner:adversary:$seed:$name");
  my $pk         = Crypt::PK::ECC->new;
  $pk->import_key_raw(pack('H*', $secret_hex), 'secp256k1');
  my $der = $pk->export_key_der('private');
  return Net::Nostr::Key->new(privkey => \$der);
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

sub _resolve_authority {
  my ($self, $symbol) = @_;
  my $id = $self->_grants->{$symbol};
  if (!defined $id) {
    croak "unknown authority reference: $symbol\n";
  }
  return $id;
}

sub _grants {
  my ($self) = @_;
  return $self->{_grants} ||= {};
}

sub _ban_tags {
  my ($bans) = @_;
  if (!defined $bans) {
    return ();
  }
  if (ref($bans) ne 'ARRAY') {
    croak "bans must be an array reference\n";
  }
  my @tags;
  for my $mask (@{$bans}) {
    push @tags, ['ban', $mask];
  }
  return @tags;
}

sub _relay_outcome {
  my ($accepted, $reason) = @_;
  return _observation('relay_outcome', {accepted => ($accepted ? 1 : 0), reason => (defined $reason ? $reason : q{})});
}

sub _observation {
  my ($type, $payload) = @_;
  return {type => $type, payload => $payload};
}

sub _require_field {
  my ($payload, $field) = @_;
  my $value = $payload->{$field};
  if (!(defined $value && !ref($value) && length $value)) {
    croak "$field is required\n";
  }
  return $value;
}

sub _require_kind {
  my ($payload) = @_;
  my $kind = $payload->{kind};
  if (!(defined $kind && !ref($kind) && $kind =~ /\A[1-9][0-9]*\z/mxs)) {
    croak "kind must be a positive integer\n";
  }
  return $kind;
}

sub _default_scalar {
  my ($value, $default) = @_;
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

Overnet::Burner::Adversary::Arena::Live - a live arena driving the real authoritative relay

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $arena = Overnet::Burner::Adversary::Arena::Live->new(
    snapshot_signers => ['snapshot-authority'],
    seed             => '1',
  );
  $arena->reset;
  my $observations = $arena->apply(
    {type => 'publish_control', payload => {
      signer => 'operator-session', actor => 'operator',
      authority => 'operator-grant', kind => 9000,
      roles => [{subject => 'operator', role => 'irc.operator'}],
    }},
  );

=head1 DESCRIPTION

A live arena drives the real Overnet authoritative hosted-channel relay
(C<Overnet::Authority::HostedChannel::Relay>) in process, so the adversary
catalog replays against the actual hardened authorization code rather than a
recorded transcript. It is the arena a
L<Overnet::Burner::Adversary::Arena::Recorded> stands in for, and the substrate
of the live regression corpus: driving a seed attack through it and finding no
oracle violation proves the deployed relay still defends that attack.

The relay module is loaded lazily (via C<require>) the first time the arena
builds a relay, so this module remains loadable - for style and coverage gates -
even where the relay dist is not on C<@INC>. A caller that intends to
C<reset>/C<apply> must make C<Overnet::Authority::HostedChannel::Relay>
available.

=head2 Identities and scope

Actions name identities and grants symbolically (C<operator>, C<attacker>,
C<operator-grant>). The arena maps each identity name to a deterministic
secp256k1 keypair derived from the arena seed, so a run is reproducible and the
same name always resolves to the same key. All scopes map onto a single relay
group; the symbolic C<scope> in an action is echoed verbatim into the
observations so it lines up with the oracle's ground truth.

=head2 Deriving observations independently

The arena never trusts an action's claim. Acceptance or rejection of an event
is read from the relay's own C<on_event> decision (C<relay_outcome>). Capability
and admission observations are produced by I<probing> the live relay: to answer
"does this subject hold operator" the arena authorizes - but never stores - a
remove-user operator action for the subject and reports the capability only if
the real relay accepts it; to answer "is this subject admitted" it reads the
relay's decision on the subject's join request. This is what makes the arena's
observations an independent signal the oracle can judge.

=head2 Action vocabulary

Each action is C<< {type => ..., payload => {...}} >>:

=over

=item * C<new_identity> - C<name>: register a deterministic identity.

=item * C<publish_grant> - C<actor>, C<delegate>, optional C<id>: publish a
delegation grant signed by C<actor> delegating to C<delegate>; C<id> records a
symbolic handle a later control event can reference as its authority.

=item * C<publish_control> - C<signer>, C<actor>, C<authority>, C<kind>,
optional C<roles> (list of C<< {subject, role} >>), C<sequence>, C<created_at>:
publish a NIP-29 control event and return the relay's decision.

=item * C<publish_snapshot> - C<signer>, C<kind>, optional C<grants>, C<bans>,
C<closed>, C<force_store>: publish a group snapshot. C<force_store> stores the
event even when the relay refuses it, to mirror a forged snapshot that is
present in the store but must be ignored in derived state.

=item * C<join> - C<actor>, C<scope>, optional C<mask>: submit a join request
and return the relay's decision plus an C<observed_admission>.

=item * C<observe_capability> - C<subject>, C<scope>, optional C<capability>:
probe whether the subject holds the capability and emit an
C<observed_capability> only if the live relay grants it.

=item * C<observe_state> - C<scope>, C<instance>, C<subjects> (list of identity
names): probe each subject and emit one C<observed_state> whose C<state> is the
canonical sorted set of subjects the live relay derives as operators, tagged
with the given C<instance>. Two instances driven the same accepted events in
different store orders emit matching C<observed_state>, which the oracle's
convergence invariant judges; a divergence is a replay-ordering defect.

=back

=head1 SUBROUTINES/METHODS

=head2 new

Creates a live arena. Takes optional C<relay_url> (default
C<ws://127.0.0.1:7448>), C<grant_kind> (default 14142), C<group_id>,
C<auth_scope>, C<snapshot_signers> (identity names that are the relay's
authoritative snapshot signers), and C<seed>.

C<store_factory> is an optional code reference returning a fresh relay store;
the arena calls it on each C<reset> so an episode can drive the relay against an
alternate persistence backend - for example a store that hands events back in
delivery order rather than a canonical order, to exercise replay and
duplicate-delivery ordering. When omitted the relay uses its default store.

=head2 baseline_ref

Returns the opaque baseline reference identifying the live system under test.

=head2 reset

Builds a fresh relay with an empty store and clears the identity and grant
registries, so each episode starts from a clean authoritative baseline.

=head2 apply

Takes one action object, executes it against the live relay, and returns an
array reference of observations derived from the relay's real behavior.

=head1 DIAGNOSTICS

Invalid constructor arguments, unknown action types, unknown authority
references, and malformed payloads are reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires C<Overnet::Authority::HostedChannel::Relay> (the relay dist) to be on
C<@INC> before C<reset> or C<apply> is called.

=head1 DEPENDENCIES

Requires L<Moo>, L<Net::Nostr::Key>, L<Crypt::PK::ECC>, and L<Digest::SHA>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The arena drives the relay in process rather than over a WebSocket; it exercises
the authorization engine, not the transport. All scopes map onto a single relay
group.

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
