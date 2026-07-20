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
use Overnet::Burner::Worker;
use Overnet::Burner::Worker::Syncer;

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

# In-process coverage for the syncer: role, interval derivation, a full
# localhost run that reconciles against a seeded relay and discovers what it
# needs, and an unreachable relay that becomes an error metric.

subtest 'role, interval, timeout, and filter derivation' => sub {
  is(Overnet::Burner::Worker::Syncer->expected_role, 'syncer', 'declares the syncer role');

  my $default = Overnet::Burner::Worker::Syncer->new(input => _input(_layout('sy-def'), 'sy-def'));
  is $default->_sync_interval, 1,  'a missing interval defaults to one second';
  is $default->_sync_timeout,  10, 'a missing timeout defaults to ten seconds';
  is $default->_sync_filter, {}, 'a missing filter reconciles all visible events';

  my $configured = Overnet::Burner::Worker::Syncer->new(
    input => _input(
      _layout('sy-cfg'), 'sy-cfg', undef,
      {syncer => {interval_seconds => 0.25, timeout_seconds => 3, filters => [{kinds => [7800]}]}},
    ),
  );
  is $configured->_sync_interval, 0.25, 'a configured interval is honored';
  is $configured->_sync_timeout,  3,    'a configured timeout is honored';
  is $configured->_sync_filter, {kinds => [7800]}, 'a configured filter is honored';
};

subtest 'a full run reconciles against the relay and reports what it needs' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my @seeded = _seed_events("ws://127.0.0.1:$port", 5);
  is scalar(@seeded), 5, 'five events were seeded into the relay';

  my $run_dir = _layout('sy-run');
  my $syncer  = Overnet::Burner::Worker::Syncer->new(
    input => _input($run_dir, 'sy-run', ["ws://127.0.0.1:$port"], {syncer => {interval_seconds => 0.25}}, 0.8),
  );
  $syncer->run;

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;

  my $events = _metric_events($run_dir, 'sy-run');
  ok scalar(@{$events}) >= 1, 'the syncer emitted at least one sync_round metric';
  is [map { $_->{operation} } @{$events}], [('sync_round') x scalar @{$events}], 'every metric is a sync_round';

  my ($first) = @{$events};
  is $first->{status}, 'success', 'a reconciliation session against a live relay succeeds';
  ok $first->{rounds} >= 1, 'the session records at least one protocol round';
  ok defined $first->{duration_ms} && $first->{duration_ms} >= 0, 'the session records a duration';
  is $first->{need_count}, 5, 'negentropy discovers the five seeded events as needed';
  is $first->{have_count}, 0, 'the empty-local syncer has nothing the relay lacks';
};

subtest 'a reconciliation step continues while the protocol has more to send' => sub {
  my $syncer = Overnet::Burner::Worker::Syncer->new(input => _input(_layout('sy-step'), 'sy-step'));

  # A relay that splits its answer hands back a next message: the step must
  # relay it and stay open. (An empty-local syncer never sees this over the
  # wire, but the handler stays protocol-complete for a relay that does.)
  my @sent;
  my $client = FakeClient->new(sub { push @sent, [@_[1, 2]] });
  my $more   = {
    client     => $client,
    negentropy => FakeNeg->new('cafe', ['have-1'], ['need-1']),
    sub_id     => 'sub-1',
    done       => AnyEvent->condvar,
    rounds     => 0,
    have       => [],
    need       => [],
  };
  $syncer->_reconcile_step($more, 'msg-in');
  is \@sent, [['sub-1', 'cafe']], 'the next protocol message is relayed back';
  is $more->{rounds}, 1, 'the round is counted';
  is $more->{need}, ['need-1'], 'discovered needs accumulate';
  is $more->{have}, ['have-1'], 'discovered haves accumulate';
  ok !$more->{done}->ready, 'the session stays open for the next round';

  # A relay that is done hands back undef: the step converges.
  my $last = {
    client     => $client,
    negentropy => FakeNeg->new(undef, [], []),
    sub_id     => 'sub-1',
    done       => AnyEvent->condvar,
    rounds     => 0,
    have       => [],
    need       => [],
  };
  $syncer->_reconcile_step($last, 'final');
  ok $last->{done}->ready, 'the session ends when the protocol completes';
  is $last->{done}->recv, 1, 'convergence is signalled as success';
};

