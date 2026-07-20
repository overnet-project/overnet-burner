use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use AnyEvent;
use FindBin;
use IO::Socket::INET;
use JSON ();
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Net::Nostr::Client;
use Net::Nostr::Filter;
use Overnet::Burner::Worker;
use Overnet::Burner::Worker::SyncBridge;

# Minimal doubles for unit-testing the reconciliation handler in isolation:
# FakeNeg returns a scripted reconcile result, FakeClient records neg_msg sends.
{

  package FakeNeg;
  sub new { my ($c, @r) = @_; return bless {result => [@r]}, $c }
  sub reconcile { my ($self) = @_; return @{$self->{result}} }

  package FakeClient;
  sub new { my ($c, $on_msg) = @_; return bless {on_msg => $on_msg}, $c }
  sub neg_msg { my $self = shift; return $self->{on_msg}->($self, @_) }
}

# In-process coverage for the sync bridge: role and config derivation, a full
# run that converges two relays given asymmetric writes, a topology with no
# peer relay, and an unreachable relay -- both of which are error metrics.

subtest 'role, interval, timeout, and filter derivation' => sub {
  is(Overnet::Burner::Worker::SyncBridge->expected_role, 'sync_bridge', 'declares the sync_bridge role');

  my $default = Overnet::Burner::Worker::SyncBridge->new(input => _input(_layout('sb-def'), 'sb-def'));
  is $default->_sync_interval, 1,  'a missing interval defaults to one second';
  is $default->_sync_timeout,  10, 'a missing timeout defaults to ten seconds';
  is $default->_sync_filter, {}, 'a missing filter reconciles all visible events';

  my $configured = Overnet::Burner::Worker::SyncBridge->new(
    input => _input(
      _layout('sb-cfg'), 'sb-cfg', undef,
      {sync_bridge => {interval_seconds => 0.25, timeout_seconds => 3, filters => [{kinds => [7800]}]}},
    ),
  );
  is $configured->_sync_interval, 0.25, 'a configured interval is honored';
  is $configured->_sync_timeout,  3,    'a configured timeout is honored';
  is $configured->_sync_filter, {kinds => [7800]}, 'a configured filter is honored';
};

subtest 'a full run converges two relays that were written asymmetrically' => sub {
  my $port_a = _free_port();
  my $pid_a  = _spawn_relay($port_a);
  my $port_b = _free_port();
  my $pid_b  = _spawn_relay($port_b);
  my $a      = "ws://127.0.0.1:$port_a";
  my $b      = "ws://127.0.0.1:$port_b";

  # Asymmetric writes with a one-event overlap: A={1,2,3}, B={3,4,5}.
  _seed_events($a, 1, 2, 3);
  _seed_events($b, 3, 4, 5);

  my $run_dir = _layout('sb-run');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input($run_dir, 'sb-run', [$a, $b], {sync_bridge => {interval_seconds => 0.25}}, 0.8),
  );
  $bridge->run;

  my $final_a = _dump_relay($a);
  my $final_b = _dump_relay($b);

  kill 'TERM', $pid_a, $pid_b;
  waitpid $pid_a, 0;
  waitpid $pid_b, 0;

  is [sort keys %{$final_a}], [sort keys %{$final_b}], 'both relays hold the same event set after the bridge';
  is scalar(keys %{$final_a}), 5, 'the shared set is the union of the two asymmetric writes';

  my $events = _metric_events($run_dir, 'sb-run');
  ok scalar(@{$events}) >= 1, 'the bridge emitted at least one sync_converge metric';
  my ($first) = @{$events};
  is $first->{operation}, 'sync_converge', 'the metric is a sync_converge';
  is $first->{status},    'success',       'a converging session succeeds';
  is $first->{rounds},        3, 'convergence takes three negentropy passes';
  is $first->{fetched_count}, 5, 'the bridge fetches the whole union';
  is $first->{pushed_count},  4, 'the bridge pushes each relay the events it lacked';
  is $first->{left_url},  $a, 'the metric records the primary relay';
  is $first->{right_url}, $b, 'the metric records the peer relay';
};

subtest 'a topology without a peer relay is an error metric, not a failure' => sub {
  my $port = _free_port();
  my $pid  = _spawn_relay($port);
  my $a    = "ws://127.0.0.1:$port";

  my $run_dir = _layout('sb-solo');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input($run_dir, 'sb-solo', [$a], {sync_bridge => {interval_seconds => 0.25}}, 0.4),
  );
  ok lives { $bridge->run }, 'a lone relay does not crash the bridge';

  kill 'TERM', $pid;
  waitpid $pid, 0;

  my $events = _metric_events($run_dir, 'sb-solo');
  ok scalar(@{$events}) >= 1, 'the bridge still emitted a metric';
  is $events->[0]{status}, 'error', 'a bridge without a peer is an error metric';
  ok defined $events->[0]{error} && length $events->[0]{error}, 'the error metric carries a reason';
};

