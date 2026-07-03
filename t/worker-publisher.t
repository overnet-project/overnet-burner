use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use JSON::Schema::Modern;
use Net::Nostr::Client;
use Net::Nostr::Filter;
use Net::Nostr::Relay;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Publisher;

my $repo   = "$FindBin::Bin/..";
my $worker = "$repo/bin/overnet-burner-worker";
my $schema =
  JSON::decode_json(_slurp(File::Spec->catfile($repo, 'schemas', 'worker-input-v1.schema.json')));

subtest 'published sample input validates against worker-input-v1' => sub {
  my $sample = JSON::decode_json(_slurp(File::Spec->catfile($repo, 'examples', 'worker-input-v1-sample.json')));
  my $result = JSON::Schema::Modern->new->evaluate($sample, $schema);
  ok $result->valid, 'sample worker input validates';
};

subtest 'publisher identity derives deterministically from seed and worker id' => sub {
  my $first  = Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-001');
  my $second = Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-001');
  my $other  = Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-002');

  is $first->pubkey_hex,   $second->pubkey_hex, 'same seed and worker id derive the same identity';
  isnt $first->pubkey_hex, $other->pubkey_hex,  'a different worker id derives a different identity';
};

subtest 'publisher measures honestly against a live relay' => sub {
  my $port  = _free_port();
  my $relay = Net::Nostr::Relay->new;
  $relay->start('127.0.0.1', $port);

  my $run_dir = _run_layout();
  my $input   = _worker_input($run_dir, $port, duration_seconds => 2, publish_rate_per_second => 5);

  Overnet::Burner::Worker::Publisher->new(input => $input)->run;

  ok -e File::Spec->catfile($run_dir, 'workers', 'publisher-001', 'ready'), 'publisher wrote its ready file';

  my $events = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  ok @{$events} >= 5,  'publisher emitted a plausible number of metric events' or diag(scalar @{$events});
  ok @{$events} <= 15, 'publisher respected the configured rate'               or diag(scalar @{$events});

  my @bad_shape =
    grep { $_->{operation} ne 'publish' || $_->{worker_id} ne 'publisher-001' || $_->{role} ne 'publisher' } @{$events};
  is \@bad_shape, [], 'every metric event carries the publish operation and worker identity';

  my @failures = grep { $_->{status} ne 'success' } @{$events};
  is \@failures, [], 'every publish against a healthy relay succeeded';

  my @missing_ids = grep { !$_->{event_id} } @{$events};
  is \@missing_ids, [], 'every publish metric records its published event id';

  my $stored =
    _stored_events($port, Overnet::Burner::Worker::Publisher->derive_key(12345, 'publisher-001')->pubkey_hex);
  is scalar @{$stored}, scalar @{$events}, 'the relay stored exactly as many events as the metrics claim';
  is [sort map { $_->{event_id} } @{$events}], [sort map { $_->id } @{$stored}],
    'stored event ids match the measured event ids exactly';

  my @invalid_kind = grep { $_->kind != 7800 } @{$stored};
  is \@invalid_kind, [], 'published events are Overnet events';
};

subtest 'publisher paces each workload phase by its own rate' => sub {
  my $port  = _free_port();
  my $relay = Net::Nostr::Relay->new;
  $relay->start('127.0.0.1', $port);

  my $run_dir = _run_layout();
  my $input   = _worker_input($run_dir, $port, duration_seconds => 4, publish_rate_per_second => 5);
  $input->{phases} = [
    {name => 'warmup',   start_seconds => 0, duration_seconds => 1, publish_rate_per_second => 2},
    {name => 'main',     start_seconds => 1, duration_seconds => 2, publish_rate_per_second => 5},
    {name => 'cooldown', start_seconds => 3, duration_seconds => 1, publish_rate_per_second => 0},
  ];

  Overnet::Burner::Worker::Publisher->new(input => $input)->run;

  my $events = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));

  my @untagged = grep { !defined $_->{phase} } @{$events};
  is \@untagged, [], 'every event names its phase';

  my @warmup   = grep { $_->{phase} eq 'warmup' } @{$events};
  my @main     = grep { $_->{phase} eq 'main' } @{$events};
  my @cooldown = grep { $_->{phase} eq 'cooldown' } @{$events};

  ok @warmup >= 1 && @warmup <= 3, 'warmup publishes at the warmup rate' or diag(scalar @warmup);
  ok @main >= 5   && @main <= 12,  'main publishes at the main rate'     or diag(scalar @main);
  is \@cooldown, [], 'an explicit rate of zero publishes nothing';

  is [map { $_->{phase} } @{$events}], [(map {'warmup'} @warmup), (map {'main'} @main)], 'phases run in order';
};

