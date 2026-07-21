use strictures 2;

use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use IO::Socket::INET;
use JSON   ();
use POSIX  qw(WNOHANG);
use Socket qw(SOL_SOCKET SO_LINGER);

use Overnet::Burner::Adversary::Server;

my $JSON = JSON->new->utf8->canonical;

my $ATTACKER_CAP = {subject => 'attacker', capability => 'irc.operator', scope => 'channel:#ops'};
my $OPERATOR_CAP = {subject => 'operator', capability => 'irc.operator', scope => 'channel:#ops'};

# A recorded arena lets the server's whole loop be exercised deterministically
# with no live relay: one action yields the aligned observation batch.
sub _create_recorded {
  my ($server, $id, %args) = @_;
  return $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {
      session_id => $id,
      arena      => {
        type      => 'recorded',
        responses => [
          [
            {type => 'relay_outcome',       payload => {accepted => 1}},
            {type => 'observed_capability', payload => $ATTACKER_CAP},
          ],
        ],
      },
      ground_truth => {authorized_capabilities => [$OPERATOR_CAP]},
      %args,
    },
  );
}

subtest 'health check' => sub {
  my $response = Overnet::Burner::Adversary::Server->new->dispatch(method => 'GET', path => '/health');
  is $response->{status}, 200, 'health is 200';
  is $response->{body}, {status => 'ok'}, 'health reports ok';
};

subtest 'a full session lifecycle over the API' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;

  my $created = _create_recorded($server, 'sess-1');
  is $created->{status},             201,        'create returns 201';
  is $created->{body}{session_id},   'sess-1',   'create echoes the session id';
  is $created->{body}{baseline_ref}, 'recorded', 'create reports the arena baseline';

  my $stepped = $server->dispatch(
    method => 'POST',
    path   => '/sessions/sess-1/actions',
    body   => {actions => [{type => 'publish_control', payload => {kind => 9001}}]},
  );
  is $stepped->{status}, 200, 'submitting an action returns 200';
  my @types = map { $_->{type} } @{$stepped->{body}{observations}};
  is \@types, ['relay_outcome', 'observed_capability'], 'the arena observations flow back to the driver';
  ok defined $stepped->{body}{observations}[0]{seq}, 'observations carry their session seq';

  my $verdict = $server->dispatch(method => 'GET', path => '/sessions/sess-1/verdict');
  is $verdict->{status}, 200, 'verdict returns 200';
  ok $verdict->{body}{verdict}{violated}, 'the oracle catches the unauthorized capability recorded over the API';
  is $verdict->{body}{verdict}{invariants}{authorization}{status}, 'violated', 'authorization invariant fires';

  my $summary = $server->dispatch(method => 'GET', path => '/sessions/sess-1');
  is $summary->{status}, 200, 'summary returns 200';
  ok $summary->{body}{step_count} >= 3, 'the summary counts the recorded steps';

  my $log = $server->dispatch(method => 'GET', path => '/sessions/sess-1/log');
  is $log->{status}, 200, 'log returns 200';
  like $log->{body}{jsonl}, qr/observed_capability/mx, 'the log is the replayable session jsonl';

  my $closed = $server->dispatch(method => 'DELETE', path => '/sessions/sess-1');
  is $closed->{status},       200, 'delete returns 200';
  is $closed->{body}{closed}, 1,   'delete reports the session closed';

  my $gone = $server->dispatch(method => 'GET', path => '/sessions/sess-1');
  is $gone->{status}, 404, 'a deleted session is gone';
};

subtest 'the session built over the API matches a runner-built session' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;
  _create_recorded($server, 'sess-parity');
  $server->dispatch(
    method => 'POST',
    path   => '/sessions/sess-parity/actions',
    body   => {action => {type => 'publish_control', payload => {kind => 9001}}},
  );

  my $verdict = $server->dispatch(method => 'GET', path => '/sessions/sess-parity/verdict');
  my $finding = $verdict->{body}{verdict}{findings}[0];
  is $finding->{subject}, 'attacker',     'the over-the-API verdict names the escalating subject';
  is $finding->{scope},   'channel:#ops', 'the finding carries the scope';
};

