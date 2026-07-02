use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON  ();
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo   = "$FindBin::Bin/..";
my $worker = "$repo/bin/overnet-burner-worker";
my $tmp    = tempdir(CLEANUP => 1);

subtest 'object reader measures derived object read round trips' => sub {
  my $port         = _free_port();
  my $endpoint_pid = _spawn_object_endpoint($port);

  my $run_dir = _run_layout('object-reader-001');
  my $input   = {
    input_version    => 1,
    run_id           => 'object-reader-test-001',
    run_dir          => $run_dir,
    worker_id        => 'object-reader-001',
    role             => 'object_reader',
    seed             => 12345,
    duration_seconds => 2,
    metric_stream    => 'metrics/object-reader-001.jsonl',
    ready_file       => 'workers/object-reader-001/ready',
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {
      object_reads => {
        rate_per_second => 5,
        objects         =>
          [{type => 'burner.workload', id => 'burner-obj-1'}, {type => 'burner.workload', id => 'burner-missing'},],
      },
    },
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'object-reader-001', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
    exec $^X, "-I$repo/lib", $worker or die "exec: $!";
  }

  my $ready_path = File::Spec->catfile($run_dir, 'workers', 'object-reader-001', 'ready');
  my $deadline   = time + 10;
  while (time < $deadline && !-e $ready_path) {
    if (waitpid($pid, WNOHANG) == $pid) {
      die "object reader exited before becoming ready\n";
    }
    sleep 0.05;
  }
  ok -e $ready_path, 'object reader wrote its ready file after probing the endpoint';

  waitpid $pid, 0;
  is $? >> 8, 0, 'object reader exited cleanly after its duration';

  my $stream =
    Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', 'object-reader-001.jsonl'));
  ok @{$stream} >= 3, 'object reader issued repeated reads' or diag(scalar @{$stream});

  my @bad_shape = grep { $_->{operation} ne 'object_read' } @{$stream};
  is \@bad_shape, [], 'object read metrics use the object_read operation';

  is [map { $_->{object_id} } @{$stream}[0 .. 1]], ['burner-obj-1', 'burner-missing'],
    'object reader cycles through the configured references in order';

  my @successes = grep { $_->{status} eq 'success' } @{$stream};
  ok @successes >= 1, 'fulfilled reads are successes';
  my @bad_successes =
    grep { $_->{object_id} ne 'burner-obj-1' || ($_->{http_status} || 0) != 200 } @successes;
  is \@bad_successes, [], 'successes name the stored object with http status 200';

  my @refusals = grep { $_->{status} eq 'error' } @{$stream};
  ok @refusals >= 1, 'structured relay refusals are error metrics';
  my @bad_refusals = grep {
         $_->{object_id} ne 'burner-missing'
      || ($_->{http_status} || 0) != 404
      || ($_->{error}       || q{}) ne 'not_found'
  } @refusals;
  is \@bad_refusals, [], 'refusals carry the relay outcome code and http status';

  my @bad_types = grep { $_->{object_type} ne 'burner.workload' } @{$stream};
  is \@bad_types, [], 'object read metrics carry the object type';

  my @bad_durations = grep { $_->{duration_ms} < 0 || $_->{duration_ms} > 5000 } @{$stream};
  is \@bad_durations, [], 'object read durations are plausible for a local endpoint';

  kill 'TERM', $endpoint_pid;
  waitpid $endpoint_pid, 0;
};

