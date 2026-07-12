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
use Overnet::Burner::Worker::ObjectReader;

# In-process unit coverage for the object reader: origin derivation, the
# fatal paths, a full localhost run, and the per-response branches of a
# single read driven through a duck-typed HTTP client.

subtest 'expected role and origin derivation' => sub {
  is(Overnet::Burner::Worker::ObjectReader->expected_role,
    'object_reader', 'the reader declares the object_reader role');

  my $derive = sub { Overnet::Burner::Worker::ObjectReader->_object_read_origin(shift) };
  is $derive->('ws://127.0.0.1:8080'),   'http://127.0.0.1:8080',  'ws maps to http';
  is $derive->('wss://relay.example'),   'https://relay.example',  'wss maps to https';
  is $derive->('http://relay.example/'), 'http://relay.example',   'trailing slashes are trimmed';
  is $derive->('https://relay.example'), 'https://relay.example',  'https is left intact';
  like dies { $derive->('tcp://relay.example') }, qr/cannot\ derive\ an\ object\ read\ origin/mx,
    'an unsupported scheme is fatal';
};

subtest 'url escaping encodes reserved characters' => sub {
  is Overnet::Burner::Worker::ObjectReader::_url_escape('a b/c?d'), 'a%20b%2Fc%3Fd',
    'reserved characters become percent escapes';
  is Overnet::Burner::Worker::ObjectReader::_url_escape('safe-._~'), 'safe-._~',
    'unreserved characters are preserved';
};

subtest 'run rejects a workload without object references' => sub {
  my $reader = Overnet::Burner::Worker::ObjectReader->new(input => _input(_layout('or-empty'), 'or-empty', []));
  like dies { $reader->run }, qr/object_reads\.objects/mx, 'an empty object list is fatal';
};

subtest 'run fails fast when the endpoint is unreachable' => sub {
  my $run_dir = _layout('or-down');
  my $reader  = Overnet::Burner::Worker::ObjectReader->new(
    input => _input($run_dir, 'or-down', [{type => 'burner.workload', id => 'x'}], 'ws://127.0.0.1:1'),
  );
  like dies { $reader->run }, qr/unreachable/mx, 'an unreachable endpoint is fatal';
  ok !-e File::Spec->catfile($run_dir, 'workers', 'or-down', 'ready'),
    'the reader never claimed readiness';
};

subtest 'a full localhost run measures successes and refusals' => sub {
  my $port          = _free_port();
  my $endpoint_pid  = _spawn_endpoint($port);
  my $run_dir       = _layout('or-run');
  my $reader        = Overnet::Burner::Worker::ObjectReader->new(
    input => _input(
      $run_dir, 'or-run',
      [
        {type => 'burner.workload', id => 'burner-obj-1'},
        {type => 'burner.workload', id => 'burner-missing'},
        {type => 'burner.workload', id => 'burner-weird'},
      ],
      "ws://127.0.0.1:$port",
      0.6, 20,
    ),
  );

  $reader->run;

  ok -e File::Spec->catfile($run_dir, 'workers', 'or-run', 'ready'),
    'the reader wrote its ready file';

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'or-run.jsonl'));
  ok @{$stream} >= 3, 'several reads were issued' or diag scalar @{$stream};

  my %by_id = map { $_->{object_id} => $_ } @{$stream};
  is $by_id{'burner-obj-1'}{status},     'success', 'the stored object read succeeds';
  is $by_id{'burner-obj-1'}{http_status}, 200,      'the success carries http 200';
  is $by_id{'burner-missing'}{status},   'error',   'the missing object read is an error';
  is $by_id{'burner-missing'}{error},    'not_found', 'the refusal carries the relay code';
  is $by_id{'burner-weird'}{error},      'http_404', 'an undecodable refusal falls back to the status code';

  kill 'TERM', $endpoint_pid;
  waitpid $endpoint_pid, 0;
};

subtest 'a single read reports an unreachable relay as a structured error' => sub {
  my $run_dir = _layout('or-single');
  my $reader  = Overnet::Burner::Worker::ObjectReader->new(
    input => _input($run_dir, 'or-single', [{type => 'burner.workload', id => 'x'}]),
  );
  $reader->{host} = 'test-host';
  $reader->open_metric_stream;

  my $unreachable = _fake_http(sub { return {status => 599, content => "connection refused\nmore"} });
  $reader->_read_once(
    http   => $unreachable,
    origin => 'http://127.0.0.1:9',
    object => {type => 'burner.workload', id => 'x'},
    phase  => 'main',
  );

  my $empty599 = _fake_http(sub { return {status => 599, content => q{}} });
  $reader->_read_once(
    http   => $empty599,
    origin => 'http://127.0.0.1:9',
    object => {type => 'burner.workload', id => 'x'},
    phase  => 'main',
  );
  $reader->close_metric_stream;

  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'or-single.jsonl'));
  is $stream->[0]{status}, 'error',              'a 599 read is an error';
  is $stream->[0]{error},  'connection refused', 'the first line of the content is the reason';
  is $stream->[1]{error},  'object read failed', 'an empty 599 body gets a default reason';
};

