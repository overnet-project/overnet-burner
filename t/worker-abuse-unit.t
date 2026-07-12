use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Net::Nostr::Relay;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Abuse;
use Overnet::Burner::Worker::ConnectionFlood;
use Overnet::Burner::Worker::Flooder;
use Overnet::Burner::Worker::MalformedPublisher;
use Overnet::Burner::Worker::ProvenanceForger;
use Overnet::Burner::Worker::Replayer;
use Overnet::Burner::Worker::Sybil;
use Overnet::Burner::Worker::SubscriptionAbuser;

my $ABUSE = 'Overnet::Burner::Worker::Abuse';

# In-process coverage for the abuse workers, targeting the classification and
# defense logic, the abstract-base contract, the publish/subscribe error and
# timeout paths, connection teardown, and provenance-forger helpers that the
# relay-driven t/worker-abuse.t does not reach.

subtest 'classify_response maps relay acknowledgements' => sub {
  is $ABUSE->classify_response(1, 'ok'),
    {status => 'success', outcome => 'accepted', error_category => undef, duplicate => 0},
    'a plain accept is a success';
  is $ABUSE->classify_response(1, 'duplicate: already stored')->{duplicate}, 1,
    'a duplicate accept is flagged';
  is $ABUSE->classify_response(0, 'invalid: bad signature'),
    {status => 'error', outcome => 'rejected', error_category => 'invalid input', duplicate => 0},
    'an invalid rejection is invalid input';
  is $ABUSE->classify_response(0, 'auth-required: sign in')->{outcome}, 'unauthorized',
    'an auth-required rejection is unauthorized';
  is $ABUSE->classify_response(0, undef)->{error_category}, 'internal failure',
    'an unprefixed rejection falls back to internal failure';
};

subtest 'defense_for scores each role model' => sub {
  is $ABUSE->defense_for('flooder', {outcome => 'accepted', error_category => undef, duplicate => 0}),
    {defended => 0, defended_correct => 0}, 'an accepted flood is not defended';
  is $ABUSE->defense_for('flooder', {outcome => 'rejected', error_category => 'policy rejection', duplicate => 0}),
    {defended => 1, defended_correct => 1}, 'a policy-rejected flood is correctly defended';
  is $ABUSE->defense_for('flooder', {outcome => 'rejected', error_category => 'invalid input', duplicate => 0}),
    {defended => 1, defended_correct => 0}, 'a flood rejected with the wrong category is defended but incorrect';
  is $ABUSE->defense_for('replayer', {outcome => 'accepted', error_category => undef, duplicate => 1}),
    {defended => 1, defended_correct => 1}, 'a recognized duplicate replay is a correct defense';
  is $ABUSE->defense_for('subscription_abuser', {outcome => 'rejected', error_category => undef, duplicate => 0}),
    {defended => 1, defended_correct => 1}, 'a refused subscription is correct by construction';
  like dies { $ABUSE->defense_for('mystery', {outcome => 'accepted'}) },
    qr/no\ defense\ model/mx, 'an unknown role is fatal';
};

subtest 'the abstract base refuses to act' => sub {
  like dies { $ABUSE->abuse_operation }, qr/must\ define\ abuse_operation/mx, 'abuse_operation is abstract';
  like dies { $ABUSE->build_event },     qr/must\ define\ build_event/mx,     'build_event is abstract';
  is $ABUSE->default_rate, 1, 'the base default rate is one operation per second';
};

subtest 'every abuse role declares a default rate' => sub {
  is(Overnet::Burner::Worker::Flooder->default_rate,            1000, 'flooder floods hard');
  is(Overnet::Burner::Worker::Sybil->default_rate,             50,   'sybil churns fast');
  is(Overnet::Burner::Worker::MalformedPublisher->default_rate, 5,   'malformed publisher default');
  is(Overnet::Burner::Worker::Replayer->default_rate,           5,   'replayer default');
  is(Overnet::Burner::Worker::ConnectionFlood->default_rate,    20,  'connection flood default');
  is(Overnet::Burner::Worker::SubscriptionAbuser->default_rate, 20,  'subscription abuser default');
  is(Overnet::Burner::Worker::ProvenanceForger->default_rate,   5,   'provenance forger default');
};

