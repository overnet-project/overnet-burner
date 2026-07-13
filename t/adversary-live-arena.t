use strictures 2;

use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Arena::Live;
use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Session;

# The live arena drives the real authoritative relay. Where the relay dist is
# not on @INC (e.g. a bare unit-test environment), there is nothing to drive, so
# skip rather than fail.
my $relay_available = eval {
  require Overnet::Authority::HostedChannel::Relay;
  require Net::Nostr::RelayStore;
  1;
};
if (!$relay_available) {
  plan skip_all => 'relay-perl not available (Overnet::Authority::HostedChannel::Relay)';
}

# A relay store that hands events back in raw delivery order instead of the
# canonical (created_at, id) order the shipped stores impose. Two instances
# backed by this store that accept the same events in different orders therefore
# see different input positions - the exact situation irc.md section 11.4
# forbids a derivation from depending on.
{

  package DeliveryOrderStore;
  use parent -norequire, 'Net::Nostr::RelayStore';

  sub _insert_ordered {
    my ($self, $event) = @_;
    push @{$self->{_ordered}}, $event;
    return;
  }
}

my $SNAPSHOT_AUTHORITY = 'snapshot-authority';
my $SCOPE              = 'channel:#ops';
my $OPERATOR_CAP       = {subject => 'operator', capability => 'irc.operator', scope => $SCOPE};

sub _arena {
  return Overnet::Burner::Adversary::Arena::Live->new(
    snapshot_signers => [$SNAPSHOT_AUTHORITY],
    seed             => '1',
  );
}

sub _run {
  my (%args) = @_;
  return Overnet::Burner::Adversary::Runner->new->run(
    driver       => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $args{actions}),
    arena        => _arena(),
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => $args{ground_truth},
    session_id   => $args{session_id},
    seed         => '1',
  );
}

# Establish a legitimate operator through the authoritative bootstrap path: a
# grant the operator signs, then the initial 9000 that names the operator.
my @SEED_OPERATOR = (
  {type => 'new_identity',  payload => {name  => 'operator'}},
  {type => 'publish_grant', payload => {actor => 'operator', delegate => 'operator-session', id => 'operator-grant'}},
  {
    type    => 'publish_control',
    payload => {
      signer    => 'operator-session',
      actor     => 'operator',
      authority => 'operator-grant',
      kind      => 9_000,
      roles     => [{subject => 'operator', role => 'irc.operator'}],
    },
  },
);

# C1: a forged delegation grant. The attacker signs a grant but the control
# event claims the operator as its actor. The hardened relay rejects it, so the
# attacker is never observed holding operator.
subtest 'C1 forged-grant escalation is defended by the live relay' => sub {
  my $result = _run(
    session_id => 'live-c1',
    actions    => [
      @SEED_OPERATOR,
      {type => 'new_identity', payload => {name => 'attacker'}},
      {
        type    => 'publish_grant',
        payload => {actor => 'attacker', delegate => 'attacker-session', id => 'forged-grant'},
      },
      {
        type    => 'publish_control',
        payload => {
          signer    => 'attacker-session',
          actor     => 'operator',
          authority => 'forged-grant',
          kind      => 9_001,
          roles     => [{subject => 'attacker', role => 'irc.operator'}],
        },
      },
      {type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE}},
      {type => 'observe_capability', payload => {subject => 'operator', scope => $SCOPE}},
    ],
    ground_truth => {authorized_capabilities => [$OPERATOR_CAP]},
  );

  ok !$result->{verdict}{violated}, 'the live relay defends the forged-grant escalation';
  is $result->{verdict}{invariants}{authorization}{status}, 'upheld',
    'only the legitimate operator is observed holding operator';
};

