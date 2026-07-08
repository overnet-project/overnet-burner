use strictures 2;

use Test2::V0;

use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Arena::Recorded;
use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Attack;

my $ATTACK = 'Overnet::Burner::Adversary::Attack';

sub _run {
  my ($name, $outcome) = @_;
  my $attack      = $ATTACK->attack($name);
  my $interaction = $ATTACK->interaction($name, outcome => $outcome);

  return Overnet::Burner::Adversary::Runner->new->run(
    driver => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $interaction->{actions}),
    arena  => Overnet::Burner::Adversary::Arena::Recorded->new(
      baseline_ref => 'catalog',
      responses    => $interaction->{responses},
    ),
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => $attack->{ground_truth},
    session_id   => "$name-$outcome",
    seed         => '1',
  );
}

# The end-to-end proof: every seed attack, driven action-by-action through the
# runner against a recorded arena, must be upheld when the arena replays a
# defended system and caught - on exactly its target invariant - when the arena
# replays a vulnerable one. This is the whole loop (driver -> arena -> session
# -> oracle) exercised without any live system under test.
subtest 'every catalog attack runs the full loop and is judged correctly' => sub {
  for my $name (@{$ATTACK->names}) {
    my $target = $ATTACK->attack($name)->{target_invariant};

    my $defended = _run($name, 'defended');
    ok !$defended->{verdict}{violated}, "$name: a defended system raises no finding through the runner";

    my $exploited = _run($name, 'exploited');
    ok $exploited->{verdict}{violated}, "$name: a vulnerable system is caught through the runner";
    is $exploited->{verdict}{invariants}{$target}{status}, 'violated', "$name: the $target invariant fires";

    my @violated =
      grep { $exploited->{verdict}{invariants}{$_}{status} eq 'violated' }
      sort keys %{$exploited->{verdict}{invariants}};
    is \@violated, [$target], "$name: exactly the targeted invariant is violated";
  }
};

# A session built by the runner must be judged identically to the same attack's
# hand-built catalog session: the runner is just a different path to the same
# durable artifact.
subtest 'a runner session matches the equivalent catalog session verdict' => sub {
  for my $name (@{$ATTACK->names}) {
    my $result = _run($name, 'exploited');
    my $direct = Overnet::Burner::Adversary::Oracle->new->evaluate(
      session      => $ATTACK->session($name, outcome => 'exploited'),
      ground_truth => $ATTACK->attack($name)->{ground_truth},
    );
    is $result->{verdict}{violated}, $direct->{violated}, "$name: runner and catalog sessions agree on the verdict";
  }
};

subtest 'the runner records the driver actions and arena observations in order' => sub {
  my $interaction = $ATTACK->interaction('forged_grant_escalation', outcome => 'exploited');
  my $result      = Overnet::Burner::Adversary::Runner->new->run(
    driver       => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $interaction->{actions}),
    arena        => Overnet::Burner::Adversary::Arena::Recorded->new(responses => $interaction->{responses}),
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => $ATTACK->attack('forged_grant_escalation')->{ground_truth},
    session_id   => 'run-1',
    seed         => '7',
  );

  my $session = $result->{session};
  my @actions = @{$session->steps_of_kind('action')};
  is scalar(@actions),  3,              'every scripted action is recorded';
  is $actions[0]{type}, 'new_identity', 'actions are recorded in submission order';

  my @observations = @{$session->steps_of_kind('observation')};
  ok scalar(@observations) >= 1, 'the arena observations are recorded';

  my $meta = $session->steps_of_kind('meta')->[0];
  is $meta->{payload}{arena_baseline_ref}, 'recorded', 'the session baseline comes from the arena';
};

subtest 'a scripted driver emits its actions once and then stops' => sub {
  my $driver =
    Overnet::Burner::Adversary::Driver::Scripted->new(actions => [{type => 'join', payload => {subject => 'x'}}],);
  my $first = $driver->next_actions('ignored-session');
  is scalar(@{$first}),                        1,  'the first call yields the scripted actions';
  is $driver->next_actions('ignored-session'), [], 'the second call stops the session';
};

subtest 'a recorded arena replays batches positionally then empties' => sub {
  my $arena = Overnet::Burner::Adversary::Arena::Recorded->new(
    responses => [[{type => 'relay_outcome', payload => {accepted => 0}}], []],);
  $arena->reset;
  is $arena->apply({type => 'a'})->[0]{type}, 'relay_outcome', 'first action gets the first batch';
  is $arena->apply({type => 'b'}),            [],              'second action gets the empty batch';
  is $arena->apply({type => 'c'}),            [],              'exhausted arena returns nothing';
};

subtest 'the runner bounds runaway drivers' => sub {
  my $forever = mock {} => (add => [next_actions => sub { return [{type => 'noop'}]; }],);
  my $arena   = Overnet::Burner::Adversary::Arena::Recorded->new(responses => []);

  like dies {
    Overnet::Burner::Adversary::Runner->new(max_steps => 4)->run(
      driver     => $forever,
      arena      => $arena,
      oracle     => Overnet::Burner::Adversary::Oracle->new,
      session_id => 'runaway',
      seed       => '1',
    );
  }, qr/exceeded\ max_steps/mx, 'an endless driver is stopped at the bound';
};

subtest 'the runner validates its collaborators and required arguments' => sub {
  my $ok_arena  = Overnet::Burner::Adversary::Arena::Recorded->new(responses => []);
  my $ok_driver = Overnet::Burner::Adversary::Driver::Scripted->new(actions => []);
  my $ok_oracle = Overnet::Burner::Adversary::Oracle->new;
  my $runner    = Overnet::Burner::Adversary::Runner->new;

  like dies {
    $runner->run(driver => $ok_driver, arena => $ok_arena, oracle => $ok_oracle, seed => '1');
  }, qr/session_id\ is\ required/mx, 'session_id is required';

  like dies {
    $runner->run(
      driver       => $ok_driver,
      arena        => $ok_arena,
      oracle       => $ok_oracle,
      session_id   => 's',
      seed         => '1',
      ground_truth => []
    );
  }, qr/ground_truth\ must\ be\ an\ object/mx, 'ground_truth must be an object';

  like dies {
    $runner->run(driver => $ok_oracle, arena => $ok_arena, oracle => $ok_oracle, session_id => 's', seed => '1');
  }, qr/driver\ must\ implement\ next_actions/mx, 'a driver must implement next_actions';

  like dies {
    $runner->run(driver => undef, arena => $ok_arena, oracle => $ok_oracle, session_id => 's', seed => '1');
  }, qr/driver\ is\ required/mx, 'a missing driver is rejected';
};

subtest 'the reference drivers and arenas validate their inputs' => sub {
  like dies { Overnet::Burner::Adversary::Driver::Scripted->new(actions => 'nope') },
    qr/actions\ must\ be\ an\ array\ reference/mx, 'scripted actions must be an array';
  like dies { Overnet::Burner::Adversary::Driver::Scripted->new(actions => [{payload => {}}]) },
    qr/each\ scripted\ action\ must\ be\ an\ object\ with\ a\ type/mx, 'scripted actions need a type';
  like dies { Overnet::Burner::Adversary::Arena::Recorded->new(responses => 'nope') },
    qr/responses\ must\ be\ an\ array\ reference/mx, 'recorded responses must be an array';
  like dies { Overnet::Burner::Adversary::Arena::Recorded->new(responses => [[{payload => {}}]]) },
    qr/each\ recorded\ observation\ must\ be\ an\ object\ with\ a\ type/mx, 'recorded observations need a type';
};

done_testing;