subtest 'the abuse rate falls back to the default when unconfigured' => sub {
  my $flooder = Overnet::Burner::Worker::Flooder->new(input => _input('ab-rate', 'flooder'));
  is $flooder->_abuse_rate({}), 1000, 'a phase without an abuse rate uses the default';
  is $flooder->_abuse_rate({abuse => {flooder => {publish_rate_per_second => 7}}}), 7,
    'a configured phase rate is honored';
};

subtest 'publish_event reports a lost connection and a timeout' => sub {
  my $flooder = Overnet::Burner::Worker::Flooder->new(input => _input('ab-pub', 'flooder'));
  my $key     = $flooder->derive_key(12345, 'flooder');
  my $event   = $flooder->build_event($key, 1);

  my ($accepted, $message) = $flooder->publish_event(_client(publish_dies => 1), $event, {});
  is $accepted, 0, 'a failed send is not accepted';
  is $message, 'error: relay connection lost', 'a failed send reports a lost connection';

  ($accepted, $message) = $flooder->publish_event(_client(), $event, {});
  is $accepted, 0, 'an unacknowledged publish is not accepted';
  is $message, 'error: abuse operation timed out', 'an unacknowledged publish times out';
};

subtest 'an idle abuse phase paces nothing' => sub {
  my $flooder = Overnet::Burner::Worker::Flooder->new(input => _input('ab-idle', 'flooder'));
  my $stop    = 0;
  my $done    = $flooder->_run_phase(
    client  => _client(),
    key     => $flooder->derive_key(12345, 'flooder'),
    pending => {},
    phase   => {name => 'idle', start_seconds => 0, duration_seconds => 0, abuse => {flooder => {publish_rate_per_second => 0}}},
    started => time,
    stop    => \$stop,
  );
  is $done, 1, 'the idle phase returns cleanly';
};

subtest 'connection teardown is best effort' => sub {
  my $cf = Overnet::Burner::Worker::ConnectionFlood->new(input => _input('ab-tear', 'connection_flood'));
  is $cf->teardown_abuse, 1, 'tearing down with no held connections succeeds';

  $cf->{held_connections} = [_client(disconnect_dies => 1), _client()];
  is $cf->teardown_abuse, 1, 'a connection that fails to close does not abort teardown';
  is $cf->{held_connections}, [], 'teardown clears the held connections';
};

subtest 'subscription abuse reports a lost connection and a timeout' => sub {
  my $sa  = Overnet::Burner::Worker::SubscriptionAbuser->new(input => _input('ab-sub', 'subscription_abuser'));
  my $key = $sa->derive_key(12345, 'subscription_abuser');

  my ($accepted, $message) =
    $sa->perform_abuse(client => _client(subscribe_dies => 1), key => $key, pending => {}, sequence => 1, phase => 'main');
  is $accepted, 0, 'a failed subscribe is not accepted';
  is $message, 'error: relay connection lost', 'a failed subscribe reports a lost connection';

  ($accepted, $message) =
    $sa->perform_abuse(client => _client(), key => $key, pending => {}, sequence => 2, phase => 'main');
  is $accepted, 0, 'an unresolved subscription is not accepted';
  is $message, 'error: subscription timed out', 'an unresolved subscription times out';
};

subtest 'the provenance forger verifies and configures itself' => sub {
  my $forger =
    Overnet::Burner::Worker::ProvenanceForger->new(input => _input('ab-forge', 'provenance_forger'));
  is $forger->_verify_forged_event, 'unresolvable',
    'verification without a built event is unresolvable';
  is $forger->_forge_config->{protocol}, 'irc', 'a run without an abuse block uses the defaults';

  my ($classification) = $forger->classify_abuse(
    accepted => 0, message => 'error: refused', key => $forger->derive_key(12345, 'ab-forge'),
    sequence => 1, phase => 'main', relay_url => 'ws://127.0.0.1:1',
  );
  is $classification->{status}, 'error', 'a relay that refused to carry the forgery is an error status';

  # The authority key is derived once and cached; call it twice.
  is $forger->_authority_key->pubkey_hex, $forger->_authority_key->pubkey_hex,
    'the authority identity is stable across calls';

  my $configured = Overnet::Burner::Worker::ProvenanceForger->new(
    input => _input('ab-forge2', 'provenance_forger', {provenance_forger => {origin => 'example.test/#room'}}),
  );
  is $configured->_forge_config->{origin}, 'example.test/#room', 'a configured origin overrides the default';
  is $configured->_forge_config->{protocol}, 'irc', 'unset fields keep their defaults';
};