# C2: a forged snapshot. A non-authoritative signer publishes an operator
# snapshot naming itself; even stored, the hardened relay ignores it in derived
# state, so the attacker never holds operator.
subtest 'C2 forged-snapshot self-grant is defended by the live relay' => sub {
  my $result = _run(
    session_id => 'live-c2',
    actions    => [
      @SEED_OPERATOR,
      {type => 'new_identity', payload => {name => 'attacker'}},
      {
        type    => 'publish_snapshot',
        payload => {
          signer      => 'attacker',
          kind        => 39_001,
          grants      => [{subject => 'attacker', role => 'irc.operator'}],
          force_store => 1,
        },
      },
      {type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE}},
      {type => 'observe_capability', payload => {subject => 'operator', scope => $SCOPE}},
    ],
    ground_truth => {authorized_capabilities => [$OPERATOR_CAP]},
  );

  ok !$result->{verdict}{violated}, 'the live relay ignores the forged snapshot in derived state';
  is $result->{verdict}{invariants}{authorization}{status}, 'upheld', 'the attacker is not observed holding operator';
};

# Ban-mask evasion: with a ban active, a banned subject that omits its mask is
# refused (fail-closed), while a non-matching subject that asserts a mask is
# admitted.
subtest 'ban-mask evasion is defended by the live relay' => sub {
  my $result = _run(
    session_id => 'live-ban',
    actions    => [
      {
        type    => 'publish_snapshot',
        payload => {signer => $SNAPSHOT_AUTHORITY, kind => 39_000, bans => ['*!*@banned.example']},
      },
      {type => 'join', payload => {actor => 'banned', scope => $SCOPE}},
      {type => 'join', payload => {actor => 'guest',  scope => $SCOPE, mask => '*!*@guest.example'}},
    ],
    ground_truth => {
      expected_admissions =>
        [{subject => 'banned', scope => $SCOPE, admitted => 0}, {subject => 'guest', scope => $SCOPE, admitted => 1},],
    },
  );

  ok !$result->{verdict}{violated}, 'the live relay refuses the maskless banned join and admits the guest';
  is $result->{verdict}{invariants}{admission}{status}, 'upheld', 'admission decisions match the authoritative truth';
};

# Positive control: prove the detector fires on a real, live-relay-derived
# capability. An authoritative snapshot signer legitimately grants a rogue
# operator; the arena's probe confirms the relay really honors it, and the
# oracle - whose ground truth does not authorize the rogue - catches it.
subtest 'the harness catches a genuine unauthorized capability against the live relay' => sub {
  my $result = _run(
    session_id => 'live-positive-control',
    actions    => [
      {
        type    => 'publish_snapshot',
        payload => {
          signer => $SNAPSHOT_AUTHORITY,
          kind   => 39_001,
          grants => [{subject => 'rogue', role => 'irc.operator'}],
        },
      },
      {type => 'observe_capability', payload => {subject => 'rogue', scope => $SCOPE}},
    ],
    ground_truth => {authorized_capabilities => []},
  );

  ok $result->{verdict}{violated}, 'an unauthorized operator the live relay really grants is caught';
  is $result->{verdict}{invariants}{authorization}{status}, 'violated', 'the authorization invariant fires';

  my ($finding) = grep { $_->{invariant} eq 'authorization' } @{$result->{verdict}{findings}};
  is $finding->{subject},    'rogue',        'the finding names the rogue operator';
  is $finding->{capability}, 'irc.operator', 'the finding names the capability';
  is $finding->{scope},      $SCOPE,         'the finding names the scope';
};

subtest 'the live arena records real relay outcomes into the session' => sub {
  my $result = _run(
    session_id   => 'live-outcomes',
    actions      => \@SEED_OPERATOR,
    ground_truth => {},
  );

  my $session  = $result->{session};
  my @outcomes = grep { $_->{type} eq 'relay_outcome' } @{$session->steps_of_kind('observation')};
  ok scalar(@outcomes) >= 1, 'the session captures relay_outcome observations';
  ok((grep { $_->{payload}{accepted} } @outcomes), 'the legitimate operator seed is accepted by the live relay');

  my $meta = $session->steps_of_kind('meta')->[0];
  like $meta->{payload}{arena_baseline_ref}, qr/HostedChannel::Relay/mx, 'the session baseline names the live SUT';
};

