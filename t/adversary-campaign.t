use strictures 2;

use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Campaign;
use Overnet::Burner::Adversary::Corpus;

my $SCOPE = 'channel:#ops';

# A stub arena that always withstands the attack: it observes nothing, so the
# oracle never sees an unauthorized capability and the verdict is not violated.
{

  package DefendedArena;
  sub new          { my ($class) = @_; return bless {}, $class; }
  sub baseline_ref { return 'stub:defended'; }
  sub reset        { return; }                                      ## no critic (ProhibitBuiltinHomonyms)
  sub apply        { return []; }
}

# A stub arena with a hole: any capability observation leaks operator to the
# attacker, which burner's ground truth never authorized - an authorization
# violation the oracle must catch.
{

  package LeakyArena;
  sub new          { my ($class) = @_; return bless {}, $class; }
  sub baseline_ref { return 'stub:leaky'; }
  sub reset        { return; }                                      ## no critic (ProhibitBuiltinHomonyms)

  sub apply {
    my ($self, $action) = @_;
    if ($action->{type} eq 'observe_capability') {
      return [
        {
          type    => 'observed_capability',
          payload => {subject => 'attacker', capability => 'irc.operator', scope => $SCOPE},
        },
      ];
    }
    return [];
  }
}

sub _base {
  my ($name) = @_;
  return {
    name             => $name,
    target_invariant => 'authorization',
    seed             => '1',
    snapshot_signers => [],
    actions          => [{type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE}}],
    ground_truth     => {authorized_capabilities => []},
  };
}

subtest 'the constructor validates its collaborators' => sub {
  like dies { Overnet::Burner::Adversary::Campaign->new }, qr/corpus\ is\ required/mx, 'corpus is required';
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1));
  like dies { Overnet::Burner::Adversary::Campaign->new(corpus => $corpus, arena_factory => 'x') },
    qr/arena_factory\ must\ be\ a\ code\ reference/mx, 'arena_factory must be a code reference';
};

subtest 'hunt aggregates regressions and tags the base that produced them' => sub {
  my $corpus   = Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1));
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => $corpus,
    arena_factory => sub { return LeakyArena->new },
  );

  my $result = $campaign->hunt(bases => [_base('alpha'), _base('beta')], max_variants => 8);

  is $result->{swept}, 2, 'both bases were swept';
  ok $result->{explored} > 1,           'the campaign explored the mutation neighbourhood';
  ok scalar(@{$result->{regressions}}), 'the leaky arena produced regressions';

  my %bases = map { $_->{base} => 1 } @{$result->{regressions}};
  ok $bases{alpha}, 'a regression is tagged with base alpha';
  ok $bases{beta},  'a regression is tagged with base beta';

  my ($one) = @{$result->{regressions}};
  ok $one->{verdict}{violated}, 'each regression carries the violated verdict';
  ok((defined $one->{label} && length $one->{label}), 'each regression carries the variant label');
  ok(ref $one->{actions} eq 'ARRAY',                  'each regression carries the reproducing action trace');
};

subtest 'hunt over a defended arena finds no regressions' => sub {
  my $corpus   = Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1));
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => $corpus,
    arena_factory => sub { return DefendedArena->new },
  );

  my $result = $campaign->hunt(bases => [_base('alpha')], max_variants => 8);
  is scalar(@{$result->{regressions}}), 0, 'a defended arena yields no regressions';
};

subtest 'promote adds a defended, novel attack and refuses the rest' => sub {
  my $dir      = tempdir(CLEANUP => 1);
  my $corpus   = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => $corpus,
    arena_factory => sub { return DefendedArena->new },
  );

  my $added = $campaign->promote(_base('promoted'));
  is $added->{added}, 1,          'a defended, novel attack is promoted';
  is $added->{name},  'promoted', 'the promotion reports the entry name';

  my $reloaded = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  is scalar(@{$reloaded->entries}), 1, 'the promoted attack is now a corpus entry';

  my $again = $campaign->promote(_base('promoted-again'));
  is $again->{added},  0,                 'a duplicate action signature is not promoted again';
  is $again->{reason}, 'already-guarded', 'the duplicate is reported as already-guarded';
  is scalar(@{Overnet::Burner::Adversary::Corpus->new(dir => $dir)->entries}), 1, 'the corpus did not grow';
};

