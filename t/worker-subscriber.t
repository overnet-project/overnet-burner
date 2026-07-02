use strictures 2;

use AnyEvent;
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Net::Nostr::Client;
use Net::Nostr::Relay;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Publisher;

my $repo   = "$FindBin::Bin/..";
my $worker = "$repo/bin/overnet-burner-worker";

subtest 'subscriber measures live fanout from stamped events' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _run_layout('subscriber-001');
  my $input   = {
    input_version    => 1,
    run_id           => 'subscriber-test-001',
    run_dir          => $run_dir,
    worker_id        => 'subscriber-001',
    role             => 'subscriber',
    seed             => 12345,
    duration_seconds => 4,
    metric_stream    => 'metrics/subscriber-001.jsonl',
    ready_file       => 'workers/subscriber-001/ready',
    endpoints        => {relays               => ["ws://127.0.0.1:$port"]},
    workload         => {subscription_filters => [{kinds => [7800]}],},
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'subscriber-001', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
    exec $^X, "-I$repo/lib", $worker or die "exec: $!";
  }

  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'subscriber-001', 'ready');
  my $deadline   = time + 10;
  while (time < $deadline && !-e $ready_path) {
    if (waitpid($pid, WNOHANG) == $pid) {
      die "subscriber exited before becoming ready\n";
    }
    sleep 0.05;
  }
  ok -e $ready_path, 'subscriber wrote its ready file after subscribing';

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

  my @published;
  for my $sequence (1 .. 3) {
    my $event = $key->create_event(
      kind    => 7800,
      content => JSON->new->canonical(1)->encode(
        {
          provenance => {type     => 'native'},
          body       => {sequence => $sequence, sent_at => time * 1000},
        }
      ),
      tags => [['overnet_v', '0.1.0'],],
    );
    my $waiter = AnyEvent->condvar;
    $pending{$event->id} = $waiter;
    $client->publish($event);
    ok $waiter->recv, "publish $sequence is accepted";
    push @published, $event->id;
    sleep 0.1;
  }
  $client->disconnect;

  waitpid $pid, 0;
  is $? >> 8, 0, 'subscriber exited cleanly after its duration';

  my $stream = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'subscriber-001.jsonl'));
  is scalar @{$stream}, 3, 'subscriber measured every live event';

  my @bad_shape =
    grep { $_->{operation} ne 'subscription_fanout' || $_->{status} ne 'success' } @{$stream};
  is \@bad_shape, [], 'fanout metrics use the subscription_fanout operation and succeed';

  is [sort map { $_->{event_id} } @{$stream}], [sort @published], 'fanout metrics name exactly the published events';

  my @bad_durations = grep { $_->{duration_ms} < 0 || $_->{duration_ms} > 5000 } @{$stream};
  is \@bad_durations, [], 'fanout durations are plausible for a local relay';

  my @missing_sub = grep { !$_->{subscription_id} } @{$stream};
  is \@missing_sub, [], 'fanout metrics carry the subscription id';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'subscriber requires subscription filters' => sub {
  my $run_dir = _run_layout('subscriber-002');
  my $input   = {
    input_version    => 1,
    run_id           => 'subscriber-test-002',
    run_dir          => $run_dir,
    worker_id        => 'subscriber-002',
    role             => 'subscriber',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => 'metrics/subscriber-002.jsonl',
    ready_file       => 'workers/subscriber-002/ready',
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    workload         => {},
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'subscriber-002', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
  my $output = `$^X -I$repo/lib $worker 2>&1`;
  isnt $? >> 8, 0, 'subscriber without filters exits non-zero';
  like $output, qr/subscription_filters/, 'failure names the missing workload field';
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
