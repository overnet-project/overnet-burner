use strictures 2;

use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Arena::Live;
use Overnet::Burner::Adversary::Oracle;

# The live arena drives the real authoritative relay. Where the relay dist is
# not on @INC (e.g. a bare unit-test environment), there is nothing to drive, so
# skip rather than fail.
my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
if (!$relay_available) {
  plan skip_all => 'relay-perl not available (Overnet::Authority::HostedChannel::Relay)';
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
};

done_testing;