subtest 'an unreachable relay becomes an error metric, not a failure' => sub {
  my $port = _free_port();
  my $pid  = _spawn_relay($port);
  my $a    = "ws://127.0.0.1:$port";

  my $run_dir = _layout('sb-down');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input(
      $run_dir, 'sb-down', [$a, 'ws://127.0.0.1:1'],
      {sync_bridge => {interval_seconds => 0.25, timeout_seconds => 0.5}}, 0.4,
    ),
  );
  ok lives { $bridge->run }, 'an unreachable peer does not crash the bridge';

  kill 'TERM', $pid;
  waitpid $pid, 0;

  my $events = _metric_events($run_dir, 'sb-down');
  ok scalar(@{$events}) >= 1, 'the bridge still emitted a metric';
  is $events->[0]{status}, 'error', 'an unreachable relay is an error metric';
  ok defined $events->[0]{error} && length $events->[0]{error}, 'the error metric carries a reason';
};

subtest 'a reconciliation step continues while the protocol has more to send' => sub {
  my $bridge = Overnet::Burner::Worker::SyncBridge->new(input => _input(_layout('sb-step'), 'sb-step'));

  # A relay that splits its answer hands back a next message: the step relays it
  # and stays open. Otherwise it converges.
  my @sent;
  my $client = FakeClient->new(sub { push @sent, [@_[1, 2]] });
  my $more   = {
    client     => $client,
    negentropy => FakeNeg->new('cafe', ['have-1'], ['need-1']),
    sub_id     => 'sub-1',
    done       => AnyEvent->condvar,
    have       => [],
    need       => [],
  };
  $bridge->_reconcile_step($more, 'msg-in');
  is \@sent, [['sub-1', 'cafe']], 'the next protocol message is relayed back';
  is $more->{need}, ['need-1'], 'discovered needs accumulate';
  is $more->{have}, ['have-1'], 'discovered haves accumulate';
  ok !$more->{done}->ready, 'the session stays open for the next round';

  my $last = {
    client     => $client,
    negentropy => FakeNeg->new(undef, [], []),
    sub_id     => 'sub-1',
    done       => AnyEvent->condvar,
    have       => [],
    need       => [],
  };
  $bridge->_reconcile_step($last, 'final');
  ok $last->{done}->ready, 'the session ends when the protocol completes';
  is $last->{done}->recv, 1, 'convergence is signalled';
};

subtest 'a relay that never answers reconciliation times out into an error metric' => sub {
  my $port = _free_port();
  my $pid  = _spawn_silent_relay($port);

  my $run_dir = _layout('sb-silent');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input(
      $run_dir, 'sb-silent', ["ws://127.0.0.1:$port", 'ws://127.0.0.1:2'],
      {sync_bridge => {interval_seconds => 0.25, timeout_seconds => 0.3}}, 0.4,
    ),
  );
  $bridge->run;

  kill 'TERM', $pid;
  waitpid $pid, 0;

  my $events = _metric_events($run_dir, 'sb-silent');
  ok scalar(@{$events}) >= 1, 'the bridge emitted a metric';
  is $events->[0]{status}, 'error', 'a relay that never responds is an error metric';
  ok defined $events->[0]{error} && length $events->[0]{error}, 'the timeout error carries a reason';
};

subtest 'a relay that answers NEG-OPEN with NEG-ERR is an error metric' => sub {
  my $port = _free_port();
  my $pid  = _spawn_erroring_relay($port);

  my $run_dir = _layout('sb-err');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input(
      $run_dir, 'sb-err', ["ws://127.0.0.1:$port", 'ws://127.0.0.1:2'],
      {sync_bridge => {interval_seconds => 0.25}}, 0.4,
    ),
  );
  ok lives { $bridge->run }, 'a negentropy error does not crash the bridge';

  kill 'TERM', $pid;
  waitpid $pid, 0;

  my $events = _metric_events($run_dir, 'sb-err');
  ok scalar(@{$events}) >= 1, 'the bridge emitted a metric';
  is $events->[0]{status}, 'error', 'a NEG-ERR reply is an error metric';
};

