use strictures 2;

use Test2::V0;

use Overnet::Burner::Adversary::WireRelay;

# A stub event carrying just the id() the submitter correlates on.
{

  package t::StubEvent;
  sub new { return bless {id => $_[1]}, $_[0]; }
  sub id  { return $_[0]->{id}; }
}

# A stub client that accepts publish() but never delivers an OK, so the
# submitter's timeout path fires deterministically without a relay.
{

  package t::SilentClient;
  sub new        { return bless {}, $_[0]; }
  sub publish    { return 1; }
  sub disconnect { return 1; }
}

subtest 'submit before connect dies' => sub {
  my $wire = Overnet::Burner::Adversary::WireRelay->new(relay_url => 'ws://127.0.0.1:1');
  my $err  = dies { $wire->submit(t::StubEvent->new('abc')) };
  like $err, qr/not connected/, 'submit refuses before connect';
};

subtest 'submit times out when no OK arrives' => sub {
  my $wire = Overnet::Burner::Adversary::WireRelay->new(
    relay_url => 'ws://127.0.0.1:1',
    timeout   => 0.2,
  );
  $wire->_client(t::SilentClient->new);

  my ($accepted, $reason) = $wire->submit(t::StubEvent->new('deadbeef'));
  is $accepted, undef, 'a timed-out submit reports an undefined decision';
  like $reason, qr/timeout/, 'the reason names the timeout';

  ok $wire->disconnect, 'disconnect succeeds after a stubbed client';
};

subtest 'delivering to an unknown event id is a no-op' => sub {
  my $wire = Overnet::Burner::Adversary::WireRelay->new(relay_url => 'ws://127.0.0.1:1');
  ok $wire->_deliver('never-pending', [1, 'ignored']),
    'delivering with no pending waiter is harmless';
};

subtest 'disconnect is a no-op when never connected' => sub {
  my $wire = Overnet::Burner::Adversary::WireRelay->new(relay_url => 'ws://127.0.0.1:1');
  ok $wire->disconnect, 'disconnect on an unconnected adapter returns true';
};

done_testing;
