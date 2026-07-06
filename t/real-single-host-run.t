use strictures 2;
use Test2::V0;

use Cwd            qw(abs_path);
use File::Path     qw(make_path);
use File::Spec;
use File::Temp     qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();

my $bin       = abs_path(File::Spec->catfile($FindBin::Bin, q{..}, 'bin', 'overnet-burner'));
my $relay_bin = _relay_bin();

plan skip_all => 'relay-perl checkout not found (need bin/overnet-relay.pl)'
  unless $relay_bin;

my $tmp  = tempdir(CLEANUP => 1);
my $port = _free_port();
my $hf   = File::Spec->catfile($tmp, 'relay-health.json');
my $lf   = File::Spec->catfile($tmp, 'relay.log');
my $pidf = File::Spec->catfile($tmp, 'relay.pid');

my $relay_pid;
END { kill 'TERM', $relay_pid if defined $relay_pid }

my $start_sh  = _write_script("$tmp/relay-start.sh",  qq{$^X "$relay_bin" --host 127.0.0.1 --port $port --health-file "$hf" --log-file "$lf" >/dev/null 2>&1 &\necho \$! > "$pidf"\n});
my $health_sh = _write_script("$tmp/relay-health.sh", qq{for i in \$(seq 1 50); do grep -q '"status":"ready"' "$hf" 2>/dev/null && exit 0; sleep 0.2; done\nexit 1\n});
my $stop_sh   = _write_script("$tmp/relay-stop.sh",   qq{[ -f "$pidf" ] && kill "\$(cat "$pidf")" 2>/dev/null\nexit 0\n});

my $scenario = File::Spec->catfile($tmp, 'real-baseline.yml');
_write_scenario($scenario, $port, "sh $start_sh", "sh $health_sh", "sh $stop_sh");

my $run_id = 'real-single-host';
my $output = `$^X "$bin" run --scenario "$scenario" --runs-dir "$tmp/runs" --run-id $run_id --runner rex-local-workers 2>&1`;
my $exit   = $? >> 8;

if (open my $pf, '<', $pidf) {
  my $line = <$pf>;
  close $pf;
  $relay_pid = $1 if defined $line && $line =~ /(\d+)/mx;
}

is $exit, 0, 'real single-host run completes' or diag $output;

my $report = _read_json(File::Spec->catfile($tmp, 'runs', $run_id, 'report.json'));

ok $report->{metrics}{collected}, 'run collected real Overnet workload metrics'
  or diag(JSON->new->canonical->pretty->encode($report->{metrics} || {}));

my $publish = _stream_events("$tmp/runs/$run_id", 'publisher-001');
ok scalar(@{$publish}) > 0, 'publisher emitted real publish metric events against the relay';
my @accepted = grep { ($_->{status} // q{}) eq 'success' && defined $_->{duration_ms} } @{$publish};
ok scalar(@accepted) > 0, 'the real relay accepted valid Overnet events with real publish latencies'
  or diag(JSON->new->canonical->pretty->encode($publish->[0] || {}));

my $subscribe = _stream_events("$tmp/runs/$run_id", 'subscriber-001');
ok scalar(@{$subscribe}) > 0, 'subscriber emitted real fanout metric events';

ok scalar(@{$report->{thresholds} || []}) > 0, 'thresholds were evaluated against real metrics';

done_testing;

sub _relay_bin {
  for my $dir (
    File::Spec->catdir($FindBin::Bin, q{..}, q{..}, 'relay-perl'),
    File::Spec->catdir($FindBin::Bin, q{..}, q{..}, q{..}, 'relay-perl'),
  ) {
    my $candidate = File::Spec->catfile(abs_path($dir) // q{}, 'bin', 'overnet-relay.pl');
    return $candidate if -f $candidate;
  }
  return;
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}

sub _write_script {
  my ($path, $body) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} "#!/bin/sh\n", $body;
  close $fh or die "close $path: $!";
  return $path;
}

sub _write_scenario {
  my ($path, $port, $start, $health, $stop) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} <<"YAML";
run:
  name: real-single-host-baseline
  duration: 3
  seed: 12345

topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "$start"
      health: "$health"
      stop: "$stop"
    endpoints:
      - ws://127.0.0.1:$port
  publishers:
    count: 1
  subscribers:
    count: 1

workload:
  publish_rate_per_second: 10
  subscription_filters:
    - kinds: [7800]

provision:
  workers:
    how: local

thresholds:
  publish_p99_ms: 2000
  subscription_fanout_p99_ms: 3000
  error_rate_max: 0.5
YAML
  close $fh or die "close $path: $!";
  return;
}

sub _read_json {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $raw = do { local $/ = undef; <$fh> };
  close $fh or die "close $path: $!";
  return JSON::decode_json($raw);
}

sub _stream_events {
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