subtest 'a TERM signal stops the bridge' => sub {
  my $port_a = _free_port();
  my $pid_a  = _spawn_relay($port_a);
  my $port_b = _free_port();
  my $pid_b  = _spawn_relay($port_b);

  my $run_dir = _layout('sb-term');
  my $bridge  = Overnet::Burner::Worker::SyncBridge->new(
    input => _input(
      $run_dir, 'sb-term', ["ws://127.0.0.1:$port_a", "ws://127.0.0.1:$port_b"],
      {sync_bridge => {interval_seconds => 0.25}}, 10,
    ),
  );

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { sleep 0.6; kill 'TERM', $parent; exit 0 }

  $bridge->run;
  waitpid $killer, 0;

  ok -e File::Spec->catfile($run_dir, 'workers', 'sb-term', 'ready'),
    'the bridge stopped after the signal without hanging for its full duration';

  kill 'TERM', $pid_a, $pid_b;
  waitpid $pid_a, 0;
  waitpid $pid_b, 0;
};

done_testing;

sub _layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _input {
  my ($run_dir, $worker_id, $relays, $workload, $duration) = @_;
  $relays   //= ['ws://127.0.0.1:1', 'ws://127.0.0.1:2'];
  $duration //= 1;
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'sync_bridge',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => $relays},
    workload         => $workload // {},
  };
}

sub _metric_events {
  my ($run_dir, $worker_id) = @_;
  my $path = File::Spec->catfile($run_dir, 'metrics', "$worker_id.jsonl");
  return [] unless -f $path;
  open my $fh, '<', $path or die "open $path: $!";
  my @events;
  while (my $line = <$fh>) {
    next unless $line =~ /\S/mx;
    push @events, JSON::decode_json($line);
  }
  close $fh or die "close $path: $!";
  return \@events;
}

sub _seed_events {
  my ($url, @specs) = @_;
  my $key    = Overnet::Burner::Worker->derive_key('seed', 'sync-bridge-seed');
  my $client = Net::Nostr::Client->new;
  my %ok;
  my $cv = AnyEvent->condvar;
  $client->on(ok => sub { my ($id, $accepted) = @_; $ok{$id} = $accepted; $cv->send if keys %ok == @specs; });
  $client->connect($url);
  for my $spec (@specs) {
    $client->publish($key->create_event(kind => 7800, content => "e-$spec", tags => [['d', "obj-$spec"]]));
  }
  my $timeout = AnyEvent->timer(after => 8, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;
  return;
}

sub _dump_relay {
  my ($url) = @_;
  my $client = Net::Nostr::Client->new;
  my %events;
  my $cv = AnyEvent->condvar;
  $client->on(event => sub { my ($sid, $ev) = @_; $events{$ev->id} = 1; });
  $client->on(eose => sub { $cv->send });
  $client->connect($url);
  $client->subscribe('dump', Net::Nostr::Filter->new(kinds => [7800]));
  my $timeout = AnyEvent->timer(after => 5, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;
  return \%events;
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

sub _spawn_silent_relay {
  my ($port) = @_;
  return _spawn_relay_script($port, 'silent-relay', <<'PERL');
use strict;
use warnings;
use Net::Nostr::Relay;
package SilentRelay;
our @ISA = ('Net::Nostr::Relay');
sub _handle_neg_open { return }    # accept NEG-OPEN but never respond
package main;
SilentRelay->new->run($ARGV[0], $ARGV[1]);
PERL
}

sub _spawn_erroring_relay {
  my ($port) = @_;
  return _spawn_relay_script($port, 'erroring-relay', <<'PERL');
use strict;
use warnings;
use Net::Nostr::Relay;
use Net::Nostr::Message;
package ErroringRelay;
our @ISA = ('Net::Nostr::Relay');
sub _handle_neg_open {
  my ($self, $conn_id, $msg) = @_;
  my $conn = $self->_connections->{$conn_id};
  $conn->send(Net::Nostr::Message->new(
    type => 'NEG-ERR', subscription_id => $msg->subscription_id,
    message => 'error: synthetic negentropy failure',
  )->serialize);
  return;
}
package main;
ErroringRelay->new->run($ARGV[0], $ARGV[1]);
PERL
}

sub _spawn_relay_script {
  my ($port, $name, $source) = @_;
  my $script = File::Spec->catfile(tempdir(CLEANUP => 1), $name);
  open my $fh, '>', $script or die "open $script: $!";
  print {$fh} $source or die "print: $!";
  close $fh or die "close: $!";

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) { exec $^X, $script, '127.0.0.1', $port or die "exec: $!" }
  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) { close $probe or die "close: $!"; return $pid }
    if (waitpid($pid, WNOHANG) != 0) { die "$name exited before listening\n" }
    sleep 0.1;
  }
  die "$name never listened on port $port\n";
}
