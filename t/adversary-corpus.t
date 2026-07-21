use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Corpus;

subtest 'the shipped corpus loads its entries' => sub {
  my $corpus  = Overnet::Burner::Adversary::Corpus->new;
  my $entries = $corpus->entries;

  ok scalar(@{$entries}), 'the shipped corpus is non-empty';
  ok((grep { $_->{name} eq 'forged-grant-escalation' } @{$entries}), 'includes the forged-grant escalation attack');

  for my $entry (@{$entries}) {
    ok((defined $entry->{target_invariant} && length $entry->{target_invariant}),
      "entry '$entry->{name}' names its target invariant");
    ok((ref $entry->{actions} eq 'ARRAY' && @{$entry->{actions}}), "entry '$entry->{name}' carries actions");
    ok(ref $entry->{ground_truth} eq 'HASH',                       "entry '$entry->{name}' carries ground truth");
  }
};

subtest 'every corpus entry stays defended against the live relay' => sub {
  my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
  if (!$relay_available) {
    plan skip_all => 'relay-perl not available (Overnet::Authority::HostedChannel::Relay)';
  }

  my $corpus = Overnet::Burner::Adversary::Corpus->new;
  for my $entry (@{$corpus->entries}) {
    my $verdict = $corpus->replay($entry);
    ok !$verdict->{violated}, "corpus entry '$entry->{name}' is still defended by the live relay"
      or diag join "\n", map { $_->{summary} // q{} } @{$verdict->{findings}};
  }
};

subtest 'the corpus grows: add persists a new replayable entry' => sub {
  my $dir    = tempdir(CLEANUP => 1);
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  is scalar(@{$corpus->entries}), 0, 'a fresh corpus directory is empty';

  $corpus->add(
    {
      name             => 'sample-attack',
      description      => 'a persisted sample',
      target_invariant => 'authorization',
      seed             => '1',
      snapshot_signers => [],
      actions          => [{type => 'new_identity', payload => {name => 'x'}}],
      ground_truth     => {authorized_capabilities => []},
    }
  );

  my $reloaded = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  is scalar(@{$reloaded->entries}), 1,               'the added entry is persisted and reloads';
  is $reloaded->entries->[0]{name}, 'sample-attack', 'the entry round-trips by name';
};

subtest 'the constructor accepts a single hash reference and a missing directory reads empty' => sub {
  my $dir    = tempdir(CLEANUP => 1);
  my $corpus = Overnet::Burner::Adversary::Corpus->new({dir => $dir});
  is $corpus->dir, $dir, 'a hash-reference constructor sets the directory';

  my $absent = Overnet::Burner::Adversary::Corpus->new(dir => File::Spec->catdir($dir, 'not-created-yet'));
  is $absent->entries, [], 'entries from a directory that does not exist is empty';
};

subtest 'add fills in defaults for a minimal entry' => sub {
  my $dir    = tempdir(CLEANUP => 1);
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  $corpus->add(
    {
      name         => 'minimal-attack',
      actions      => [{type => 'new_identity', payload => {name => 'x'}}],
      ground_truth => 'not-a-hash',
    }
  );
  my $entry = Overnet::Burner::Adversary::Corpus->new(dir => $dir)->entries->[0];
  is $entry->{description},      q{}, 'a missing description defaults to empty';
  is $entry->{target_invariant}, q{}, 'a missing target invariant defaults to empty';
  is $entry->{seed},             '1', 'a missing seed defaults to 1';
  is $entry->{ground_truth}, {}, 'a non-mapping ground truth becomes an empty object';
};

subtest 'replay defaults an entry seed and ground truth' => sub {
  my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
  if (!$relay_available) {
    plan skip_all => 'relay-perl not available';
  }
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1));
  my $verdict =
    $corpus->replay({name => 'defaulted', actions => [{type => 'new_identity', payload => {name => 'operator'}}]});
  ok exists $verdict->{violated}, 'a minimal entry replays and yields a verdict';
};

subtest 'arena_for builds the arena named by the entry profile' => sub {
  my $vault = Overnet::Burner::Adversary::Corpus->arena_for({profile => 'document-vault', seed => '7'});
  isa_ok $vault, ['Overnet::Burner::Adversary::Arena::DocumentVault'], 'a document-vault entry builds the vault arena';
  is $vault->seed, '7', 'the entry seed is forwarded to the arena';

  my $default = Overnet::Burner::Adversary::Corpus->arena_for({});
  isa_ok $default, ['Overnet::Burner::Adversary::Arena::Live'], 'an entry with no profile builds the default IRC arena';

  my $signed = Overnet::Burner::Adversary::Corpus->arena_for({snapshot_signers => ['authority']});
  isa_ok $signed, ['Overnet::Burner::Adversary::Arena::Live'], 'snapshot_signers are forwarded to the IRC arena';
};

subtest 'a non-IRC corpus entry replays and stays defended without a relay' => sub {
  my $corpus = Overnet::Burner::Adversary::Corpus->new;
  my ($vault) = grep { $_->{name} eq 'document-vault-forged-writer-grant' } @{$corpus->entries};
  ok $vault, 'the shipped corpus carries the document-vault entry';
  is $vault->{profile}, 'document-vault', 'the entry names the document-vault profile';

  my $verdict = $corpus->replay($vault);
  ok !$verdict->{violated}, 'the vault authority defends the forged writer grant';
  is $verdict->{invariants}{authorization}{status}, 'upheld', 'the authorization invariant is upheld';
};

subtest 'add persists the entry profile' => sub {
  my $dir    = tempdir(CLEANUP => 1);
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  $corpus->add(
    {
      name         => 'vault-attack',
      profile      => 'document-vault',
      actions      => [{type => 'observe_capability', payload => {subject => 'nobody', scope => 'vault:reports'}}],
      ground_truth => {authorized_capabilities => []},
    }
  );
  $corpus->add(
    {
      name         => 'irc-attack',
      actions      => [{type => 'new_identity', payload => {name => 'x'}}],
      ground_truth => {authorized_capabilities => []},
    }
  );

  my %by_name = map { $_->{name} => $_ } @{Overnet::Burner::Adversary::Corpus->new(dir => $dir)->entries};
  is $by_name{'vault-attack'}{profile}, 'document-vault',     'an explicit profile is persisted';
  is $by_name{'irc-attack'}{profile},   'irc-hosted-channel', 'a missing profile persists as the default';

  my $verdict = Overnet::Burner::Adversary::Corpus->new(dir => $dir)->replay($by_name{'vault-attack'});
  ok !$verdict->{violated}, 'the reloaded vault entry replays defended with no relay';
};

subtest 'add rejects malformed entries' => sub {
  my $dir    = tempdir(CLEANUP => 1);
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => $dir);

  like dies { $corpus->add({actions => [{type => 'x', payload => {}}]}) }, qr/name\ is\ required/mx,
    'add requires a name';
  like dies { $corpus->add({name => 'no-actions'}) }, qr/actions\ must\ be\ a\ non-empty\ array/mx,
    'add requires actions';
  like dies { $corpus->add({name => 'bad/name', actions => [{type => 'x', payload => {}}]}) },
    qr/name\ must\ be\ a\ simple\ identifier/mx, 'add rejects a path-like name';
  like dies { $corpus->add('not-a-hash') }, qr/entry\ must\ be\ an\ object/mx, 'add requires an object';
  like dies { $corpus->add({name => 'no-type', actions => ['plain-string']}) },
    qr/each\ action\ must\ be\ an\ object\ with\ a\ type/mx, 'each action needs a type';
};

done_testing;
