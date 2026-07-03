use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Worker::Abuse;

my $class = 'Overnet::Burner::Worker::Abuse';

subtest 'core outcome and error categories map from NIP-01 OK prefixes' => sub {
  my @cases = (
    [1, q{},                                  'accepted',     undef],
    [1, 'duplicate: already have this',       'accepted',     undef],
    [0, 'invalid: bad signature',             'rejected',     'invalid input'],
    [0, 'blocked: rejected by policy',        'rejected',     'policy rejection'],
    [0, 'rate-limited: slow down',            'rejected',     'policy rejection'],
    [0, 'pow: insufficient proof of work',    'rejected',     'policy rejection'],
    [0, 'restricted: not permitted',          'rejected',     'authorization failure'],
    [0, 'auth-required: please authenticate', 'unauthorized', 'authentication failure'],
    [0, 'error: something broke',             'rejected',     'internal failure'],
    [0, 'mystery meat',                       'rejected',     'internal failure'],
  );

  for my $case (@cases) {
    my ($accepted, $message, $outcome, $category) = @{$case};
    my $result = $class->classify_response($accepted, $message);
    is $result->{outcome},        $outcome,  "outcome for '$message'";
    is $result->{error_category}, $category, "error category for '$message'";
  }
};

subtest 'a duplicate accept is recognised as explicit idempotent handling' => sub {
  my $result = $class->classify_response(1, 'duplicate: already have this event');
  ok $result->{duplicate}, 'a duplicate: prefix on an accept is flagged';

  my $plain = $class->classify_response(1, q{});
  ok !$plain->{duplicate}, 'a plain accept is not a duplicate';
};

subtest 'flooder defends on any rejection, correctly on resource protection' => sub {
  my $role = 'flooder';

  my $limited = $class->defense_for($role, $class->classify_response(0, 'rate-limited: slow down'));
  ok $limited->{defended},         'a rate-limited flood is defended';
  ok $limited->{defended_correct}, 'rate limiting is the correct flood defense';

  my $blocked = $class->defense_for($role, $class->classify_response(0, 'blocked: rejected by policy'));
  ok $blocked->{defended_correct}, 'a policy block is a correct flood defense';

  my $invalid = $class->defense_for($role, $class->classify_response(0, 'invalid: bad signature'));
  ok $invalid->{defended},          'any rejection stops the flood';
  ok !$invalid->{defended_correct}, 'rejecting a valid flood as invalid is the wrong defense';

  my $accepted = $class->defense_for($role, $class->classify_response(1, q{}));
  ok !$accepted->{defended}, 'an accepted flood event is a defense failure';
};

subtest 'malformed_publisher defends on rejection, correctly on invalid input' => sub {
  my $role = 'malformed_publisher';

  my $invalid = $class->defense_for($role, $class->classify_response(0, 'invalid: bad signature'));
  ok $invalid->{defended},         'a rejected malformed event is defended';
  ok $invalid->{defended_correct}, 'rejecting it as invalid input is the correct defense';

  my $internal = $class->defense_for($role, $class->classify_response(0, 'error: broke'));
  ok $internal->{defended},          'an internal-error rejection still stops the event';
  ok !$internal->{defended_correct}, 'but internal failure is the wrong category for a malformed event';

  my $accepted = $class->defense_for($role, $class->classify_response(1, q{}));
  ok !$accepted->{defended}, 'accepting a malformed event is a defense failure';
};

subtest 'replayer defends on duplicate handling or rejection' => sub {
  my $role = 'replayer';

  my $duplicate = $class->defense_for($role, $class->classify_response(1, 'duplicate: already have this event'));
  ok $duplicate->{defended},         'an explicit duplicate accept is defended';
  ok $duplicate->{defended_correct}, 'explicit duplicate handling is the correct defense';

  my $rejected = $class->defense_for($role, $class->classify_response(0, 'blocked: rejected by policy'));
  ok $rejected->{defended},         'a rejected replay is defended';
  ok $rejected->{defended_correct}, 'an explicit rejection is a correct replay defense';

  my $silent = $class->defense_for($role, $class->classify_response(1, q{}));
  ok !$silent->{defended}, 'a silent plain accept of a replay is a defense failure';
};

subtest 'subscription_abuser defends when the relay refuses the subscription' => sub {
  my $role = 'subscription_abuser';

  # EOSE is modelled as an accept (the subscription opened); CLOSED as a
  # rejection carrying the relay's reason.
  my $refused = $class->defense_for($role, $class->classify_response(0, 'error: too many subscriptions'));
  ok $refused->{defended},         'a refused subscription is defended';
  ok $refused->{defended_correct}, 'refusing an excess subscription with CLOSED is the correct mechanism';

  my $blocked = $class->defense_for($role, $class->classify_response(0, 'blocked: subscription quota exceeded'));
  ok $blocked->{defended_correct}, 'a policy refusal is also correct';

  my $opened = $class->defense_for($role, $class->classify_response(1, q{}));
  ok !$opened->{defended}, 'an opened subscription is a defense failure';
};

subtest 'status follows relay acceptance' => sub {
  is $class->classify_response(1, q{})->{status},                  'success', 'an accepted operation is success';
  is $class->classify_response(0, 'invalid: bad')->{status},       'error',   'a rejected operation is error';
  is $class->classify_response(1, 'duplicate: have it')->{status}, 'success', 'a duplicate accept is success';
};

done_testing;
