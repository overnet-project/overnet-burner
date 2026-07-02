use strictures 2;

use AnyEvent;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
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

my $repo   = "$FindBin::Bin/..";
my $worker = "$repo/bin/overnet-burner-worker";

subtest 'query reader measures filter query round trips' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

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
  for my $sequence (1 .. 3) {
    my $event = $key->create_event(
      kind    => 7800,
      content => JSON->new->canonical(1)->encode(
        {
          provenance => {type     => 'native'},
          body       => {sequence => $sequence},
        }
      ),
      tags => [['overnet_v', '0.1.0'],],
    );
    my $waiter = AnyEvent->condvar;
    $pending{$event->id} = $waiter;
    $client->publish($event);
    ok $waiter->recv, "seed publish $sequence is accepted";
  }
  $client->disconnect;

  my $run_dir = _run_layout('query-reader-001');
  my $input   = {
    input_version    => 1,
    run_id           => 'query-reader-test-001',
    run_dir          => $run_dir,
    worker_id        => 'query-reader-001',
    role             => 'query_reader',
    seed             => 12345,
    duration_seconds => 2,
    metric_stream    => 'metrics/query-reader-001.jsonl',
    ready_file       => 'workers/query-reader-001/ready',
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {
      query_filters         => [{kinds => [7800]}],
      query_rate_per_second => 5,
    },
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'query-reader-001', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
    exec $^X, "-I$repo/lib", $worker or die "exec: $!";
  }

  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'query-reader-001', 'ready');
  my $deadline   = time + 10;
  while (time < $deadline && !-e $ready_path) {
    if (waitpid($pid, WNOHANG) == $pid) {
      die "query reader exited before becoming ready\n";
    }
    sleep 0.05;
  }
  ok -e $ready_path, 'query reader wrote its ready file after connecting';

  waitpid $pid, 0;
  is $? >> 8, 0, 'query reader exited cleanly after its duration';

  my $stream =
    Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'query-reader-001.jsonl'));
  ok @{$stream} >= 3, 'query reader issued repeated queries' or diag(scalar @{$stream});

  my @bad_shape = grep { $_->{operation} ne 'query' || $_->{status} ne 'success' } @{$stream};
  is \@bad_shape, [], 'query metrics use the query operation and succeed';

  my @bad_counts = grep { !defined $_->{result_count} || $_->{result_count} != 3 } @{$stream};
  is \@bad_counts, [], 'every query saw exactly the three stored events';

  my @bad_durations = grep { $_->{duration_ms} < 0 || $_->{duration_ms} > 5000 } @{$stream};
  is \@bad_durations, [], 'query durations are plausible for a local relay';

  my %subscription_ids = map { $_->{subscription_id} => 1 } @{$stream};
  is scalar keys %subscription_ids, scalar @{$stream}, 'each query used a distinct subscription id';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'query reader requires query filters' => sub {
  my $run_dir = _run_layout('query-reader-002');
  my $input   = {
    input_version    => 1,
    run_id           => 'query-reader-test-002',
    run_dir          => $run_dir,
    worker_id        => 'query-reader-002',
    role             => 'query_reader',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => 'metrics/query-reader-002.jsonl',
    ready_file       => 'workers/query-reader-002/ready',
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    workload         => {},
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'query-reader-002', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
  my $output = `$^X -I$repo/lib $worker 2>&1`;
  isnt $? >> 8, 0, 'query reader without filters exits non-zero';
  like $output, qr/query_filters/, 'failure names the missing workload field';
};

done_testing;

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _spawn_relay {
  my ($port) = @_;
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    exec $^X, '-MNet::Nostr::Relay', '-e', 'Net::Nostr::Relay->new->run($ARGV[0], $ARGV[1])', '127.0.0.1', $port
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
      die "relay child exited before listening\n";
    }
    sleep 0.1;
  }
  die "relay child never listened on port $port\n";
}

sub _free_port {
  my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
  ) or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
