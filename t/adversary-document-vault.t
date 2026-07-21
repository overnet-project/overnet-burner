use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Adversary::Arena::DocumentVault;
use Overnet::Burner::Adversary::Profile::DocumentVault;
use Overnet::Burner::Adversary::Session;
use Overnet::Burner::Adversary::Oracle;

# The document-vault authority: a scope has one owner, and only the owner may
# delegate write access. This exercises the concrete arena (its authority
# decisions and observations) and the profile that packages it. The end-to-end
# neutrality proof - the same generic engine judging this non-IRC authority -
# lives in t/adversary-neutrality.t.

my $ARENA   = 'Overnet::Burner::Adversary::Arena::DocumentVault';
my $PROFILE = 'Overnet::Burner::Adversary::Profile::DocumentVault';

subtest 'the arena defaults to a single owner and scope' => sub {
  my $arena = $ARENA->new;
  is $arena->owner, 'owner',         'the default owner';
  is $arena->scope, 'vault:reports', 'the default scope';
  is $arena->seed,  '1',             'the default seed';
  is $arena->baseline_ref, 'live:Overnet::Burner::Adversary::Arena::DocumentVault',
    'the baseline names the document-vault authority';

  my $configured = $ARENA->new(owner => 'custodian', scope => 'vault:secrets', seed => '9');
  is $configured->owner, 'custodian',     'a configured owner is honored';
  is $configured->scope, 'vault:secrets', 'a configured scope is honored';
  is $configured->seed,  '9',             'a configured seed is honored';
};

subtest 'only the owner can delegate write access' => sub {
  my $arena = $ARENA->new(seed => '1');
  $arena->reset;

  my $owner_grant = $arena->apply({type => 'publish_grant', payload => {actor => 'owner', delegate => 'writer'}});
  is $owner_grant, [{type => 'relay_outcome', payload => {accepted => 1, reason => q{}}}],
    'the owner grant is accepted';

  my $forged = $arena->apply({type => 'publish_grant', payload => {actor => 'attacker', delegate => 'attacker'}});
  is $forged,
    [{type => 'relay_outcome', payload => {accepted => 0, reason => 'grant not signed by the scope owner'}}],
    'a non-owner grant is rejected';
};

subtest 'a capability observation is read from the derived writer set' => sub {
  my $arena = $ARENA->new(seed => '1');
  $arena->reset;
  $arena->apply({type => 'publish_grant', payload => {actor => 'owner', delegate => 'writer'}});

  is $arena->apply({type => 'observe_capability', payload => {subject => 'writer', scope => 'vault:reports'}}),
    [
    {
      type    => 'observed_capability',
      payload => {subject => 'writer', capability => 'vault.writer', scope => 'vault:reports'},
    }
    ],
    'the granted writer is observed to hold write access';

  is $arena->apply({type => 'observe_capability', payload => {subject => 'nobody', scope => 'vault:reports'}}), [],
    'a subject with no grant yields no observation';

  # A default scope and a default capability, plus an explicit capability label.
  is $arena->apply({type => 'observe_capability', payload => {subject => 'writer'}}),
    [
    {
      type    => 'observed_capability',
      payload => {subject => 'writer', capability => 'vault.writer', scope => 'vault:reports'},
    }
    ],
    'the scope and capability default to the arena scope and write capability';

  is $arena->apply(
    {
      type    => 'observe_capability',
      payload => {subject => 'writer', scope => 'vault:reports', capability => 'vault.rw'}
    }
    ),
    [
    {
      type    => 'observed_capability',
      payload => {subject => 'writer', capability => 'vault.rw', scope => 'vault:reports'}
    }
    ],
    'an explicit capability label is echoed';
};

subtest 'a grant is scoped to the arena scope, not another scope' => sub {
  my $arena = $ARENA->new(seed => '1', scope => 'vault:reports');
  $arena->reset;
  $arena->apply({type => 'publish_grant', payload => {actor => 'owner', delegate => 'writer'}});

  is $arena->apply({type => 'observe_capability', payload => {subject => 'writer', scope => 'vault:other'}}), [],
    'the writer holds no access in a different scope';
};

subtest 'registering an identity produces no observation' => sub {
  my $arena = $ARENA->new(seed => '1');
  $arena->reset;
  is $arena->apply({type => 'new_identity', payload => {name => 'writer'}}), [], 'new_identity is silent';
};

subtest 'the profile packages its arena, vocabulary, and catalog' => sub {
  is $PROFILE->name, 'document-vault', 'the profile names itself';

  my $arena = $PROFILE->build_arena(seed => '1');
  isa_ok $arena, [$ARENA], 'build_arena returns a document-vault arena';

  my $vocab = $PROFILE->vocabulary;
  is $vocab->{capabilities}, ['vault.writer'],                                    'the vocabulary lists its capability';
  is $vocab->{scopes},       ['vault:reports'],                                   'the vocabulary lists its scope';
  is $vocab->{action_types}, [qw(new_identity publish_grant observe_capability)], 'the vocabulary lists its actions';

  my $catalog = $PROFILE->attack_catalog;
  is [sort keys %{$catalog}], ['forged_writer_grant'], 'the catalog seeds the forged-writer-grant attack';
  is $catalog->{forged_writer_grant}{target_invariant}, 'authorization',
    'the attack targets the authorization invariant';
};

subtest 'the catalog transcripts judge as documented' => sub {
  my $oracle  = Overnet::Burner::Adversary::Oracle->new;
  my $catalog = $PROFILE->attack_catalog;

  for my $name (sort keys %{$catalog}) {
    my $attack = $catalog->{$name};

    my $defended = $oracle->evaluate(
      session      => _session_from($name, $attack, 'defended'),
      ground_truth => $attack->{ground_truth},
    );
    ok !$defended->{violated}, "$name: a defended authority raises no violation";

    my $exploited = $oracle->evaluate(
      session      => _session_from($name, $attack, 'exploited'),
      ground_truth => $attack->{ground_truth},
    );
    ok $exploited->{violated}, "$name: a vulnerable authority is caught";
    is $exploited->{invariants}{$attack->{target_invariant}}{status}, 'violated',
      "$name: the $attack->{target_invariant} invariant fires";

    my @violated = grep { $exploited->{invariants}{$_}{status} eq 'violated' } sort keys %{$exploited->{invariants}};
    is \@violated, [$attack->{target_invariant}], "$name: exactly the targeted invariant is violated";
  }
};

done_testing;

sub _session_from {
  my ($name, $attack, $outcome) = @_;
  my $session = Overnet::Burner::Adversary::Session->new(
    session_id         => "$name-$outcome",
    seed               => '1',
    arena_baseline_ref => 'catalog',
  );
  for my $action (@{$attack->{actions}}) {
    $session->append_action(type => $action->{type}, payload => $action->{payload});
  }
  for my $observation (@{$attack->{$outcome}}) {
    $session->append_observation(type => $observation->{type}, payload => $observation->{payload});
  }
  return $session;
}
