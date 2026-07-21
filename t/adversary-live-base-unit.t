use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

# The LiveBase arena is the application-neutral skeleton every live arena
# reuses: the reset/apply loop, deterministic identity derivation, the session
# clock, the authority symbol table, and the observation and validation helpers.
# A concrete arena supplies only a system under test and its authority handlers.
# This test drives the base directly through a minimal stub subclass - which is
# also a working proof that the base is genuinely reusable by a non-IRC
# application, independent of the reference IRC arena.

{

  package Test::LiveBase::Stub;    ## no critic (Modules::ProhibitMultiplePackages)

  use strictures 2;
  use Moo;

  extends 'Overnet::Burner::Adversary::Arena::LiveBase';

  our $VERSION = '0.001';

  sub baseline_ref { return 'live:Test::Stub' }

  sub _build_sut {
    my ($self) = @_;
    $self->{_build_count} = ($self->{_build_count} || 0) + 1;
    return {sut => 1, build => $self->{_build_count}};
  }

  sub _do_noop { return [] }

  sub _do_echo {
    my ($self, $payload) = @_;
    return [$self->_observation('echo', $payload)];
  }
}

my $CLASS = 'Overnet::Burner::Adversary::Arena::LiveBase';

subtest 'reset builds the system under test and clears state' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  $arena->reset;
  is $arena->_sut, {sut => 1, build => 1}, 'reset builds the system under test';
  is $arena->baseline_ref, 'live:Test::Stub', 'the concrete arena names its baseline';

  # Populate derived state, then prove reset clears it.
  $arena->_key('alice');
  $arena->_grants->{'g'} = 'grant-id';
  $arena->_next_time;
  $arena->_next_session;
  $arena->reset;
  is $arena->_grants, {},   'reset clears the authority symbol table';
  is $arena->_next_session, 'session-1',        'reset restarts the session counter';
  is $arena->_next_time,    $CLASS->_base_time, 'reset restarts the session clock';
};

subtest 'apply validates the action envelope and dispatches by type' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  $arena->reset;

  is $arena->apply({type => 'noop'}), [], 'a known action dispatches to its handler';
  is $arena->apply({type => 'echo', payload => {a => 1}}), [{type => 'echo', payload => {a => 1}}],
    'the payload reaches the handler';
  is $arena->apply({type => 'noop', payload => undef}), [], 'an omitted payload defaults to an empty object';

  like dies { $arena->apply('not-a-hash') }, qr/action\ object\ with\ a\ type/mx, 'a non-object action is rejected';
  like dies { $arena->apply({}) }, qr/action\ object\ with\ a\ type/mx, 'an action without a type is rejected';
  like dies { $arena->apply({type => 'nope'}) }, qr/unknown\ live\ action:\ nope/mx,
    'an action type with no handler is rejected';
  like dies { $arena->apply({type => 'noop', payload => []}) }, qr/payload\ must\ be\ an\ object/mx,
    'a non-object payload is rejected';
};

subtest 'the system under test is built lazily' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  my $sut   = $arena->_sut;
  is $sut, {sut => 1, build => 1}, '_sut builds on first demand without an explicit reset';
  is $arena->_sut, $sut, '_sut is memoized across calls';
};

subtest 'identities are deterministic, memoized, and validated' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  $arena->reset;

  my $key = $arena->_key('alice');
  ok $key->isa('Net::Nostr::Key'), '_key returns a Net::Nostr::Key';
  is $arena->_key('alice'), $key, 'the same name resolves to the memoized key';

  my $other = Test::LiveBase::Stub->new(seed => '1');
  $other->reset;
  is $other->_key('alice')->pubkey_hex, $key->pubkey_hex, 'the same seed and name derive the same key';

  my $different = Test::LiveBase::Stub->new(seed => '2');
  $different->reset;
  isnt $different->_key('alice')->pubkey_hex, $key->pubkey_hex, 'a different seed derives a different key';

  like dies { $arena->_key(q{}) },   qr/identity\ name\ is\ required/mx, 'an empty identity name is rejected';
  like dies { $arena->_key(undef) }, qr/identity\ name\ is\ required/mx, 'an undefined identity name is rejected';
  like dies { $arena->_key({}) },    qr/identity\ name\ is\ required/mx, 'a reference identity name is rejected';
};

subtest 'the session clock and session labels advance monotonically' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  $arena->reset;
  my $base = $CLASS->_base_time;
  is $arena->_next_time,    $base,       'the clock starts at the base time';
  is $arena->_next_time,    $base + 1,   'the clock advances by one each read';
  is $arena->_next_session, 'session-1', 'session labels start at one';
  is $arena->_next_session, 'session-2', 'session labels advance';
};

subtest 'the authority symbol table resolves references' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  $arena->reset;
  is $arena->_grants, {}, 'the symbol table starts empty';
  $arena->_grants->{'operator-grant'} = 'event-123';
  is $arena->_resolve_authority('operator-grant'), 'event-123', 'a known reference resolves to its event id';
  like dies { $arena->_resolve_authority('missing') }, qr/unknown\ authority\ reference:\ missing/mx,
    'an unknown reference is rejected';
};

subtest 'observation helpers build canonical shapes' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  is $arena->_observation('kind', {a => 1}), {type => 'kind', payload => {a => 1}},
    '_observation wraps type and payload';
  is $arena->_relay_outcome(1, 'ok'), {type => 'relay_outcome', payload => {accepted => 1, reason => 'ok'}},
    'an accepting outcome carries its reason';
  is $arena->_relay_outcome(0, undef), {type => 'relay_outcome', payload => {accepted => 0, reason => q{}}},
    'a rejecting outcome defaults the reason to empty';
  is $arena->_relay_outcome('yes'), {type => 'relay_outcome', payload => {accepted => 1, reason => q{}}},
    'any true value normalizes to accepted one';
};

subtest 'field and kind validators enforce their contracts' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');

  is $arena->_require_field({name => 'alice'}, 'name'), 'alice', 'a present scalar field is returned';
  like dies { $arena->_require_field({}, 'name') }, qr/name\ is\ required/mx, 'an absent field is rejected';
  like dies { $arena->_require_field({name => q{}}, 'name') }, qr/name\ is\ required/mx, 'an empty field is rejected';
  like dies { $arena->_require_field({name => []}, 'name') }, qr/name\ is\ required/mx, 'a reference field is rejected';

  is $arena->_require_kind({kind => 9001}), 9001, 'a positive integer kind is returned';
  like dies { $arena->_require_kind({kind => 0}) }, qr/kind\ must\ be\ a\ positive\ integer/mx,
    'a zero kind is rejected';
  like dies { $arena->_require_kind({kind => 'x'}) }, qr/kind\ must\ be\ a\ positive\ integer/mx,
    'a non-numeric kind is rejected';
  like dies { $arena->_require_kind({}) }, qr/kind\ must\ be\ a\ positive\ integer/mx, 'a missing kind is rejected';
};

subtest 'the scalar defaulter fills and validates' => sub {
  my $arena = Test::LiveBase::Stub->new(seed => '1');
  is $arena->_default_scalar(undef,     'fallback'), 'fallback', 'an undefined value takes the default';
  is $arena->_default_scalar('present', 'fallback'), 'present',  'a present value is kept';
  like dies { $arena->_default_scalar([], 'fallback') }, qr/expected\ a\ non-empty\ scalar/mx,
    'a reference value is rejected';
  like dies { $arena->_default_scalar(q{}, 'fallback') }, qr/expected\ a\ non-empty\ scalar/mx,
    'an empty value is rejected';
};

done_testing;