subtest 'the worker executable honors the process contract' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir    = _run_layout();
  my $input      = _worker_input($run_dir, $port, duration_seconds => 1, publish_rate_per_second => 3);
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'publisher-001', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
  my $output = `$^X -I$repo/lib $worker 2>&1`;
  is $? >> 8, 0, 'worker exits zero after an orderly run' or diag($output);

  my $events = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  ok @{$events} >= 1, 'worker subprocess emitted metric events';

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;

  delete local $ENV{OVERNET_BURNER_WORKER_INPUT};
  my $no_input = `$^X -I$repo/lib $worker 2>&1`;
  isnt $? >> 8, 0, 'worker without input exits non-zero';
  like $no_input, qr/OVERNET_BURNER_WORKER_INPUT/, 'worker names the missing input variable';
};

subtest 'publisher survives a relay restart and measures the outage' => sub {
  my $port      = _free_port();
  my $relay_pid = _spawn_relay($port);

  my $run_dir    = _run_layout();
  my $input      = _worker_input($run_dir, $port, duration_seconds => 8, publish_rate_per_second => 5);
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'publisher-001', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
    exec $^X, "-I$repo/lib", $worker or die "exec: $!";
  }

  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'publisher-001', 'ready');
  my $deadline   = time + 10;
  while (time < $deadline && !-e $ready_path) {
    if (waitpid($pid, WNOHANG) == $pid) {
      die "publisher exited before becoming ready\n";
    }
    sleep 0.05;
  }
  ok -e $ready_path, 'publisher became ready against the original relay';

  sleep 1;
  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
  my $restarted_pid = _spawn_relay($port);

  waitpid $pid, 0;
  is $? >> 8, 0, 'publisher exited cleanly despite the relay restart';

  my $events = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'publisher-001.jsonl'));
  my @errors = grep { $_->{status} eq 'error' } @{$events};
  ok @errors >= 1, 'the outage produced error metrics, not worker death' or diag(scalar @{$events});

  my ($last_error_index) = grep { $events->[$_]{status} eq 'error' } reverse 0 .. $#{$events};
  my @after_recovery = grep { $_->{status} eq 'success' } @{$events}[$last_error_index .. $#{$events}];
  ok @after_recovery >= 1, 'the publisher recovered and published successfully after the restart'
    or diag(JSON->new->canonical(1)->encode($events));

  kill 'TERM', $restarted_pid;
  waitpid $restarted_pid, 0;
};

done_testing;

sub _worker_input {
  my ($run_dir, $port, %workload) = @_;
  return {
    input_version    => 1,
    run_id           => 'worker-test-001',
    run_dir          => $run_dir,
    worker_id        => 'publisher-001',
    role             => 'publisher',
    seed             => 12345,
    duration_seconds => delete $workload{duration_seconds},
    metric_stream    => 'metrics/publisher-001.jsonl',
    ready_file       => 'workers/publisher-001/ready',
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {%workload},
  };
}

sub _run_layout {
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', 'publisher-001'));
  return $run_dir;
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

sub _stored_events {
  my ($port, $pubkey_hex) = @_;

  my $client = Net::Nostr::Client->new;
  my @stored;
  my $cv = AnyEvent->condvar;
  $client->on(event => sub { my (undef, $event) = @_; push @stored, $event });
  $client->on(eose  => sub { $cv->send });
  $client->connect("ws://127.0.0.1:$port");
  $client->subscribe('verify', Net::Nostr::Filter->new(authors => [$pubkey_hex], kinds => [7800]));
  my $timeout = AnyEvent->timer(after => 10, cb => sub { $cv->send });
  $cv->recv;
  $client->disconnect;

  return \@stored;
}

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return $content;
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
