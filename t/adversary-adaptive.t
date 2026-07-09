use strictures 2;

use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Driver::Adaptive;
use Overnet::Burner::Adversary::Arena::Recorded;
use Overnet::Burner::Adversary::Oracle;

my $ADAPTIVE = 'Overnet::Burner::Adversary::Driver::Adaptive';

sub _run {
  my (%args) = @_;
  return Overnet::Burner::Adversary::Runner->new->run(
    driver       => $args{driver},
    arena        => $args{arena},
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => (defined $args{ground_truth} ? $args{ground_truth} : {}),
    session_id   => $args{session_id},
    seed         => '1',
  );
}

# A genuinely reactive policy: probe once, then branch on what the relay did.
# If the probe was refused, retry with a different action; otherwise stop. This
# proves the driver feeds observations back into the decision.
subtest 'the driver branches on the observations it receives' => sub {
  my $policy = sub {
    my ($context) = @_;
    if ($context->{turn} == 0) {
      return [{type => 'probe', payload => {}}];
    }
    my ($outcome) = grep { $_->{type} eq 'relay_outcome' } @{$context->{new_observations}};
    if ($outcome && !$outcome->{payload}{accepted}) {
      return [{type => 'retry', payload => {}}];
    }
    return [];
  };

  my $arena = Overnet::Burner::Adversary::Arena::Recorded->new(
    responses => [[{type => 'relay_outcome', payload => {accepted => 0}}], []],);
  my $result = _run(
    session_id => 'adapt-branch',
    driver     => $ADAPTIVE->new(policy => $policy),
    arena      => $arena,
  );

  my @actions = map { $_->{type} } @{$result->{session}->steps_of_kind('action')};
  is \@actions, ['probe', 'retry'], 'the driver retried only because it observed a refusal';
};

subtest 'a policy sees only the new observations each turn but the full history too' => sub {
  my @history_sizes;
  my @window_sizes;
  my $policy = sub {
    my ($context) = @_;
    push @history_sizes, scalar @{$context->{observations}};
    push @window_sizes,  scalar @{$context->{new_observations}};
    return $context->{turn} < 2 ? [{type => 'step', payload => {}}] : [];
  };

  my $arena = Overnet::Burner::Adversary::Arena::Recorded->new(
    responses => [[{type => 'o', payload => {}}], [{type => 'o', payload => {}}]],);
  _run(session_id => 'adapt-window', driver => $ADAPTIVE->new(policy => $policy), arena => $arena);

  is \@history_sizes, [0, 1, 2], 'the full observation history grows each turn';
  is \@window_sizes,  [0, 1, 1], 'the new-observation window carries only that turn';
};

subtest 'goal_seeking tries each attempt in order and stops when exhausted' => sub {
  my $driver = $ADAPTIVE->goal_seeking(
    attempts  => [[{type => 'a'}], [{type => 'b'}], [{type => 'c'}]],
    succeeded => sub { return 0; },
  );
  my $arena  = Overnet::Burner::Adversary::Arena::Recorded->new(responses => []);
  my $result = _run(session_id => 'adapt-exhaust', driver => $driver, arena => $arena);

  my @actions = map { $_->{type} } @{$result->{session}->steps_of_kind('action')};
  is \@actions, ['a', 'b', 'c'], 'every attempt is tried when none succeeds';
};

subtest 'goal_seeking stops early the moment the goal is met' => sub {
  my $driver = $ADAPTIVE->goal_seeking(
    attempts  => [[{type => 'attack'}], [{type => 'should-not-run'}]],
    succeeded => sub {
      my ($context) = @_;
      return scalar grep { $_->{type} eq 'breach' } @{$context->{observations}};
    },
    on_success => sub { return [{type => 'confirm', payload => {}}]; },
  );
  my $arena  = Overnet::Burner::Adversary::Arena::Recorded->new(responses => [[{type => 'breach', payload => {}}]],);
  my $result = _run(session_id => 'adapt-early', driver => $driver, arena => $arena);

  my @actions = map { $_->{type} } @{$result->{session}->steps_of_kind('action')};
  is \@actions, ['attack', 'confirm'], 'the second attempt is never reached and on_success fires';
};

subtest 'the driver validates its inputs' => sub {
  like dies { $ADAPTIVE->new(policy => 'nope') }, qr/policy\ must\ be\ a\ code\ reference/mx, 'policy must be code';
  like dies {
    $ADAPTIVE->new(policy => sub { }, max_turns => 0)
  }, qr/max_turns\ must\ be\ a\ positive\ integer/mx, 'max_turns must be positive';
  like dies { $ADAPTIVE->goal_seeking(attempts => {}) }, qr/attempts\ must\ be\ an\ array\ reference/mx,
    'attempts must be an array';

  my $bad   = $ADAPTIVE->new(policy => sub { return {not => 'array'}; });
  my $arena = Overnet::Burner::Adversary::Arena::Recorded->new(responses => []);
  like dies { _run(session_id => 'adapt-bad', driver => $bad, arena => $arena) },
    qr/policy\ must\ return\ an\ array\ reference/mx, 'a policy must return an array reference';
};

