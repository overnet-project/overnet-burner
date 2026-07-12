use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Adversary::Driver::Scripted;

my $class = 'Overnet::Burner::Adversary::Driver::Scripted';

subtest 'the scripted driver validates its actions' => sub {
  like dies { $class->new(actions => 'nope') }, qr/actions\ must\ be\ an\ array/mx,
    'actions must be an array reference';
  like dies { $class->new(actions => [{payload => {}}]) }, qr/must\ be\ an\ object\ with\ a\ type/mx,
    'each action needs a type';
  like dies { $class->new(actions => [{type => q{}}]) }, qr/must\ be\ an\ object\ with\ a\ type/mx,
    'an empty type is rejected';
};

subtest 'the scripted driver accepts a single hash reference' => sub {
  my $driver = $class->new({actions => [{type => 'publish_control', payload => {n => 1}}]});
  is $driver->actions, [{type => 'publish_control', payload => {n => 1}}], 'the actions are stored';
};

subtest 'the scripted driver emits its actions once then stops' => sub {
  my $driver  = $class->new(actions => [{type => 'a'}, {type => 'b', payload => {list => [1, 2]}}]);
  my $emitted = $driver->next_actions({});
  is $emitted, [{type => 'a'}, {type => 'b', payload => {list => [1, 2]}}], 'the full list is emitted first';

  # The emitted actions are deep copies, not aliases into the driver's state.
  $emitted->[1]{payload}{list}[0] = 99;
  is $driver->actions->[1]{payload}{list}[0], 1, 'mutating the emitted copy does not affect the driver';

  is $driver->next_actions({}), [], 'subsequent calls emit nothing';
};

done_testing;