subtest 'promote refuses a live violation' => sub {
  my $dir      = tempdir(CLEANUP => 1);
  my $corpus   = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => $corpus,
    arena_factory => sub { return LeakyArena->new },
  );

  my $refused = $campaign->promote(_base('would-be-hole'));
  is $refused->{added},  0,              'a currently-violated attack is not promoted';
  is $refused->{reason}, 'not-defended', 'the refusal names the reason';
  is scalar(@{Overnet::Burner::Adversary::Corpus->new(dir => $dir)->entries}), 0,
    'a live violation never enters the corpus';
};

subtest 'the constructor accepts a hash reference and an explicit oracle and validates the corpus' => sub {
  my $corpus = Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1));
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    {corpus => $corpus, arena_factory => sub { return DefendedArena->new }, oracle => Overnet::Burner::Adversary::Oracle->new});
  ok $campaign, 'a hash-reference constructor with an explicit oracle builds a campaign';
  like dies { Overnet::Burner::Adversary::Campaign->new(corpus => 'not-a-corpus') }, qr/corpus\ is\ required/mx,
    'an object without the corpus interface is rejected';
};

subtest 'hunt validates its bases' => sub {
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1)),
    arena_factory => sub { return DefendedArena->new },
  );
  like dies { $campaign->hunt(bases => 'nope') }, qr/bases\ must\ be\ an\ array/mx, 'bases must be an array';
  like dies { $campaign->hunt(bases => ['not-a-hash']) }, qr/base\ must\ be\ an\ object/mx, 'a base must be an object';
  like dies { $campaign->hunt(bases => [{actions => [{type => 'x'}]}]) }, qr/base\ name\ is\ required/mx,
    'a base needs a name';
  like dies { $campaign->hunt(bases => [{name => 'n', actions => []}]) },
    qr/base\ actions\ must\ be\ a\ non-empty/mx, 'a base needs actions';
};

subtest 'hunt defaults max_variants, seed and ground_truth and honours the baseline' => sub {
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => Overnet::Burner::Adversary::Corpus->new(dir => tempdir(CLEANUP => 1)),
    arena_factory => sub { return DefendedArena->new },
  );

  # A base with no seed, no ground_truth, snapshot_signers and an authoritative
  # snapshot action: exercises the default paths and the baseline digest's
  # snapshot-matching branch.
  my $base = {
    name             => 'snapshotted',
    snapshot_signers => ['authority'],
    actions          => [
      {type => 'publish_snapshot',  payload => {signer  => 'authority'}},
      {type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE}},
    ],
  };
  my $result = $campaign->hunt(bases => [$base]);
  is $result->{swept}, 1, 'the base was swept with the default budget';
};

subtest 'promote iterates existing entries and defaults the replay' => sub {
  my $dir      = tempdir(CLEANUP => 1);
  my $corpus   = Overnet::Burner::Adversary::Corpus->new(dir => $dir);
  my $campaign = Overnet::Burner::Adversary::Campaign->new(
    corpus        => $corpus,
    arena_factory => sub { return DefendedArena->new },
  );

  # Seed the corpus with one attack, then promote a structurally different one
  # that has no seed or ground_truth, so the signature loop skips a non-match
  # and the replay defaults kick in.
  $campaign->promote(_base('first'));
  my $novel = {
    name    => 'second',
    actions => [{type => 'observe_capability', payload => {subject => 'other', scope => $SCOPE}}],
  };
  my $added = $campaign->promote($novel);
  is $added->{added}, 1, 'a structurally distinct attack is promoted past the existing entry';
  is scalar(@{Overnet::Burner::Adversary::Corpus->new(dir => $dir)->entries}), 2, 'the corpus grew to two entries';
};

subtest 'the hardened live relay withstands the whole corpus neighbourhood' => sub {
  my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
  if (!$relay_available) {
    plan skip_all => 'relay-perl not available (Overnet::Authority::HostedChannel::Relay)';
  }

  my $corpus   = Overnet::Burner::Adversary::Corpus->new;
  my $campaign = Overnet::Burner::Adversary::Campaign->new(corpus => $corpus);

  my $result = $campaign->hunt(max_variants => 4);
  ok $result->{swept} > 0,                   'the campaign swept the shipped corpus';
  ok $result->{explored} > $result->{swept}, 'the campaign drove mutations against the live relay';
  is scalar(@{$result->{regressions}}), 0,
    'no mutation of any guarded attack reopens a hole against the hardened relay'
    or diag join "\n", map {"$_->{base}/$_->{label}"} @{$result->{regressions}};
};

done_testing;