subtest 'a negentropy error without a message falls back to a default reason' => sub {
  my $syncer = Overnet::Burner::Worker::Syncer->new(input => _input(_layout('sy-nerr'), 'sy-nerr'));

  my $state = {done => AnyEvent->condvar};
  $syncer->_note_neg_error($state, q{});
  is $state->{error}, 'negentropy error', 'an empty relay message yields a default reason';
  ok $state->{done}->ready, 'the session is ended';
  is $state->{done}->recv, 0, 'the failure is signalled as an error';
};

subtest 'an unreachable relay becomes an error metric, not a failure' => sub {
  my $run_dir = _layout('sy-down');
  my $syncer  = Overnet::Burner::Worker::Syncer->new(
    input => _input($run_dir, 'sy-down', ['ws://127.0.0.1:1'], {syncer => {interval_seconds => 0.25}}, 0.4),
  );
  ok lives { $syncer->run }, 'an unreachable relay does not crash the syncer';

  my $events = _metric_events($run_dir, 'sy-down');
  ok scalar(@{$events}) >= 1, 'the syncer still emitted a metric';
  is $events->[0]{status}, 'error', 'an unreachable relay is an error metric';
  ok defined $events->[0]{error} && length $events->[0]{error}, 'the error metric carries a reason';
};

subtest 'a relay that answers NEG-OPEN with NEG-ERR is an error metric' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_erroring_relay($port);

  my $run_dir = _layout('sy-err');
  my $syncer  = Overnet::Burner::Worker::Syncer->new(
    input => _input($run_dir, 'sy-err', ["ws://127.0.0.1:$port"], {syncer => {interval_seconds => 0.25}}, 0.4),
  );
  ok lives { $syncer->run }, 'a negentropy error does not crash the syncer';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;

  my $events = _metric_events($run_dir, 'sy-err');
  ok scalar(@{$events}) >= 1, 'the syncer emitted a metric';
  is $events->[0]{status}, 'error', 'a NEG-ERR reply is an error metric';
  like $events->[0]{error}, qr/synthetic negentropy failure/,
    'the relay-reported reason is preserved in the metric';
};

subtest 'a relay that never answers NEG-OPEN times out into an error metric' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_silent_relay($port);

  # A short timeout with a matching duration: the first session blocks on the
  # sync timeout, and the run deadline passes while it waits.
  my $run_dir = _layout('sy-silent');
  my $syncer  = Overnet::Burner::Worker::Syncer->new(
    input => _input(
      $run_dir, 'sy-silent',
      ["ws://127.0.0.1:$port"],
      {syncer => {interval_seconds => 0.25, timeout_seconds => 0.3}},
      0.4,
    ),
  );
  $syncer->run;

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;

  my $events = _metric_events($run_dir, 'sy-silent');
  ok scalar(@{$events}) >= 1, 'the syncer emitted a metric';
  is $events->[0]{status}, 'error', 'a relay that never responds is an error metric';
  ok defined $events->[0]{error} && length $events->[0]{error}, 'the timeout error carries a reason';
};

subtest 'a TERM signal stops the syncer' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _layout('sy-term');
  my $syncer  = Overnet::Burner::Worker::Syncer->new(
    input => _input($run_dir, 'sy-term', ["ws://127.0.0.1:$port"], {syncer => {interval_seconds => 0.25}}, 10),
  );

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { sleep 0.6; kill 'TERM', $parent; exit 0 }

  $syncer->run;
  waitpid $killer, 0;

  ok -e File::Spec->catfile($run_dir, 'workers', 'sy-term', 'ready'),
    'the syncer stopped after the signal without hanging for its full duration';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
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
  $relays   //= ['ws://127.0.0.1:1'];
  $duration //= 1;
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'syncer',
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
  my ($url, $count) = @_;
  my $key    = Overnet::Burner::Worker->derive_key('seed', 'syncer-seed');
  my $client = Net::Nostr::Client->new;
  my %ok;
  my $cv = AnyEvent->condvar;
  $client->on(ok => sub { my ($id, $accepted) = @_; $ok{$id} = $accepted; $cv->send if keys %ok == $count; });
  $client->connect($url);
  my @ids;
  for my $i (1 .. $count) {
    my $event = $key->create_event(kind => 7800, content => "seed-$i", tags => [['d', "obj-$i"]]);
    push @ids, $event->id;
    $client->publish($event);
  }
  my $timeout = AnyEvent->timer(after => 8, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;
  return grep { $ok{$_} } @ids;
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