subtest 'the live arena validates its actions' => sub {
  my $arena = _arena();
  $arena->reset;
  like dies { $arena->apply({type => 'no_such_action'}) }, qr/unknown\ live\ action/mx, 'unknown action rejected';
  like dies {
    $arena->apply(
      {type => 'publish_control', payload => {signer => 'x', actor => 'y', authority => 'missing', kind => 9_000}});
  }, qr/unknown\ authority\ reference/mx, 'a control event referencing an unknown grant is rejected';
  is $arena->baseline_ref, 'live:Overnet::Authority::HostedChannel::Relay', 'baseline_ref names the SUT';

  like dies {
    Overnet::Burner::Adversary::Arena::Live->new(snapshot_signers => [$SNAPSHOT_AUTHORITY], store_factory => 'nope');
  }, qr/store_factory\ must\ be\ a\ code\ reference/mx, 'a non-coderef store_factory is rejected';
};

# Replay-ordering convergence (irc.md 11.4): two live relay instances that have
# accepted the same events in different store orders MUST derive identical
# authoritative state. Two operators issue conflicting same-second put-user
# events for one target - one promoting it to operator, one leaving it a plain
# member. The events tie on created_at, carry different authorities, and share a
# semantic phase, so they reach the event-id tie-break. Feeding the pair to two
# instances in opposite orders and judging with the oracle's convergence
# invariant proves the derived operator set does not depend on store order.
my @CONVERGENCE_SETUP = (
  @SEED_OPERATOR,
  {type => 'publish_grant', payload => {actor => 'operator2', delegate => 'operator2-session', id => 'operator2-grant'}},
  {
    type    => 'publish_control',
    payload => {
      signer    => 'operator-session',
      actor     => 'operator',
      authority => 'operator-grant',
      kind      => 9_000,
      roles     => [{subject => 'operator2', role => 'irc.operator'}],
    },
  },
);

my $CONFLICT_TIME = 1_750_000_500;

my $PROMOTE_TARGET = {
  type    => 'publish_control',
  payload => {
    signer     => 'operator-session',
    actor      => 'operator',
    authority  => 'operator-grant',
    kind       => 9_000,
    created_at => $CONFLICT_TIME,
    roles      => [{subject => 'target', role => 'irc.operator'}],
  },
};

my $DEMOTE_TARGET = {
  type    => 'publish_control',
  payload => {
    signer     => 'operator2-session',
    actor      => 'operator2',
    authority  => 'operator2-grant',
    kind       => 9_000,
    created_at => $CONFLICT_TIME,
    roles      => [{subject => 'target'}],
  },
};

subtest 'two live instances converge on derived state regardless of store order' => sub {
  my $session = Overnet::Burner::Adversary::Session->new(
    session_id         => 'live-convergence',
    seed               => '1',
    arena_baseline_ref => 'live',
  );

  for my $case (
    {instance => 'store-order-forward', conflict => [$PROMOTE_TARGET, $DEMOTE_TARGET]},
    {instance => 'store-order-reverse', conflict => [$DEMOTE_TARGET, $PROMOTE_TARGET]},
    )
  {
    my $arena = Overnet::Burner::Adversary::Arena::Live->new(
      snapshot_signers => [$SNAPSHOT_AUTHORITY],
      seed             => '1',
      store_factory    => sub { return DeliveryOrderStore->new },
    );
    $arena->reset;
    for my $action (@CONVERGENCE_SETUP, @{$case->{conflict}}) {
      $arena->apply($action);
    }
    my $observations = $arena->apply(
      {
        type    => 'observe_state',
        payload => {scope => $SCOPE, instance => $case->{instance}, subjects => ['operator', 'operator2', 'target']},
      },
    );
    for my $observation (@{$observations}) {
      $session->append_observation(type => $observation->{type}, payload => $observation->{payload});
    }
  }

  my @states = grep { $_->{type} eq 'observed_state' } @{$session->steps_of_kind('observation')};
  is scalar(@states), 2, 'both instances reported an independently derived state';
  ok((grep { $_ eq 'operator' } @{$states[0]{payload}{state}{operators}}),
    'the derived state is non-empty (the seeded operator is present)');

  my $verdict = Overnet::Burner::Adversary::Oracle->new->evaluate(session => $session);
  is $verdict->{invariants}{convergence}{status}, 'upheld',
    'the oracle finds both store orders derive identical authoritative state';
  is $verdict->{invariants}{convergence}{findings}, [], 'no convergence divergence is reported';
};

