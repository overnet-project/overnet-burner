use strictures 2;

use AnyEvent;
use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Net::Nostr::Client;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Publisher;
use Overnet::Burner::Worker::QueryReader;

# In-process coverage for the query reader: role, the missing-filter fatal
# path, a full run against a localhost relay with stored events, the query
# timeout path via a duck-typed client, an idle phase, and a TERM stop.

subtest 'role and missing filters' => sub {
  is(Overnet::Burner::Worker::QueryReader->expected_role,
    'query_reader', 'the reader declares the query_reader role');

  my $run_dir = _layout('qr-empty');
  my $reader  = Overnet::Burner::Worker::QueryReader->new(input => _input($run_dir, 'qr-empty', undef));
  like dies { $reader->run }, qr/query_filters/mx, 'a run without query filters is fatal';
};

subtest 'a full localhost run measures bounded queries with results' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);
  _publish_stamped($port, 1 .. 3);

  my $run_dir = _layout('qr-run');
  my $reader  = Overnet::Burner::Worker::QueryReader->new(
    input => _input($run_dir, 'qr-run', [{kinds => [7800]}], "ws://127.0.0.1:$port", 1.0, 4),
  );
  $reader->run;

  ok -e File::Spec->catfile($run_dir, 'workers', 'qr-run', 'ready'),
    'the reader wrote its ready file after connecting';

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'qr-run.jsonl'));
  ok @{$stream} >= 1, 'at least one query was issued' or diag scalar @{$stream};
  my @bad = grep { $_->{operation} ne 'query' || $_->{status} ne 'success' } @{$stream};
  is \@bad, [], 'every query is a bounded success';
  ok $stream->[0]{result_count} >= 3, 'the query saw the stored events'
    or diag $stream->[0]{result_count};

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'a query that never reaches the boundary times out' => sub {
  my $run_dir = _layout('qr-timeout');
  my $reader  = Overnet::Burner::Worker::QueryReader->new(
    input => _input($run_dir, 'qr-timeout', [{kinds => [7800]}]),
  );
  $reader->{host} = 'test-host';
  $reader->open_metric_stream;

  my $silent = _fake_client();    # accepts subscribe, never sends eose
  $reader->_query_once(
    client   => $silent,
    filters  => [],
    pending  => {},
    sequence => 1,
    phase    => 'main',
  );
  $reader->close_metric_stream;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'qr-timeout.jsonl'));
  is $stream->[0]{status}, 'error',           'an unbounded query is an error';
  is $stream->[0]{error},  'query timed out', 'the error names the timeout';
};

subtest 'an idle phase paces nothing but completes' => sub {
  my $run_dir = _layout('qr-idle');
  my $reader  = Overnet::Burner::Worker::QueryReader->new(
    input => _input($run_dir, 'qr-idle', [{kinds => [7800]}]),
  );
  my $stop = 0;
  my $done = $reader->_run_phase(
    client  => _fake_client(),
    filters => [],
    pending => {},
    phase   => {name => 'idle', start_seconds => 0, duration_seconds => 0, query_rate_per_second => 0},
    started => time,
    stop    => \$stop,
  );
  is $done, 1, 'the idle phase returns cleanly';
};

subtest 'a TERM signal stops the reader between phases' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);
  _publish_stamped($port, 1 .. 2);

  my $run_dir = _layout('qr-term');
  my $input   = _input($run_dir, 'qr-term', [{kinds => [7800]}], "ws://127.0.0.1:$port");
  $input->{duration_seconds} = 10;
  $input->{phases}           = [
    {name => 'p1', start_seconds => 0, duration_seconds => 5, query_rate_per_second => 10},
    {name => 'p2', start_seconds => 5, duration_seconds => 5, query_rate_per_second => 10},
  ];
  my $reader = Overnet::Burner::Worker::QueryReader->new(input => $input);

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { sleep 0.6; kill 'TERM', $parent; exit 0 }

  $reader->run;
  waitpid $killer, 0;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'qr-term.jsonl'));
  my @phase2 = grep { $_->{phase} eq 'p2' } @{$stream};
  is \@phase2, [], 'the reader stopped before the second phase';

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
  my ($run_dir, $worker_id, $filters, $relay, $duration, $rate) = @_;
  $relay    //= 'ws://127.0.0.1:1';
  $duration //= 1;
  $rate     //= 10;
  my %workload = defined $filters ? (query_filters => $filters, query_rate_per_second => $rate) : ();
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'query_reader',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => [$relay]},
    workload         => \%workload,
  };
}

sub _fake_client { return bless {}, '_SilentClient' }

sub _publish_stamped {
  my ($port, @sequences) = @_;
  my $key    = Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-001');
  my $client = Net::Nostr::Client->new;
  my %pending;
  $client->on(
    ok => sub {
      my ($event_id, $accepted) = @_;
      my $waiter = delete $pending{$event_id};
      $waiter->send($accepted) if $waiter;
    }
  );
  $client->connect("ws://127.0.0.1:$port");
  for my $sequence (@sequences) {
    my $event = $key->create_event(
      kind    => 7800,
      content => JSON->new->canonical(1)->encode(
        {provenance => {type => 'native'}, body => {sequence => $sequence, sent_at => time * 1000}}),
      tags => [['overnet_v', '0.1.0']],
    );
    my $waiter = AnyEvent->condvar;
    $pending{$event->id} = $waiter;
    $client->publish($event);
    die "publish $sequence rejected\n" if !$waiter->recv;
    sleep 0.05;
  }
  $client->disconnect;
  return;
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

package _SilentClient;
sub subscribe { return 1 }
sub close     { return 1 }
