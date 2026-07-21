use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Adversary::Profile;
use Overnet::Burner::Adversary::Profile::IrcHostedChannel;

# The profile registry is the seam that makes the adversary subsystem
# application-neutral: it resolves an application profile by name, defaulting to
# the reference IRC hosted-channel profile.

my $PROFILE = 'Overnet::Burner::Adversary::Profile';
my $IRC     = 'Overnet::Burner::Adversary::Profile::IrcHostedChannel';

my $VAULT = 'Overnet::Burner::Adversary::Profile::DocumentVault';

subtest 'the registry resolves and defaults to the reference profile' => sub {
  is $PROFILE->names, ['document-vault', 'irc-hosted-channel'], 'the registry lists its profiles';
  is $PROFILE->default_name, 'irc-hosted-channel', 'the default profile is the IRC hosted-channel authority';
  is $PROFILE->default_profile, $IRC, 'the default resolves to the reference profile class';
  is $PROFILE->resolve('irc-hosted-channel'), $IRC,   'a known name resolves to its class';
  is $PROFILE->resolve('document-vault'),     $VAULT, 'the non-IRC profile resolves to its class';
  is $PROFILE->resolve(undef), $IRC, 'an undefined name resolves the default';
  is $PROFILE->resolve(q{}),   $IRC, 'an empty name resolves the default';
  like dies { $PROFILE->resolve('no-such-app') }, qr/unknown\ adversary\ profile/mx,
    'an unregistered name is rejected';
};

subtest 'the IRC profile packages its arena, catalog, and vocabulary' => sub {
  is $IRC->name, 'irc-hosted-channel', 'the profile names itself';

  my $arena = $IRC->build_arena(seed => '1');
  ok $arena->can('apply') && $arena->can('reset') && $arena->can('baseline_ref'),
    'build_arena returns an object honoring the arena contract';

  my $catalog = $IRC->attack_catalog;
  is [sort keys %{$catalog}],
    [qw(ban_mask_evasion forged_grant_escalation forged_snapshot_self_grant ordering_divergence)],
    'the catalog carries the seed attacks';
  is $catalog->{forged_grant_escalation}{target_invariant}, 'authorization',
    'a catalog entry keeps its target invariant';

  # The catalog is freshly copied each call, so a caller cannot mutate the next
  # caller's view.
  $catalog->{forged_grant_escalation}{description} = 'mutated';
  isnt $IRC->attack_catalog->{forged_grant_escalation}{description}, 'mutated',
    'attack_catalog returns a fresh copy each call';

  my $vocab = $IRC->vocabulary;
  is $vocab->{capabilities}, ['irc.operator'], 'the vocabulary names the application capability';
  is $vocab->{scopes},       ['channel:#ops'], 'the vocabulary names the application scope';
  ok scalar(@{$vocab->{action_types}}) > 0, 'the vocabulary lists action types';
};

done_testing;