subtest 'a multi-action submit advances the session per action' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;
  $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {
      session_id => 'sess-multi',
      arena      => {type => 'recorded', responses => [[{type => 'relay_outcome', payload => {accepted => 0}}], []]},
    },
  );

  my $stepped = $server->dispatch(
    method => 'POST',
    path   => '/sessions/sess-multi/actions',
    body   => {actions => [{type => 'a'}, {type => 'b'}]},
  );
  is $stepped->{status},                        200, 'a two-action submit succeeds';
  is scalar(@{$stepped->{body}{observations}}), 1,   'only the first action had a recorded observation batch';
  is $stepped->{body}{step_count}, 4, 'the session records the meta record plus two actions and one observation';
};

subtest 'the API validates its requests' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;

  is $server->dispatch(method => 'GET', path => '/nope')->{status}, 404, 'unknown route is 404';
  is $server->dispatch(method => 'POST', path => '/sessions', body => {})->{status}, 400,
    'creating without a session id is 400';
  is $server->dispatch(method => 'POST', path => '/sessions', body => [])->{status}, 400, 'a non-object body is 400';

  _create_recorded($server, 'sess-dup');
  is _create_recorded($server, 'sess-dup')->{status}, 409, 'a duplicate session id is 409';

  is $server->dispatch(method => 'GET', path => '/sessions/ghost/verdict')->{status}, 404,
    'acting on a missing session is 404';
  is $server->dispatch(method => 'POST', path => '/sessions/sess-dup/actions', body => {})->{status}, 400,
    'submitting with no action is 400';
  is $server->dispatch(method => 'POST', path => '/sessions/sess-dup/actions', body => {actions => {}})->{status}, 400,
    'actions must be an array';
};

subtest 'the step limit is enforced' => sub {
  my $server = Overnet::Burner::Adversary::Server->new(max_steps_per_session => 1);
  $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {session_id => 'sess-cap', arena => {type => 'recorded', responses => []}},
  );
  my $over = $server->dispatch(
    method => 'POST',
    path   => '/sessions/sess-cap/actions',
    body   => {actions => [{type => 'a'}, {type => 'b'}]},
  );
  is $over->{status}, 429, 'exceeding the per-session step limit is 429';
};

# The live arena is built through the adversary application-profile registry, so
# a live spec may name a profile. Arena construction is lazy about the relay
# dist, so this needs no relay checkout.
subtest 'a live arena selects an adversary application profile' => sub {
  my $default = Overnet::Burner::Adversary::Server::_default_arena({type => 'live', seed => '1'});
  ok ref($default) && $default->can('apply') && $default->can('reset'),
    'a live arena builds without naming a profile (the default)';

  my $named =
    Overnet::Burner::Adversary::Server::_default_arena({type => 'live', profile => 'irc-hosted-channel', seed => '1'});
  is ref($named), ref($default), 'naming the default profile builds the same arena class';

  like dies { Overnet::Burner::Adversary::Server::_default_arena({type => 'live', profile => 'no-such-app'}) },
    qr/unknown\ adversary\ profile/mx, 'an unregistered profile is rejected';
};

# End-to-end over the API against the real relay: create a live session, drive
# the C1 forged-grant escalation as an external driver would, and confirm the
# hardened relay defends it.
subtest 'driving the live relay through the API defends C1' => sub {
  my $relay_available = eval { require Overnet::Authority::HostedChannel::Relay; 1 };
  if (!$relay_available) {
    skip_all 'relay-perl not available';
  }

  my $server  = Overnet::Burner::Adversary::Server->new;
  my $created = $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {
      session_id   => 'live-api',
      seed         => '1',
      arena        => {type                    => 'live', snapshot_signers => ['snapshot-authority'], seed => '1'},
      ground_truth => {authorized_capabilities => [$OPERATOR_CAP]},
    },
  );
  is $created->{status}, 201, 'a live session is created over the API';
  like $created->{body}{baseline_ref}, qr/HostedChannel::Relay/mx, 'the baseline names the live relay';

  my @actions = (
    {type => 'new_identity',  payload => {name  => 'operator'}},
    {type => 'publish_grant', payload => {actor => 'operator', delegate => 'operator-session', id => 'operator-grant'}},
    {
      type    => 'publish_control',
      payload => {
        signer    => 'operator-session',
        actor     => 'operator',
        authority => 'operator-grant',
        kind      => 9_000,
        roles     => [{subject => 'operator', role => 'irc.operator'}],
      },
    },
    {type => 'publish_grant', payload => {actor => 'attacker', delegate => 'attacker-session', id => 'forged-grant'}},
    {
      type    => 'publish_control',
      payload => {
        signer    => 'attacker-session',
        actor     => 'operator',
        authority => 'forged-grant',
        kind      => 9_001,
        roles     => [{subject => 'attacker', role => 'irc.operator'}],
      },
    },
    {type => 'observe_capability', payload => {subject => 'attacker', scope => 'channel:#ops'}},
    {type => 'observe_capability', payload => {subject => 'operator', scope => 'channel:#ops'}},
  );
  my $stepped = $server->dispatch(
    method => 'POST',
    path   => '/sessions/live-api/actions',
    body   => {actions => \@actions},
  );
  is $stepped->{status}, 200, 'the attack drives through the live arena over the API';

  my $verdict = $server->dispatch(method => 'GET', path => '/sessions/live-api/verdict');
  ok !$verdict->{body}{verdict}{violated}, 'the live relay defends C1 driven over the API';
};