subtest 'subscription response handlers resolve pending waiters only' => sub {
  my $sa = Overnet::Burner::Worker::SubscriptionAbuser->new(input => _input('ab-handlers', 'subscription_abuser'));
  my %handlers;
  my $client = bless {handlers => \%handlers}, '_CapturingClient';
  my %pending;
  $sa->register_response_handlers($client, \%pending);

  my $waiter = AnyEvent->condvar;
  $pending{'sub-open'} = $waiter;
  $handlers{eose}->('sub-open');
  is $waiter->recv, [1, q{}], 'an EOSE opens the tracked subscription';

  # A CLOSED for a subscription that is no longer pending is ignored.
  ok !exists $pending{'sub-unknown'}, 'the unknown subscription starts absent';
  $handlers{closed}->('sub-unknown', 'blocked: too many subscriptions');
  ok !exists $pending{'sub-unknown'}, 'a response for an untracked subscription is dropped';
};

subtest 'a TERM signal stops an abuse run between phases' => sub {
  my $port  = _free_port();
  my $relay = _spawn_relay($port);

  my $run_dir = _run_layout('ab-term');
  my $input   = _worker_input($run_dir, $port, 'ab-term', 'flooder', 10);
  $input->{phases} = [
    {name => 'p1', start_seconds => 0, duration_seconds => 5, abuse => {flooder => {publish_rate_per_second => 50}}},
    {name => 'p2', start_seconds => 5, duration_seconds => 5, abuse => {flooder => {publish_rate_per_second => 50}}},
  ];
  my $flooder = Overnet::Burner::Worker::Flooder->new(input => $input);

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { sleep 0.6; kill 'TERM', $parent; exit 0 }

  $flooder->run;
  waitpid $killer, 0;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'ab-term.jsonl'));
  my @phase2 = grep { $_->{phase} eq 'p2' } @{$stream};
  is \@phase2, [], 'the flooder stopped before the second phase';

  kill 'TERM', $relay;
  waitpid $relay, 0;
};

done_testing;

sub _client { return bless {@_}, '_FakeAbuseClient' }

sub _input {
  my ($worker_id, $role, $abuse) = @_;
  my %workload = defined $abuse ? (abuse => $abuse) : ();
  return {
    input_version    => 1,
    run_id           => 'run',
    run_dir          => _run_layout($worker_id),
    worker_id        => $worker_id,
    role             => $role,
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    workload         => \%workload,
  };
}

sub _worker_input {
  my ($run_dir, $port, $worker_id, $role, $duration) = @_;
  return {
    input_version    => 1,
    run_id           => 'run',
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => $role,
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {},
  };
}

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _spawn_relay {
  my ($port) = @_;
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    exec $^X, '-MNet::Nostr::Relay', '-e',
      'Net::Nostr::Relay->new->run($ARGV[0], $ARGV[1])', '127.0.0.1', $port
      or die "exec: $!";
  }
  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) { close $probe or die "close: $!"; return $pid }
    if (waitpid($pid, WNOHANG) != 0) { die "relay exited before listening\n" }
    sleep 0.1;
  }
  die "relay never listened on port $port\n";
}

package _FakeAbuseClient;
sub is_connected { return 1 }
sub connect      { return 1 }
sub publish      { my ($self) = @_; die "publish failed\n" if $self->{publish_dies}; return 1 }
sub subscribe    { my ($self) = @_; die "subscribe failed\n" if $self->{subscribe_dies}; return 1 }
sub disconnect   { my ($self) = @_; die "disconnect failed\n" if $self->{disconnect_dies}; return 1 }
sub on           { return 1 }

package _CapturingClient;
sub on { my ($self, $name, $cb) = @_; $self->{handlers}{$name} = $cb; return 1 }
