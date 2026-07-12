use strictures 2;

use Test2::V0;

use Overnet::Burner::Adversary::Attack;
use Overnet::Burner::Adversary::Oracle;

my $ATTACK = 'Overnet::Burner::Adversary::Attack';

subtest 'the catalog names its seed attacks' => sub {
  is $ATTACK->names,
    [qw(ban_mask_evasion forged_grant_escalation forged_snapshot_self_grant ordering_divergence)],
    'catalog is stable and sorted';
};

subtest 'every catalog attack targets a real oracle invariant' => sub {
  my %invariant = %{Overnet::Burner::Adversary::Oracle->new->invariants};
  for my $name (@{$ATTACK->names}) {
    my $attack = $ATTACK->attack($name);
    ok exists $invariant{$attack->{target_invariant}}, "$name targets a known invariant ($attack->{target_invariant})";
    ok length($attack->{description}),                 "$name has a description";
  }
};

# The heart of the regression corpus: every seed attack must be defended by a
# spec-conformant system and caught when a system is vulnerable, and it must
# trip exactly the invariant it targets - no more, no less.
subtest 'each attack is upheld when defended and caught when exploited' => sub {
  for my $name (@{$ATTACK->names}) {
    my $attack = $ATTACK->attack($name);
    my $target = $attack->{target_invariant};
    my $oracle = Overnet::Burner::Adversary::Oracle->new;

    my $defended = $oracle->evaluate(
      session      => $ATTACK->session($name, outcome => 'defended'),
      ground_truth => $attack->{ground_truth},
    );
    ok !$defended->{violated}, "$name: a defended system raises no finding";

    my $exploited = $oracle->evaluate(
      session      => $ATTACK->session($name, outcome => 'exploited'),
      ground_truth => $attack->{ground_truth},
    );
    ok $exploited->{violated}, "$name: a vulnerable system is caught";
    is $exploited->{invariants}{$target}{status}, 'violated', "$name: the $target invariant fires";

    my @violated = grep { $exploited->{invariants}{$_}{status} eq 'violated' } sort keys %{$exploited->{invariants}};
    is \@violated, [$target], "$name: exactly the targeted invariant is violated";

    my @tags = map { $_->{invariant} } @{$exploited->{findings}};
    is [sort { $a cmp $b } keys %{{map { $_ => 1 } @tags}}], [$target],
      "$name: every finding is tagged with the targeted invariant";
  }
};

subtest 'a replayed catalog session round-trips through JSONL' => sub {
  require Overnet::Burner::Adversary::Session;
  my $session = $ATTACK->session('forged_grant_escalation', outcome => 'exploited');
  my $replay  = Overnet::Burner::Adversary::Session->from_jsonl($session->to_jsonl);
  is $replay->steps, $session->steps, 'catalog session survives serialization';
};

subtest 'the catalog validates its inputs' => sub {
  like dies { $ATTACK->attack('no-such-attack') }, qr/unknown\ attack/mx, 'unknown attack rejected';
  like dies { $ATTACK->attack(undef) }, qr/unknown\ attack:\ \(undef\)/mx, 'an undefined name is named in the error';
  like dies { $ATTACK->session('forged_grant_escalation', outcome => 'sideways') },
    qr/outcome\ must\ be\ defended\ or\ exploited/mx, 'bad outcome rejected';
};

subtest 'session defaults the outcome and seed' => sub {
  my $session = $ATTACK->session('forged_grant_escalation');
  is $session->session_id, 'forged_grant_escalation-exploited', 'the default outcome is exploited';
  is $session->seed,       '1',                                 'the default seed is 1';
};

subtest 'interaction builds an action/response transcript' => sub {
  my $interaction = $ATTACK->interaction('forged_grant_escalation');
  ok scalar(@{$interaction->{actions}}),   'the interaction carries the attack actions';
  is scalar(@{$interaction->{responses}}), scalar(@{$interaction->{actions}}),
    'each action gets a response batch';
  ok scalar(@{$interaction->{responses}[-1]}), 'the outcome transcript trails the final action';

  my $defended = $ATTACK->interaction('forged_grant_escalation', outcome => 'defended');
  ok scalar(@{$defended->{responses}[-1]}), 'a defended interaction also carries its transcript';

  like dies { $ATTACK->interaction('forged_grant_escalation', outcome => 'sideways') },
    qr/outcome\ must\ be\ defended\ or\ exploited/mx, 'interaction rejects a bad outcome';
};

done_testing;
