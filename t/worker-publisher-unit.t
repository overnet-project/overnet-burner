use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Publisher;

# In-process coverage for the publisher: role, a full localhost run that
# publishes and is acknowledged, the reconnect success/failure branches, a
# lost connection on send, the acknowledgment timeout, an idle phase, and a
# TERM stop.

subtest 'role and workload object id' => sub {
  is(Overnet::Burner::Worker::Publisher->expected_role, 'publisher', 'declares the publisher role');
  my $pub = Overnet::Burner::Worker::Publisher->new(input => _input(_layout('pb-id'), 'pb-id'));
  is $pub->_workload_object_id, 'burner-run-pb-id', 'the object id combines run and worker id';
};

subtest 'a full localhost run publishes acknowledged events' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _layout('pb-run');
  my $pub     = Overnet::Burner::Worker::Publisher->new(
    input => _input($run_dir, 'pb-run', "ws://127.0.0.1:$port", 1.0, 4),
  );
  $pub->run;

  ok -e File::Spec->catfile($run_dir, 'workers', 'pb-run', 'ready'), 'the publisher became ready';
  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'pb-run.jsonl'));
  ok @{$stream} >= 1, 'events were published' or diag scalar @{$stream};
  my @bad = grep { $_->{operation} ne 'publish' || $_->{status} ne 'success' } @{$stream};
  is \@bad, [], 'every publish was acknowledged';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

subtest 'a lost connection on send is a structured error' => sub {
  my $run_dir = _layout('pb-lost');
  my $pub     = Overnet::Burner::Worker::Publisher->new(input => _input($run_dir, 'pb-lost'));
  $pub->{host} = 'test-host';
  $pub->open_metric_stream;

  my $client = _fake_client(connected => 1, publish_dies => 1);
  $pub->_publish_once(
    client   => $client,
    key      => _key(),
    pending  => {},
    sequence => 1,
    phase    => 'main',
  );
  $pub->close_metric_stream;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'pb-lost.jsonl'));
  is $stream->[0]{status}, 'error',                 'a failed send is an error';
  is $stream->[0]{error},  'relay connection lost', 'the error names the lost connection';
};

subtest 'a disconnected client reconnects before publishing' => sub {
  my $run_dir = _layout('pb-recon');
  my $pub     = Overnet::Burner::Worker::Publisher->new(input => _input($run_dir, 'pb-recon'));
  $pub->{host} = 'test-host';
  $pub->open_metric_stream;

  # Not connected, but reconnect succeeds; the following publish still fails,
  # exercising the reconnect-then-send path without a live relay.
  my $client = _fake_client(connected => 0, connect_ok => 1, publish_dies => 1);
  $pub->_publish_once(
    client   => $client,
    key      => _key(),
    pending  => {},
    sequence => 1,
    phase    => 'main',
  );
  $pub->close_metric_stream;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'pb-recon.jsonl'));
  is scalar @{$stream}, 1, 'the reconnect proceeded to a publish attempt';
  is $stream->[0]{error}, 'relay connection lost', 'the post-reconnect send still failed cleanly';
};

subtest 'a failed reconnect is reported and the publish is skipped' => sub {
  my $run_dir = _layout('pb-reconfail');
  my $pub     = Overnet::Burner::Worker::Publisher->new(input => _input($run_dir, 'pb-reconfail'));
  $pub->{host} = 'test-host';
  $pub->open_metric_stream;

  my $client = _fake_client(connected => 0, connect_ok => 0);
  $pub->_publish_once(
    client   => $client,
    key      => _key(),
    pending  => {},
    sequence => 1,
    phase    => 'main',
  );
  $pub->close_metric_stream;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'pb-reconfail.jsonl'));
  is scalar @{$stream}, 1, 'exactly one error was recorded for the failed reconnect';
  is $stream->[0]{error}, 'relay connection lost and reconnect failed',
    'the failed reconnect is the reported error';
};

subtest 'an unacknowledged publish times out' => sub {
  my $run_dir = _layout('pb-timeout');
  my $pub     = Overnet::Burner::Worker::Publisher->new(input => _input($run_dir, 'pb-timeout'));
  $pub->{host} = 'test-host';
  $pub->open_metric_stream;

  # Connected, publish succeeds, but nothing ever acknowledges the event, so
  # the publish timeout timer resolves the waiter.
  my $client = _fake_client(connected => 1);
  $pub->_publish_once(
    client   => $client,
    key      => _key(),
    pending  => {},
    sequence => 1,
    phase    => 'main',
  );
  $pub->close_metric_stream;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'pb-timeout.jsonl'));
  is $stream->[0]{status}, 'error',              'an unacknowledged publish is an error';
  is $stream->[0]{error},  'publish timed out',  'the timeout timer supplies the reason';
};

subtest 'an idle phase paces nothing but completes' => sub {
  my $run_dir = _layout('pb-idle');
  my $pub     = Overnet::Burner::Worker::Publisher->new(input => _input($run_dir, 'pb-idle'));
  my $stop    = 0;
  my $done    = $pub->_run_phase(
    client  => _fake_client(connected => 1),
    key     => _key(),
    pending => {},
    phase   => {name => 'idle', start_seconds => 0, duration_seconds => 0, publish_rate_per_second => 0},
    started => time,
    stop    => \$stop,
  );
  is $done, 1, 'the idle phase returns cleanly';
};

subtest 'a TERM signal stops the publisher between phases' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir = _layout('pb-term');
  my $input   = _input($run_dir, 'pb-term', "ws://127.0.0.1:$port");
  $input->{duration_seconds} = 10;
  $input->{phases}           = [
    {name => 'p1', start_seconds => 0, duration_seconds => 5, publish_rate_per_second => 10},
    {name => 'p2', start_seconds => 5, duration_seconds => 5, publish_rate_per_second => 10},
  ];
  my $pub = Overnet::Burner::Worker::Publisher->new(input => $input);

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) { sleep 0.6; kill 'TERM', $parent; exit 0 }

  $pub->run;
  waitpid $killer, 0;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'pb-term.jsonl'));
  my @phase2 = grep { $_->{phase} eq 'p2' } @{$stream};
  is \@phase2, [], 'the publisher stopped before the second phase';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
};

done_testing;

sub _key { return Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-001') }

sub _layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _input {
  my ($run_dir, $worker_id, $relay, $duration, $rate) = @_;
  $relay    //= 'ws://127.0.0.1:1';
  $duration //= 1;
  $rate     //= 10;
  return {
    input_version    => 1,
    run_id           => 'run',
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'publisher',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => [$relay]},
    workload         => {publish_rate_per_second => $rate},
  };
}

sub _fake_client { return bless {@_}, '_FakePubClient' }

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

package _FakePubClient;
sub is_connected { my ($self) = @_; return $self->{connected} }
sub connect { my ($self) = @_; die "connect refused\n" if !$self->{connect_ok}; $self->{connected} = 1; return 1 }
sub publish { my ($self) = @_; die "publish failed\n" if $self->{publish_dies}; return 1 }
sub disconnect { return 1 }
sub on         { return 1 }