# The bin binding: prove the HTTP transport actually serves the API.
subtest 'the HTTP binding serves the API over a socket' => sub {
  my $port = _free_port();
  my $pid  = _spawn_server($port);

  my ($health_status, $health) = _http($port, 'GET', '/health');
  is $health_status,    200,  'GET /health over HTTP is 200';
  is $health->{status}, 'ok', 'the socket server reports ok';

  my ($created_status) = _http(
    $port, 'POST',
    '/sessions',
    {
      session_id => 'http-1',
      arena      => {type => 'recorded', responses => [[{type => 'relay_outcome', payload => {accepted => 1}}]]}
    },
  );
  is $created_status, 201, 'POST /sessions over HTTP creates a session';

  my ($action_status, $action) =
    _http($port, 'POST', '/sessions/http-1/actions', {actions => [{type => 'publish_control', payload => {}}]},);
  is $action_status,                   200,             'POST /actions over HTTP steps the session';
  is $action->{observations}[0]{type}, 'relay_outcome', 'the HTTP response carries the observations';

  kill 'TERM', $pid;
  waitpid $pid, 0;
};

subtest 'dispatch defaults, routing gaps, and arena errors' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;

  is $server->dispatch->{status}, 404, 'dispatch with no method or path defaults to GET / and 404s';

  _create_recorded($server, 'sess-route');
  is $server->dispatch(method => 'POST', path => '/sessions/sess-route')->{status}, 404,
    'an unsupported method on a session route is 404';

  # A session created without an arena spec falls back to a recorded arena.
  my $defaulted = $server->dispatch(method => 'POST', path => '/sessions', body => {session_id => 'sess-default'});
  is $defaulted->{status}, 201, 'a session without an arena spec defaults to recorded';

  is $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {session_id => 'sess-gt', arena => {type => 'recorded', responses => []}, ground_truth => 'nope'},
  )->{status}, 400, 'a non-object ground_truth is 400';

  is $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {session_id => 'sess-bad-arena', arena => 'not-a-hash'},
  )->{status}, 400, 'a non-object arena spec is 400';

  is $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {session_id => 'sess-unknown-arena', arena => {type => 'imaginary'}},
  )->{status}, 400, 'an unknown arena type is 400';
};

subtest 'a session can be closed and is then gone' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;
  _create_recorded($server, 'sess-close');
  is $server->dispatch(method => 'DELETE', path => '/sessions/sess-close')->{status}, 200,
    'a session can be closed';
  is $server->dispatch(method => 'GET', path => '/sessions/sess-close')->{status}, 404,
    'a closed session no longer exists';
};

subtest 'an arena missing the interface is rejected' => sub {
  my $server = Overnet::Burner::Adversary::Server->new(arena_factory => sub { return bless {}, 'IncompleteArena' });
  is $server->dispatch(method => 'POST', path => '/sessions', body => {session_id => 'sess-incomplete'})->{status}, 400,
    'an arena that does not implement the interface is 400';
};