subtest 'a TERM signal stops the reader between phases' => sub {
  my $port         = _free_port();
  my $endpoint_pid = _spawn_endpoint($port);
  my $run_dir      = _layout('or-term');
  my $input        = _input($run_dir, 'or-term', [{type => 'burner.workload', id => 'burner-obj-1'}],
    "ws://127.0.0.1:$port");
  $input->{duration_seconds} = 10;
  $input->{phases}           = [
    {name => 'p1', start_seconds => 0, duration_seconds => 5, object_reads => {rate_per_second => 20}},
    {name => 'p2', start_seconds => 5, duration_seconds => 5, object_reads => {rate_per_second => 20}},
  ];
  my $reader = Overnet::Burner::Worker::ObjectReader->new(input => $input);

  my $parent = $$;
  my $killer = fork;
  die "fork: $!" if !defined $killer;
  if (!$killer) {
    sleep 0.5;
    kill 'TERM', $parent;
    exit 0;
  }

  $reader->run;    # returns early once the TERM handler flips the stop flag
  waitpid $killer, 0;

  ok -e File::Spec->catfile($run_dir, 'workers', 'or-term', 'ready'),
    'the reader became ready before the signal arrived';
  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'or-term.jsonl'));
  my @phase2 = grep { $_->{phase} eq 'p2' } @{$stream};
  is \@phase2, [], 'the reader stopped before entering the second phase';

  kill 'TERM', $endpoint_pid;
  waitpid $endpoint_pid, 0;
};

subtest 'an idle phase paces nothing but still completes' => sub {
  my $run_dir = _layout('or-idle');
  my $reader  = Overnet::Burner::Worker::ObjectReader->new(
    input => _input($run_dir, 'or-idle', [{type => 'burner.workload', id => 'x'}]),
  );
  my $stop = 0;
  my $done = $reader->_run_phase(
    http    => _fake_http(sub { die "idle phase must not read\n" }),
    origin  => 'http://127.0.0.1:9',
    objects => [{type => 'burner.workload', id => 'x'}],
    phase   => {name => 'idle', start_seconds => 0, duration_seconds => 0, object_reads => {rate_per_second => 0}},
    started => time,
    stop    => \$stop,
  );
  is $done, 1, 'the idle phase returns cleanly without issuing reads';
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
  my ($run_dir, $worker_id, $objects, $relay, $duration, $rate) = @_;
  $relay    //= 'ws://127.0.0.1:1';
  $duration //= 1;
  $rate     //= 5;
  return {
    input_version    => 1,
    run_id           => "run-$worker_id",
    run_dir          => $run_dir,
    worker_id        => $worker_id,
    role             => 'object_reader',
    seed             => 12345,
    duration_seconds => $duration,
    metric_stream    => "metrics/$worker_id.jsonl",
    ready_file       => "workers/$worker_id/ready",
    endpoints        => {relays => [$relay]},
    workload         => {object_reads => {rate_per_second => $rate, objects => $objects}},
  };
}

sub _fake_http {
  my ($handler) = @_;
  return bless {handler => $handler}, '_FakeHTTP';
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _spawn_endpoint {
  my ($port) = @_;
  my $script = File::Spec->catfile(tempdir(CLEANUP => 1), 'fake-object-endpoint');
  _spew($script, <<'PERL');
use strict;
use warnings;
use IO::Socket::INET;
my ($host, $port) = @ARGV;
my $listener = IO::Socket::INET->new(
  LocalAddr => $host, LocalPort => $port, Listen => 10, ReuseAddr => 1,
) or die "listen: $!";
while (my $conn = $listener->accept) {
  my $request_line = <$conn> // '';
  while (defined(my $line = <$conn>)) { last if $line =~ /^\r?\n\z/ }
  my ($path) = $request_line =~ m{\AGET\s+(\S+)};
  $path //= '';
  my ($status, $body);
  if ($path =~ m{\A/\.well-known/overnet/v1/object(?:\?(.*))?\z}) {
    my %q = map { my ($k, $v) = split /=/, $_, 2; ($k, $v // '') } split /&/, ($1 // '');
    if (($q{id} // '') eq 'burner-obj-1') {
      $status = '200 OK';
      $body   = '{"object_type":"burner.workload","object_id":"burner-obj-1"}';
    } elsif (($q{id} // '') eq 'burner-missing') {
      ($status, $body) = ('404 Not Found', '{"error":{"code":"not_found"}}');
    } elsif (($q{id} // '') eq 'burner-weird') {
      ($status, $body) = ('404 Not Found', 'not json at all');
    } else {
      ($status, $body) = ('200 OK', '{}');
    }
  } else {
    ($status, $body) = ('404 Not Found', '{"error":{"code":"not_found"}}');
  }
  print {$conn} "HTTP/1.1 $status\r\nContent-Type: application/json\r\n"
    . 'Content-Length: ' . length($body) . "\r\nConnection: close\r\n\r\n$body";
  close $conn;
}
PERL
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) { exec $^X, $script, '127.0.0.1', $port or die "exec: $!" }
  my $deadline = time + 10;
  while (time < $deadline) {
    my $probe = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 1);
    if ($probe) { close $probe or die "close: $!"; return $pid }
    if (waitpid($pid, WNOHANG) != 0) { die "endpoint exited before listening\n" }
    sleep 0.1;
  }
  die "endpoint never listened on port $port\n";
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh or die "close $path: $!";
  return;
}

package _FakeHTTP;
sub get { my ($self, $url) = @_; return $self->{handler}->($url) }
