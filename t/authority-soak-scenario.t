use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Plan;

# The soak scenario's diagnostic power comes from running two DIFFERENT load
# shapes at once against one relay: a role whose group is recreated every cycle
# (so its own group stays small) alongside a role that hammers a single group
# for the whole run. Degradation in the first means the cost scales with total
# relay history; degradation in only the second means it scales with the group.
#
# A soak that quietly lost one of those roles, or pointed both at the same
# group, would still run for hours and still report a tidy zero error rate --
# while no longer being able to tell those two causes apart. So the shape is
# asserted here rather than trusted.

my $scenario = Overnet::Burner::Config->load_file("$FindBin::Bin/../scenarios/authority-soak.yml");
my $plan     = Overnet::Burner::Plan->build($scenario);

subtest 'the soak plans both load shapes against one relay' => sub {
  is [map { $_->{id} } @{$plan->{channel_lifecycles}}], ['channel-lifecycle-001'],
    'the fresh-group-per-cycle role is planned';
  is [map { $_->{id} } @{$plan->{control_publishers}}], ['control-publisher-001'],
    'the single-growing-group role is planned';

  is [map { $_->{endpoint} } @{$plan->{relays}}], ['ws://127.0.0.1:7448'],
    'both roles load the same relay, so their curves are comparable';
};

subtest 'the soak actually runs long enough to accumulate history' => sub {

  # An hour is the shortest run that showed the degradation clearly; the shipped
  # scenario asks for two. A "soak" trimmed to a minute would report health and
  # prove nothing, which is the failure this guards.
  ok $plan->{run}{duration_seconds} >= 3_600, 'the shipped duration is long enough for history to accumulate'
    or diag($plan->{run}{duration_seconds});
};

subtest 'the two roles do not share a group' => sub {

  # If the lifecycle role were pinned to the control role's persistent group,
  # both curves would degrade together and the "fresh group" signal -- the one
  # that proved the cost was global rather than per-group -- would be lost.
  my $control_group = $scenario->{workload}{control}{group};
  ok defined $control_group && length $control_group, 'the persistent group is named';

  my $lifecycle = $scenario->{workload}{lifecycle} || {};
  isnt $lifecycle->{group}, $control_group, 'the lifecycle role is not pinned to the persistent group';
};

done_testing;