subtest 'the socket loop survives hostile clients' => sub {
  local $ENV{OVERNET_BURNER_ADVERSARY_READ_TIMEOUT} = 1;
  local $ENV{OVERNET_BURNER_ADVERSARY_MAX_BODY}     = 1024;
  my $port = _free_port();
  my $pid  = _spawn_server($port);

  # A client that sends a request then abortively resets the connection makes
  # the server's response write hit a broken pipe. Without SIGPIPE handling and
  # per-connection error isolation this kills the whole single-process server.
  {
    my $rude = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 5)
      or die "connect: $!";
    $rude->setsockopt(SOL_SOCKET, SO_LINGER, pack 'II', 1, 0);
    print {$rude} "GET /health HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n" or die "print: $!";
    close $rude or die "close: $!";
  }

  # An oversized Content-Length must be rejected with 413, not read into memory
  # or left to block the loop. Bounded by a deadline so a regression cannot hang
  # the suite.
  my ($big_ok, $big_err, $big_status) = _with_deadline(
    10,
    'oversized body',
    sub {
      return _http_raw($port, "POST /sessions HTTP/1.1\r\nHost: x\r\nContent-Length: 100000000\r\n\r\n");
    });
  ok $big_ok, 'an oversized-body request completes without hanging the server' or diag $big_err;
  is $big_status, 413, 'an oversized request body is rejected with 413';

  # A slowloris client that connects and never finishes its request must not
  # wedge the serial server.
  my $slow = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 5)
    or die "connect: $!";
  print {$slow} "GET /health HTTP/1.1\r\n" or die "print: $!";

  # After every hostile client above, a well-behaved client is still served.
  my ($ok, $err, $status, $health) = _with_deadline(15, 'survival', sub { return _http($port, 'GET', '/health') });
  ok $ok, 'the server still serves a normal request after hostile clients' or diag $err;
  is $status, 200, 'the survivor request succeeds';
  is($health->{status}, 'ok', 'the health body is intact') if $ok;

  close $slow or die "close: $!";
  is waitpid($pid, WNOHANG), 0, 'the server process is still running';
  kill 'TERM', $pid;
  waitpid $pid, 0;
};

done_testing;

sub _with_deadline {
  my ($seconds, $label, $code) = @_;
  my @result;
  my $ok = eval {
    local $SIG{ALRM} = sub { die "deadline exceeded ($label)\n" };
    alarm $seconds;
    @result = $code->();
    alarm 0;
    1;
  };
  my $error = $@;
  alarm 0;
  return ($ok, $error, @result);
}

sub _http_raw {
  my ($port, $raw) = @_;
  my $socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 5)
    or die "connect: $!";
  print {$socket} $raw or die "print: $!";
  my $response = do { local $/; <$socket> };
  close $socket or die "close: $!";
  my ($status) = ($response // q{}) =~ m{\AHTTP/\S+\ (\d+)}mxs;
  return $status;
}

sub _free_port {
  my $probe = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp', Listen => 1)
    or die "probe: $!";
  my $port = $probe->sockport;
  close $probe or die "close: $!";
  return $port;
}

sub _spawn_server {
  my ($port) = @_;
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    exec $^X, "$FindBin::Bin/../bin/overnet-burner-adversary-server", '--host', '127.0.0.1', '--port', $port
      or die "exec: $!";
  }

  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) {
      close $probe or die "close: $!";
      return $pid;
    }
    if (waitpid($pid, WNOHANG) != 0) {
      die "server child exited before listening\n";
    }
    sleep 0.1;
  }
  die "server never listened on port $port\n";
}

sub _http {
  my ($port, $method, $path, $body) = @_;
  my $socket = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 5)
    or die "connect: $!";

  my $payload = defined $body ? $JSON->encode($body) : q{};
  my $length  = length $payload;
  print {$socket} "$method $path HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
    . "Content-Length: $length\r\nConnection: close\r\n\r\n$payload"
    or die "print: $!";

  my $raw = do { local $/; <$socket> };
  close $socket or die "close: $!";

  my ($status) = $raw =~ m{\AHTTP/\S+\ (\d+)}mxs;
  my ($json)   = $raw =~ /\r\n\r\n(.*)\z/mxs;
  my $decoded  = length($json // q{}) ? $JSON->decode($json) : {};
  return ($status, $decoded);
}
