use strictures 2;

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
