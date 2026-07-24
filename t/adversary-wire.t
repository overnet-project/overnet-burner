use strictures 2;

use Test2::V0;

use IO::Socket::INET;
use Time::HiRes qw(sleep);

use Overnet::Burner::Adversary::Arena::Wire;

# The wire arena needs the real relay dist; skip cleanly where it is absent.
BEGIN {
  eval { require Overnet::Authority::HostedChannel::Relay; 1 }
    or plan skip_all => 'Overnet::Authority::HostedChannel::Relay not available';
}

sub _free_port {
  my $sock = IO::Socket::INET->new(Proto => 'tcp', LocalAddr => '127.0.0.1', Listen => 1)
    or die "cannot allocate a port: $!";
  my $port = $sock->sockport;
  $sock->close;
  return $port;
}

sub _wait_for_listener {
  my ($port) = @_;
  for (1 .. 100) {
    my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1);
    if ($sock) { $sock->close; return 1; }
    sleep 0.1;
  }
  return 0;
}

my $port      = _free_port();
my $relay_url = "ws://127.0.0.1:$port";

# Run a real authoritative relay in a child process; the arena drives it over a
# real WebSocket from the parent.
my $relay_pid = fork;
defined $relay_pid or die "fork failed: $!";
if ($relay_pid == 0) {
  my $relay = Overnet::Authority::HostedChannel::Relay::build_authoritative_relay(
    relay_url  => $relay_url,
    grant_kind => 14142,
  );
  $relay->run('127.0.0.1', $port);
  exit 0;
}

ok _wait_for_listener($port), "authority relay is listening on $port"
  or do { kill 'TERM', $relay_pid; waitpid $relay_pid, 0; done_testing; exit };

my $arena = Overnet::Burner::Adversary::Arena::Wire->new(
  relay_url => $relay_url,
  seed      => 'wire-1',
);

like $arena->baseline_ref, qr/\Awire:\Q$relay_url\E\z/, 'baseline_ref names the wire endpoint';

$arena->reset;

# A delegation grant is accepted unconditionally by the authority relay, so the
# relay's OK crossing the wire as accepted proves the accept path.
my $grant_obs = $arena->apply(
  {type => 'publish_grant', payload => {actor => 'attacker', delegate => 'session', id => 'g1'}});
is $grant_obs->[0]{type}, 'relay_outcome', 'publish_grant yields a relay_outcome';
ok $grant_obs->[0]{payload}{accepted}, 'the relay accepted the grant over the wire';

# An operator control event from a subject with no operator authority must be
# rejected -- the relay's rejection (and reason) crossing the wire proves the
# reject path and the authorization oracle signal.
my $control_obs = $arena->apply(
  {
    type    => 'publish_control',
    payload => {
      signer => 'attacker', actor => 'attacker', authority => 'g1', kind => 9000,
      roles  => [{subject => 'attacker', role => 'irc.operator'}],
    },
  });
ok !$control_obs->[0]{payload}{accepted}, 'the relay rejected the unauthorized control over the wire';
like $control_obs->[0]{payload}{reason}, qr/\S/, 'the rejection carries a reason from the relay';

# A join exercises the provisioning-grant path (persist_grant) over the wire.
my $join_obs = $arena->apply(
  {type => 'join', payload => {actor => 'attacker', scope => 'irc://irc.example/localnet'}});
my ($join_outcome) = grep { $_->{type} eq 'relay_outcome' } @{$join_obs};
ok $join_outcome, 'join yields a relay_outcome over the wire';

# Probe-based observations have no faithful wire equivalent and must refuse.
my $probe_error = dies {
  $arena->apply({type => 'observe_capability', payload => {subject => 'attacker', scope => 's'}});
};
like $probe_error, qr/not supported over the wire/, 'capability probes refuse over the wire';

# Reset reconnects (and disconnects the previous connection).
$arena->reset;
ok $arena->apply({type => 'new_identity', payload => {name => 'attacker'}}),
  'the arena is usable again after reset';

$arena->_sut->disconnect;

kill 'TERM', $relay_pid;
waitpid $relay_pid, 0;

done_testing;
