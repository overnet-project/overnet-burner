use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Adversary::Arena::Recorded;

my $class = 'Overnet::Burner::Adversary::Arena::Recorded';

subtest 'the constructor validates its recorded responses' => sub {
  like dies { $class->new(baseline_ref => ['ref']) }, qr/baseline_ref\ must\ be\ a\ scalar/mx,
    'baseline_ref must be a scalar';
  like dies { $class->new(responses => 'nope') }, qr/responses\ must\ be\ an\ array/mx,
    'responses must be an array reference';
  like dies { $class->new(responses => ['not-a-batch']) }, qr/each\ response\ batch\ must\ be\ an\ array/mx,
    'each batch must be an array reference';
  like dies { $class->new(responses => [[{payload => {}}]]) }, qr/must\ be\ an\ object\ with\ a\ type/mx,
    'each recorded observation needs a type';
};

subtest 'defaults and the single hash reference constructor' => sub {
  my $arena = $class->new({});
  is $arena->baseline_ref, 'recorded', 'the baseline ref defaults';
  is $arena->responses,    [],         'responses default to an empty list';
};

subtest 'apply replays recorded batches then yields nothing' => sub {
  my $arena = $class->new(
    baseline_ref => 'fixture',
    responses    => [
      [{type => 'relay_outcome', payload => {accepted => 1, tags => ['a', 'b']}}],
      [{type => 'observed_capability'}],
    ],
  );
  $arena->reset;
  like dies { $arena->apply('not-a-hash') }, qr/apply\ expects\ an\ action\ object/mx, 'apply validates its action';

  is $arena->apply({type => 'a'}), [{type => 'relay_outcome', payload => {accepted => 1, tags => ['a', 'b']}}],
    'the first batch is replayed as a deep copy';
  is $arena->apply({type => 'b'}), [{type => 'observed_capability'}], 'the second batch is replayed';
  is $arena->apply({type => 'c'}), [], 'past the recorded batches, nothing is returned';
};

done_testing;
