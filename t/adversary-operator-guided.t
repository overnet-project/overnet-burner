use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Adversary::Operator::Guided;
use Overnet::Burner::Adversary::Fuzzer;

# The guided operator is the fuzzer's model-guided mutation seam: it mutates an
# attack within the application's own vocabulary and identity graph, reaching
# semantic holes the built-in structural operators (drop, duplicate, swap,
# collide) cannot express.

my $GUIDED = 'Overnet::Burner::Adversary::Operator::Guided';
my $VOCAB  = {
  capabilities => ['irc.operator'],
  scopes       => ['channel:#ops', 'channel:#staff'],
  grant_kinds  => [9000,           39_001],
  action_types => [qw(publish_control observe_capability)],
};

# A system under test with an identity-confusion hole: it reports whatever
# subject an observe names as holding operator, so observing any identity but the
# real operator leaks the capability. Only a semantic identity substitution
# reaches it.
{

  package IdentityConfusingArena;
  sub new          { my ($class) = @_; return bless {}, $class }
  sub baseline_ref { return 'stub:identity-confusing' }
  sub reset        {return}                                        ## no critic (ProhibitBuiltinHomonyms)

  sub apply {
    my ($self, $action) = @_;
    if ($action->{type} eq 'observe_capability') {
      return [
        {
          type    => 'observed_capability',
          payload => {
            subject    => $action->{payload}{subject},
            capability => 'irc.operator',
            scope      => $action->{payload}{scope},
          },
        },
      ];
    }
    return [];
  }
}

subtest 'the guided operator substitutes in-model values one field at a time' => sub {
  my $guided = $GUIDED->new(vocabulary => $VOCAB, identities => ['attacker']);

  my $base = [
    {type => 'publish_control',    payload => {actor   => 'operator', kind  => 9000, role => 'irc.operator'}},
    {type => 'observe_capability', payload => {subject => 'operator', scope => 'channel:#ops'}},
  ];
  my $mutants  = $guided->mutate($base);
  my %by_label = map { $_->{label} => $_ } @{$mutants};

  # Identity substitution draws from the attack's graph (operator) plus the
  # configured pool (attacker): actor operator -> attacker.
  ok $by_label{'actor=attacker@0'}, 'an actor identity is substituted with another in-graph identity';
  is $by_label{'actor=attacker@0'}{actions}[0]{payload}{actor}, 'attacker', 'the substitution is applied in place';
  is $by_label{'actor=attacker@0'}{actions}[1], $base->[1], 'other actions are carried through unchanged';

  # Vocabulary substitution: the grant kind and scope swap to the other
  # vocabulary value; the capability role swaps among the capabilities (only one,
  # so no mutant); the scope has two, so it mutates.
  ok $by_label{'kind=39001@0'},           'a grant kind is substituted with another vocabulary kind';
  ok $by_label{'scope=channel:#staff@1'}, 'a scope is substituted with another vocabulary scope';

  # Never a no-op: no mutant equals its base value.
  ok !$by_label{'actor=operator@0'},    'no mutant substitutes a value with itself';
  ok !$by_label{'role=irc.operator@0'}, 'a single-value domain yields no substitution';

  # The operator wrapper returns the same mutants as a code reference.
  my $op = $guided->operator;
  is scalar @{$op->($base)}, scalar @{$mutants}, 'the operator code reference yields the same mutant set';
};

subtest 'the model seam replaces the proposer in the same slot' => sub {
  my $seen_context;
  my $guided = $GUIDED->new(
    vocabulary => $VOCAB,
    identities => ['attacker'],
    propose    => sub {
      my ($context) = @_;
      $seen_context = $context;
      return [{label => 'model-mutant', actions => [{type => 'observe_capability', payload => {subject => 'ghost'}}]}];
    },
  );

  my $base    = [{type => 'observe_capability', payload => {subject => 'operator', scope => 'channel:#ops'}}];
  my $mutants = $guided->mutate($base);
  is scalar @{$mutants},   1,              'the model proposer decides the mutants';
  is $mutants->[0]{label}, 'model-mutant', 'the model mutant is forwarded';

  is $seen_context->{vocabulary},           $VOCAB, 'the model is handed the vocabulary it may draw from';
  is [sort @{$seen_context->{identities}}], ['attacker', 'operator'], 'the model is handed the identity pool';
  is $seen_context->{actions},              $base,                    'the model is handed the base attack';

  # The forwarded mutant is a copy, not the proposer's own reference.
  $mutants->[0]{actions}[0]{payload}{subject} = 'mutated';
  my $again = $guided->mutate($base);
  is $again->[0]{actions}[0]{payload}{subject}, 'ghost', 'each call returns an independent copy';
};

