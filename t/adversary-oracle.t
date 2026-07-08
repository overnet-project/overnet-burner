use strictures 2;

use Test2::V0;

use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Session;

sub _session {
  return Overnet::Burner::Adversary::Session->new(
    session_id         => 'sess-1',
    seed               => '42',
    arena_baseline_ref => 'baseline-abc',
  );
}

# Ground truth the harness knows independently: only the legitimate operator
# holds irc.operator on #ops. The attacker was never granted anything.
my $GROUND_TRUTH =
  {authorized_capabilities => [{subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'}],};

subtest 'observed capabilities backed by a grant uphold the invariant' => sub {
  my $session = _session();
  $session->append_observation(
    type    => 'observed_capability',
    payload => {subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'},
  );

  my $verdict = Overnet::Burner::Adversary::Oracle->new->evaluate(
    session      => $session,
    ground_truth => $GROUND_TRUTH,
  );

  ok !$verdict->{violated}, 'no violation when every observed capability is authorized';
  is $verdict->{invariants}{authorization}{status}, 'upheld', 'authorization upheld';
  is $verdict->{findings},                          [],       'no findings';
};

# This is the C1 forged-grant escalation: the harness forged a grant and made
# the attacker publish a 9000 put-user granting itself irc.operator. Against a
# hardened relay the control event is refused, so the attacker never appears as
# an operator - the session records no attacker capability, and the invariant
# is upheld.
subtest 'a refused escalation leaves no unauthorized capability (hardened SUT)' => sub {
  my $session = _session();
  $session->append_action(
    type    => 'publish_control',
    payload => {kind => 9000, signer => 'attacker-session', actor => 'attacker-pk', authority => 'forged'},
  );
  $session->append_observation(type => 'relay_outcome', payload => {accepted => 0, reason => 'unauthorized'});
  $session->append_observation(
    type    => 'observed_capability',
    payload => {subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'},
  );

  my $verdict = Overnet::Burner::Adversary::Oracle->new->evaluate(
    session      => $session,
    ground_truth => $GROUND_TRUTH,
  );

  ok !$verdict->{violated}, 'hardened relay refuses the forged grant, so no escalation is observed';
  is $verdict->{invariants}{authorization}{status}, 'upheld', 'authorization upheld against a hardened SUT';
};

# The same session against a VULNERABLE SUT: the forged grant is accepted and
# the attacker is now observed holding irc.operator. The oracle must catch it -
# this is the regression detector for the C1 fix.
subtest 'an accepted escalation is flagged as a violation (vulnerable SUT)' => sub {
  my $session = _session();
  $session->append_action(
    type    => 'publish_control',
    payload => {kind => 9000, signer => 'attacker-session', actor => 'attacker-pk', authority => 'forged'},
  );
  $session->append_observation(type => 'relay_outcome', payload => {accepted => 1});
  $session->append_observation(
    type    => 'observed_capability',
    payload => {subject => 'attacker-pk', capability => 'irc.operator', scope => 'channel:#ops'},
  );

  my $verdict = Overnet::Burner::Adversary::Oracle->new->evaluate(
    session      => $session,
    ground_truth => $GROUND_TRUTH,
  );

  ok $verdict->{violated}, 'unauthorized operator capability is a violation';
  is $verdict->{invariants}{authorization}{status}, 'violated', 'authorization violated';
  is scalar(@{$verdict->{findings}}),               1,          'exactly one finding';

  my $finding = $verdict->{findings}[0];
  is $finding->{invariant},  'authorization', 'finding names the invariant';
  is $finding->{subject},    'attacker-pk',   'finding names the escalating subject';
  is $finding->{capability}, 'irc.operator',  'finding names the capability';
  is $finding->{scope},      'channel:#ops',  'finding names the scope';
  ok defined $finding->{evidence_seq}, 'finding points at the observation that proves it';
  like $finding->{summary}, qr/without\ an\ authorizing\ grant/mx, 'finding explains the escalation';
};

subtest 'no observed capabilities is inconclusive, not upheld' => sub {
  my $session = _session();
  $session->append_action(type => 'publish_control', payload => {kind => 9000});

  my $verdict = Overnet::Burner::Adversary::Oracle->new->evaluate(
    session      => $session,
    ground_truth => $GROUND_TRUTH,
  );

  is $verdict->{invariants}{authorization}{status}, 'inconclusive', 'nothing observed means nothing judged';
  ok !$verdict->{violated}, 'inconclusive is not a violation';
};

subtest 'a scope mismatch is treated as unauthorized' => sub {
  my $session = _session();
  $session->append_observation(
    type    => 'observed_capability',
    payload => {subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#secret'},
  );

  my $verdict = Overnet::Burner::Adversary::Oracle->new->evaluate(
    session      => $session,
    ground_truth => $GROUND_TRUTH,
  );

  ok $verdict->{violated}, 'a grant for #ops does not authorize operator in #secret';
};

subtest 'custom invariants are evaluated and their findings surface' => sub {
  my $oracle = Overnet::Burner::Adversary::Oracle->new;
  $oracle->add_invariant(
    availability => sub {
      my ($session, $ground_truth) = @_;
      return {status => 'violated', findings => [{summary => 'honest baseline breached'}]};
    },
  );

  my $verdict = $oracle->evaluate(session => _session(), ground_truth => $GROUND_TRUTH);
  is $verdict->{invariants}{availability}{status}, 'violated', 'custom invariant runs';
  ok $verdict->{violated}, 'a custom violation fails the verdict';
  is $verdict->{findings}[0]{invariant}, 'availability', 'custom finding is tagged with its invariant';
};

subtest 'evaluate validates its arguments' => sub {
  my $oracle = Overnet::Burner::Adversary::Oracle->new;
  like dies { $oracle->evaluate(session => undef) }, qr/session\ is\ required/mx, 'session required';
  like dies { $oracle->evaluate(session => _session(), ground_truth => []) },
    qr/ground_truth\ must\ be\ an\ object/mx, 'ground_truth must be an object';
};

done_testing;