subtest 'object reader requires object references' => sub {
  my $run_dir = _run_layout('object-reader-002');
  my $input   = {
    input_version    => 1,
    run_id           => 'object-reader-test-002',
    run_dir          => $run_dir,
    worker_id        => 'object-reader-002',
    role             => 'object_reader',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => 'metrics/object-reader-002.jsonl',
    ready_file       => 'workers/object-reader-002/ready',
    endpoints        => {relays       => ['ws://127.0.0.1:1']},
    workload         => {object_reads => {rate_per_second => 1, objects => []}},
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'object-reader-002', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
  my $output = `$^X -I$repo/lib $worker 2>&1`;
  isnt $? >> 8, 0, 'object reader without references exits non-zero';
  like $output, qr/object_reads\.objects/, 'failure names the missing workload field';
};

subtest 'object reader fails fast on an unreachable endpoint' => sub {
  my $run_dir = _run_layout('object-reader-003');
  my $input   = {
    input_version    => 1,
    run_id           => 'object-reader-test-003',
    run_dir          => $run_dir,
    worker_id        => 'object-reader-003',
    role             => 'object_reader',
    seed             => 12345,
    duration_seconds => 1,
    metric_stream    => 'metrics/object-reader-003.jsonl',
    ready_file       => 'workers/object-reader-003/ready',
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    workload         => {
      object_reads => {
        rate_per_second => 1,
        objects         => [{type => 'burner.workload', id => 'burner-obj-1'}],
      },
    },
  };
  my $input_path = File::Spec->catfile($run_dir, 'workers', 'object-reader-003', 'input.json');
  _spew($input_path, JSON->new->canonical(1)->encode($input));

  local $ENV{OVERNET_BURNER_WORKER_INPUT} = $input_path;
  my $output = `$^X -I$repo/lib $worker 2>&1`;
  isnt $? >> 8, 0, 'object reader with an unreachable endpoint exits non-zero';
  like $output, qr/unreachable/, 'failure reports the unreachable endpoint';
  ok !-e File::Spec->catfile($run_dir, 'workers', 'object-reader-003', 'ready'),
    'object reader never claimed readiness';
};

done_testing;

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _spawn_object_endpoint {
  my ($port) = @_;

  my $script = File::Spec->catfile($tmp, 'fake-object-endpoint');
  _spew($script, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;

my ($host, $port) = @ARGV;
my $listener = IO::Socket::INET->new(
  LocalAddr => $host,
  LocalPort => $port,
  Listen    => 10,
  ReuseAddr => 1,
) or die "listen: $!";

while (my $conn = $listener->accept) {
  my $request_line = <$conn> // '';
  while (defined(my $line = <$conn>)) { last if $line =~ /^\r?\n\z/ }
  my ($path) = $request_line =~ m{\AGET\s+(\S+)};
  $path //= '';

  my ($status, $body);
  if ($path =~ m{\A/\.well-known/overnet/v1/object(?:\?(.*))?\z}) {
    my %query = map { my ($k, $v) = split /=/, $_, 2; ($k, $v // '') } split /&/, ($1 // '');
    if (($query{type} // '') eq 'burner.workload' && ($query{id} // '') eq 'burner-obj-1') {
      $status = '200 OK';
      $body   = '{"object_type":"burner.workload","object_id":"burner-obj-1","removed":false,'
        . '"state_event":{"id":"ab12","kind":37800},"removal_event":null}';
    } elsif (($query{id} // '') eq 'burner-missing') {
      ($status, $body) = ('404 Not Found', '{"error":{"code":"not_found"}}');
    } else {
      ($status, $body) = ('400 Bad Request', '{"error":{"code":"invalid"}}');
    }
  } else {
    ($status, $body) = ('404 Not Found', '{"error":{"code":"not_found"}}');
  }

  print {$conn} "HTTP/1.1 $status\r\n"
    . "Content-Type: application/json\r\n"
    . 'Content-Length: ' . length($body) . "\r\n"
    . "Connection: close\r\n\r\n$body";
  close $conn;
}
PERL

  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    exec $^X, $script, '127.0.0.1', $port or die "exec: $!";
  }

  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) {
      close $probe or die "close: $!";
      return $pid;
    }
    if (waitpid($pid, WNOHANG) != 0) {
      die "object endpoint child exited before listening\n";
    }
    sleep 0.1;
  }
  die "object endpoint child never listened on port $port\n";
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