subtest 'max_turns bounds a policy that never stops' => sub {
  my $driver = $ADAPTIVE->new(policy => sub { return [{type => 'forever'}]; }, max_turns => 3);
  my $arena  = Overnet::Burner::Adversary::Arena::Recorded->new(responses => []);
  my $result = _run(session_id => 'adapt-bound', driver => $driver, arena => $arena);
  is scalar(@{$result->{session}->steps_of_kind('action')}), 3, 'the driver stops after max_turns';
};

# The payoff: an adaptive campaign against the real relay. It escalates through
# attack vectors, reads the live relay's response after each, and gives up when
# none breaches - all without a fixed script.
subtest 'an adaptive campaign probes the live relay and finds no breach' => sub {
  my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
  if (!$relay_available) {
    skip_all 'relay-perl not available';
  }
  require Overnet::Burner::Adversary::Arena::Live;

  my $scope = 'channel:#ops';
  my @seed  = (
    {type => 'new_identity',  payload => {name  => 'operator'}},
    {type => 'publish_grant', payload => {actor => 'operator', delegate => 'op-session', id => 'op-grant'}},
    {
      type    => 'publish_control',
      payload => {
        signer    => 'op-session',
        actor     => 'operator',
        authority => 'op-grant',
        kind      => 9_000,
        roles     => [{subject => 'operator', role => 'irc.operator'}],
      },
    },
  );
  my @forged_grant_vector = (
    @seed,
    {type => 'publish_grant', payload => {actor => 'attacker', delegate => 'att-session', id => 'forged'}},
    {
      type    => 'publish_control',
      payload => {
        signer    => 'att-session',
        actor     => 'operator',
        authority => 'forged',
        kind      => 9_001,
        roles     => [{subject => 'attacker', role => 'irc.operator'}],
      },
    },
    {type => 'observe_capability', payload => {subject => 'attacker', scope => $scope}},
  );
  my @forged_snapshot_vector = (
    {
      type    => 'publish_snapshot',
      payload => {
        signer      => 'attacker',
        kind        => 39_001,
        grants      => [{subject => 'attacker', role => 'irc.operator'}],
        force_store => 1
      },
    },
    {type => 'observe_capability', payload => {subject => 'attacker', scope => $scope}},
  );

  my $driver = $ADAPTIVE->goal_seeking(
    attempts  => [\@forged_grant_vector, \@forged_snapshot_vector],
    succeeded => sub {
      my ($context) = @_;
      return
        scalar grep { $_->{type} eq 'observed_capability' && $_->{payload}{subject} eq 'attacker' }
        @{$context->{observations}};
    },
  );
  my $result = _run(
    session_id => 'adapt-live-defended',
    driver     => $driver,
    arena      => Overnet::Burner::Adversary::Arena::Live->new(snapshot_signers => ['snapshot-authority'], seed => '1'),
    ground_truth =>
      {authorized_capabilities => [{subject => 'operator', capability => 'irc.operator', scope => $scope}]},
  );

  ok !$result->{verdict}{violated}, 'the adaptive campaign finds no breach against the hardened relay';
  my @attacker_caps = grep { $_->{type} eq 'observed_capability' && $_->{payload}{subject} eq 'attacker' }
    @{$result->{session}->steps_of_kind('observation')};
  is scalar(@attacker_caps), 0, 'the attacker never held a capability, so every vector was exhausted';
};

# And the mirror: when a vector really does breach, the campaign stops on it.
subtest 'an adaptive campaign stops on a real breach and the oracle catches it' => sub {
  my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
  if (!$relay_available) {
    skip_all 'relay-perl not available';
  }
  require Overnet::Burner::Adversary::Arena::Live;

  my $scope  = 'channel:#ops';
  my $driver = $ADAPTIVE->goal_seeking(
    attempts => [
      [
        {
          type    => 'publish_snapshot',
          payload =>
            {signer => 'snapshot-authority', kind => 39_001, grants => [{subject => 'rogue', role => 'irc.operator'}]},
        },
        {type => 'observe_capability', payload => {subject => 'rogue', scope => $scope}},
      ],
      [{type => 'observe_capability', payload => {subject => 'rogue', scope => $scope}}],
    ],
    succeeded => sub {
      my ($context) = @_;
      return
        scalar grep { $_->{type} eq 'observed_capability' && $_->{payload}{subject} eq 'rogue' }
        @{$context->{observations}};
    },
  );
  my $result = _run(
    session_id => 'adapt-live-breach',
    driver     => $driver,
    arena      => Overnet::Burner::Adversary::Arena::Live->new(snapshot_signers => ['snapshot-authority'], seed => '1'),
    ground_truth => {authorized_capabilities => []},
  );

  ok $result->{verdict}{violated}, 'the oracle catches the real breach the campaign provoked';
  my @snapshots = grep { $_->{type} eq 'publish_snapshot' } @{$result->{session}->steps_of_kind('action')};
  is scalar(@snapshots), 1, 'the campaign stopped after the breaching vector rather than pressing on';
};

done_testing;