subtest 'malformed inputs and proposals are rejected' => sub {
  like dies { $GUIDED->new(vocabulary => 'x') }, qr/vocabulary\ must\ be\ a\ hash\ reference/mx,
    'the vocabulary must be a hash reference';
  like dies { $GUIDED->new(vocabulary => {}, propose => 'x') }, qr/propose\ must\ be\ a\ code\ reference/mx,
    'the propose seam must be a code reference';
  like dies { $GUIDED->new(vocabulary => {}, identities => 'x') }, qr/identities\ must\ be\ an\ array/mx,
    'identities must be an array reference';

  my $guided = $GUIDED->new(vocabulary => $VOCAB);
  like dies { $guided->mutate('x') }, qr/actions\ must\ be\ an\ array/mx, 'the base must be an array reference';

  my $bad_shape = $GUIDED->new(vocabulary => $VOCAB, propose => sub { return 'x' });
  like dies { $bad_shape->mutate([]) }, qr/propose\ must\ return\ an\ array/mx, 'a non-array proposal is rejected';

  my $bad_mutant = $GUIDED->new(vocabulary => $VOCAB, propose => sub { return [{actions => []}] });
  like dies { $bad_mutant->mutate([]) }, qr/must\ have\ a\ label/mx, 'a mutant without a label is rejected';
};

subtest 'the guided proposer skips malformed actions and ill-typed values' => sub {
  my $guided = $GUIDED->new(vocabulary => $VOCAB, identities => ['attacker', q{}, undef]);

  my $base = [
    'not-a-hash',
    {type => 'noop'},                                                                             # no payload
    {type => 'observe_capability', payload => {subject => 'operator', scope => {nested => 1}}},
  ];
  my $mutants  = $guided->mutate($base);
  my %by_label = map { $_->{label} => 1 } @{$mutants};

  ok $by_label{'subject=attacker@2'},     'a well-formed identity field in a valid action still mutates';
  ok !(grep {/scope=/mx} keys %by_label), 'a reference-valued field is skipped, not stringified';
  ok !$by_label{'subject=@2'},            'an empty or undefined configured identity is not a substitution value';

  my $no_scopes = $GUIDED->new(vocabulary => {capabilities => ['irc.operator']});
  my $out =
    $no_scopes->mutate([{type => 'observe_capability', payload => {subject => 'op', scope => 'channel:#ops'}}]);
  ok !(grep { $_->{label} =~ /\Ascope=/mx } @{$out}), 'a vocabulary without a scopes list yields no scope substitution';
};

subtest 'the fuzzer finds a semantic hole the structural operators miss' => sub {
  my $base = [{type => 'observe_capability', payload => {subject => 'operator', scope => 'channel:#ops'}}];
  my $ground_truth =
    {authorized_capabilities => [{subject => 'operator', capability => 'irc.operator', scope => 'channel:#ops'}]};

  my $guided      = $GUIDED->new(vocabulary => $VOCAB, identities => ['attacker']);
  my $with_guided = Overnet::Burner::Adversary::Fuzzer->new(
    arena_factory => sub { return IdentityConfusingArena->new },
    operators     => [$guided->operator],
  );
  my $found = $with_guided->explore(base => $base, ground_truth => $ground_truth, seed => '1');

  ok scalar(@{$found->{findings}}), 'the guided operator surfaces at least one violation';
  my %labels = map { $_->{label} => 1 } @{$found->{findings}};
  ok $labels{'subject=attacker@0'}, 'substituting the observed subject to the attacker leaks the capability';
  ok !$labels{'identity'},          'the unmutated base attack, observing the real operator, is not a finding';

  # The structural operators cannot express "observe a different subject", so
  # they explore the neighbourhood and find nothing.
  my $with_structural =
    Overnet::Burner::Adversary::Fuzzer->new(arena_factory => sub { return IdentityConfusingArena->new },);
  my $structural = $with_structural->explore(base => $base, ground_truth => $ground_truth, seed => '1');
  ok $structural->{explored} >= 1, 'the structural operators explored the neighbourhood';
  is scalar @{$structural->{findings}}, 0, 'the structural operators miss the identity-confusion hole';
};

done_testing;