subtest 'the live arena validates its construction' => sub {
  my $L = 'Overnet::Burner::Adversary::Arena::Live';
  ok $L->new({snapshot_signers => ['s']}), 'a single hash-reference constructor works';
  ok $L->new, 'the arena constructs with all defaults';
  like dies { $L->new(grant_kind => 'abc') }, qr/grant_kind\ must\ be\ a\ positive\ integer/mx,
    'grant_kind must be a positive integer';
  like dies { $L->new(snapshot_signers => 'x') }, qr/snapshot_signers\ must\ be\ an\ array/mx,
    'snapshot_signers must be an array reference';
  like dies { $L->new(snapshot_signers => ['']) }, qr/each\ snapshot\ signer\ must\ be/mx,
    'each snapshot signer must be a non-empty name';
  like dies { $L->new(store_factory => 'x') }, qr/store_factory\ must\ be\ a\ code\ reference/mx,
    'store_factory must be a code reference';
};

subtest 'the live arena validates the actions it applies' => sub {
  my $arena = _arena();
  $arena->reset;

  like dies { $arena->apply('not-a-hash') }, qr/apply\ expects\ an\ action\ object/mx, 'apply needs an action object';
  like dies { $arena->apply({type => 'teleport'}) }, qr/unknown\ live\ action:\ teleport/mx,
    'an unknown action type is rejected';
  like dies { $arena->apply({type => 'new_identity', payload => 'x'}) }, qr/action\ payload\ must\ be\ an\ object/mx,
    'the payload must be an object';
  like dies { $arena->apply({type => 'new_identity'}) }, qr/name/mx, 'new_identity requires a name';
  like dies { $arena->apply({type => 'observe_state', payload => {scope => 's', instance => 'i', subjects => 'x'}}) },
    qr/subjects\ must\ be\ a\ non-empty\ array/mx, 'observe_state needs a subjects array';
  like dies {
    $arena->apply({type => 'observe_state', payload => {scope => 's', instance => 'i', subjects => ['']}})
  }, qr/each\ subject\ must\ be/mx, 'each observed subject must be named';
  like dies { $arena->apply({type => 'publish_snapshot', payload => {signer => 'sig', kind => 'notint'}}) },
    qr/kind/mx, 'a snapshot kind must be a positive integer';

  # observe_capability with and without an explicit capability exercises both
  # sides of the capability default; an unknown subject simply observes nothing.
  is $arena->apply({type => 'observe_capability', payload => {subject => 'ghost', scope => 'channel:#x'}}), [],
    'observing an unknown subject yields nothing';
  is $arena->apply(
    {type => 'observe_capability', payload => {subject => 'ghost', scope => 'channel:#x', capability => 'irc.op'}}),
    [], 'an explicit capability is accepted';

  # A grant without an explicit id still applies (it is simply not remembered).
  $arena->apply({type => 'new_identity', payload => {name => 'op'}});
  $arena->apply({type => 'new_identity', payload => {name => 'op-session'}});
  ok $arena->apply({type => 'publish_grant', payload => {actor => 'op', delegate => 'op-session'}}),
    'a grant without an id is applied';

  # A full snapshot with grants, bans, and a closed flag exercises the tag
  # builders on their well-formed inputs.
  ok $arena->apply(
    {
      type    => 'publish_snapshot',
      payload => {
        signer => $SNAPSHOT_AUTHORITY,
        kind   => 39_100,
        grants => [{subject => 'op', role => 'irc.operator'}],
        bans   => ['*!*@x.example'],
        closed => 1,
      },
    }
    ),
    'a closed snapshot with grants and bans is applied';

  like dies {
    $arena->apply({type => 'publish_snapshot', payload => {signer => $SNAPSHOT_AUTHORITY, kind => 39_101, bans => 'x'}})
  }, qr/./mx, 'a non-array bans list is rejected';
};

done_testing;
