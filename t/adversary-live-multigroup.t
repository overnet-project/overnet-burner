use strictures 2;

use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Arena::Live;
use Overnet::Burner::Adversary::Oracle;

# The live arena used to map every symbolic scope onto a single relay group, so
# a cross-group authorization attack - authorize an event against one group via
# one addressing tag while a second tag smuggles it into another group's derived
# state - could not even be expressed, let alone caught. This exercises the
# multi-group vocabulary that closes that blind spot: a `group` selects the
# event's authorization group (its `h` for control, `d` for snapshots) and a
# `smuggle_group` sets the opposite tag, and observations probe a named group.

my $relay_available = eval {
  require Overnet::Authority::HostedChannel::Relay;
  require Net::Nostr::RelayStore;
  1;
};
if (!$relay_available) {
  plan skip_all => 'relay-perl not available (Overnet::Authority::HostedChannel::Relay)';
}

my $SCOPE = 'channel:#ops';
my $OP    = {subject => 'operator', capability => 'irc.operator', scope => $SCOPE};

sub _run {
  my (%args) = @_;
  return Overnet::Burner::Adversary::Runner->new->run(
    driver       => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $args{actions}),
    arena        => Overnet::Burner::Adversary::Arena::Live->new(seed => '1'),
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => $args{ground_truth},
    session_id   => $args{session_id},
    seed         => '1',
  );
}

# A legitimate operator of the "victim" group, established there and nowhere else.
my @SEED_VICTIM_OPERATOR = (
  {type => 'new_identity',  payload => {name  => 'operator'}},
  {type => 'publish_grant', payload => {actor => 'operator', delegate => 'operator-session', id => 'operator-grant'}},
  {
    type    => 'publish_control',
    payload => {
      signer    => 'operator-session',
      actor     => 'operator',
      authority => 'operator-grant',
      kind      => 9_000,
      group     => 'victim',
      roles     => [{subject => 'operator', role => 'irc.operator'}],
    },
  },
);

subtest 'observations probe the named group, not a single global group' => sub {
  my $result = _run(
    session_id => 'multigroup-positive-control',
    actions    => [
      @SEED_VICTIM_OPERATOR,
      {type => 'observe_capability', payload => {subject => 'operator', scope => $SCOPE, group => 'victim'}},
      {type => 'observe_capability', payload => {subject => 'operator', scope => $SCOPE, group => 'elsewhere'}},
    ],
    ground_truth => {authorized_capabilities => [$OP]},
  );

  my @caps = grep { $_->{type} eq 'observed_capability' } @{$result->{session}->steps_of_kind('observation')};
  is scalar(@caps), 1, 'the operator is observed holding operator in exactly one group';
  ok !$result->{verdict}{violated}, 'observing the operator only in the group it operates is not a violation';
};

subtest 'a cross-group injection cannot confer operator in the victim group (relay defends)' => sub {
  my $result = _run(
    session_id => 'multigroup-cross-group-escalation',
    actions    => [
      @SEED_VICTIM_OPERATOR,
      {type => 'new_identity',  payload => {name  => 'attacker'}},
      {type => 'publish_grant', payload => {actor => 'attacker', delegate => 'attacker-session', id => 'atk-grant'}},

      # The injection: authorize a self=operator 9000 against an empty throwaway
      # group (its `h`), smuggling `d` = victim to try to fold it into the
      # victim's derived state.
      {
        type    => 'publish_control',
        payload => {
          signer        => 'attacker-session',
          actor         => 'attacker',
          authority     => 'atk-grant',
          kind          => 9_000,
          group         => 'throwaway',
          smuggle_group => 'victim',
          roles         => [{subject => 'attacker', role => 'irc.operator'}],
        },
      },
      {type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE, group => 'victim'}},
      {type => 'observe_capability', payload => {subject => 'operator', scope => $SCOPE, group => 'victim'}},
    ],
    ground_truth => {authorized_capabilities => [$OP]},
  );

  my @outcomes = grep { $_->{type} eq 'relay_outcome' } @{$result->{session}->steps_of_kind('observation')};
  ok((grep { $_->{payload}{accepted} } @outcomes), 'the injection is accepted against the throwaway group it bootstraps');

  my %ops = map { $_->{payload}{subject} => 1 }
    grep { $_->{type} eq 'observed_capability' } @{$result->{session}->steps_of_kind('observation')};
  ok !$ops{attacker}, 'the smuggled d tag does not make the attacker an operator in the victim';
  ok $ops{operator},  'the legitimate operator still holds operator in the victim';
  ok !$result->{verdict}{violated}, 'the hardened relay defends the cross-group escalation';
};

subtest 'the arena expresses a snapshot smuggle (d authorizes, h targets another group)' => sub {
  my $arena = Overnet::Burner::Adversary::Arena::Live->new(seed => '1');
  $arena->reset;
  $arena->apply({type => 'new_identity', payload => {name => 'attacker'}});
  $arena->apply(
    {type => 'publish_grant', payload => {actor => 'attacker', delegate => 'attacker-session', id => 'atk-grant'}});

  # A delegated 39000 whose `d` is a throwaway group and whose `h` smuggles into
  # the victim; the arena must place the tags on the right addressing slots.
  my $observations = $arena->apply(
    {
      type    => 'publish_snapshot',
      payload => {
        signer        => 'attacker-session',
        actor         => 'attacker',
        authority     => 'atk-grant',
        kind          => 39_000,
        group         => 'throwaway',
        smuggle_group => 'victim',
        tombstoned    => 1,
      },
    },
  );
  is ref($observations), 'ARRAY', 'a snapshot smuggle action is accepted by the arena vocabulary';
};

subtest 'observe_availability catches a channel that is tombstoned out from under its operator' => sub {
  my $result = _run(
    session_id => 'multigroup-availability',
    actions    => [
      @SEED_VICTIM_OPERATOR,

      # While the channel is healthy the operator can act: available.
      {type => 'observe_availability', payload => {subject => 'operator', scope => $SCOPE, group => 'victim'}},

      # The channel is tombstoned (here by a delegated 39000 the operator itself
      # signs; the same denial is what a cross-group tombstone attack inflicts).
      {
        type    => 'publish_snapshot',
        payload => {
          signer     => 'operator-session',
          actor      => 'operator',
          authority  => 'operator-grant',
          kind       => 39_000,
          group      => 'victim',
          tombstoned => 1,
        },
      },

      # Now the operator can no longer act: the authority has been denied.
      {type => 'observe_availability', payload => {subject => 'operator', scope => $SCOPE, group => 'victim'}},
    ],
    ground_truth =>
      {expected_availability => [{subject => 'operator', scope => $SCOPE, available => 1}]},
  );

  my @avail = map { $_->{payload}{available} }
    grep { $_->{type} eq 'observed_availability' } @{$result->{session}->steps_of_kind('observation')};
  is \@avail, [1, 0], 'the operator was available before the tombstone and denied after';
  ok $result->{verdict}{violated}, 'the availability invariant catches the authority being destroyed';
  is $result->{verdict}{invariants}{availability}{status}, 'violated', 'availability is the violated invariant';
};

done_testing;
