use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;

# The control publisher is an honest topology role: a scenario that places it
# must normalize, validate, plan into placed actors carrying the control
# workload on every phase, and dispatch to the reference worker class.

my $scenario = Overnet::Burner::Config->normalize(
  {
    run      => {name => 'control-wiring', duration => 30, seed => 7},
    topology => {
      relays             => {count => 1, provider => 'generic-relay', endpoints => ['ws://127.0.0.1:7448']},
      control_publishers => {count => 2},
    },
    workload => {
      publish_rate_per_second => 5,
      control => {grant_kind => 14142, group => 'burner-load', scope => 'overnet-burner://load'},
    },
  },
);

ok lives { Overnet::Burner::Config->validate($scenario) }, 'a control-publisher scenario validates';

my $plan = Overnet::Burner::Plan->build($scenario);

is [map { $_->{id} } @{$plan->{control_publishers}}], ['control-publisher-001', 'control-publisher-002'],
  'the plan expands the control_publishers count into stable ids';
is $plan->{control_publishers}[0]{role}, 'control_publisher', 'a planned actor carries the control_publisher role';

my ($phase) = @{$plan->{workload}{phases}};
is $phase->{control}, {grant_kind => 14142, group => 'burner-load', scope => 'overnet-burner://load'},
  'the control workload rides on every planned phase';

# The shipped example scenario is a real, plannable authority-control-load run.
my $example      = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/authority-control-load.yml");
my $example_plan = Overnet::Burner::Plan->build($example);
is [map { $_->{id} } @{$example_plan->{control_publishers}}], ['control-publisher-001'],
  'the authority-control-load example scenario plans a control publisher';

done_testing;
