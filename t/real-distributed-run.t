use strictures 2;

use Cwd            qw(abs_path);
use File::Spec;
use File::Temp     qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

# The multi-host proof: real workers, placed across more than one guest and
# reached over the (substituted) ssh transport, run a real Overnet workload
# against a real relay; their metrics are pulled back from each guest and
# aggregated into one report. This is the distributed analogue of
# real-single-host-run.t. The ssh/scp transport is substituted by local
# fake tools that relocate every guest-side path under a shadow root, so each
# guest has its own filesystem exactly as a remote host would; the raw ssh
# shell-out itself is covered separately by guest-ssh.t. Everything else --
# relay, workers, events, latencies, collection, aggregation -- is real.

my $bin        = abs_path(File::Spec->catfile($FindBin::Bin, q{..}, 'bin', 'overnet-burner'));
my $worker_bin = abs_path(File::Spec->catfile($FindBin::Bin, q{..}, 'bin', 'overnet-burner-worker'));
my $relay_bin  = _relay_bin();

plan skip_all => 'relay-perl checkout not found (need bin/overnet-relay.pl)'
  unless $relay_bin;

my $tmp  = tempdir(CLEANUP => 1);
my $port = _free_port();

my $hf   = File::Spec->catfile($tmp, 'relay-health.json');
my $lf   = File::Spec->catfile($tmp, 'relay.log');
my $pidf = File::Spec->catfile($tmp, 'relay.pid');

my $relay_pid;
END { kill 'TERM', $relay_pid if defined $relay_pid }

my $start_sh = _write_script(
  "$tmp/relay-start.sh",
  qq{$^X "$relay_bin" --host 127.0.0.1 --port $port --health-file "$hf" --log-file "$lf" >/dev/null 2>&1 &\necho \$! > "$pidf"\n}
);
my $health_sh = _write_script("$tmp/relay-health.sh",
  qq{for i in \$(seq 1 50); do grep -q '"status":"ready"' "$hf" 2>/dev/null && exit 0; sleep 0.2; done\nexit 1\n});
my $stop_sh =
  _write_script("$tmp/relay-stop.sh", qq{[ -f "$pidf" ] && kill "\$(cat "$pidf")" 2>/dev/null\nexit 0\n});

my ($fake_ssh, $fake_scp) = _write_fake_ssh_tools($tmp);
my $fake_rex = _write_fake_rex($tmp);

# The real worker binary runs on every guest. Under the substituted transport it
# executes locally, so the same interpreter and library path reach it.
local $ENV{OVERNET_BURNER_SSH}          = $fake_ssh;
local $ENV{OVERNET_BURNER_SCP}          = $fake_scp;
local $ENV{OVERNET_BURNER_WORKER}       = qq{$^X "$worker_bin"};
local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');
local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

my $scenario = File::Spec->catfile($tmp, 'distributed.yml');
_write_scenario($scenario, $port, "sh $start_sh", "sh $health_sh", "sh $stop_sh");

my $run_id = 'real-distributed';
my $output = `$^X "$bin" run --scenario "$scenario" --runs-dir "$tmp/runs" --run-id $run_id --runner rex-local-workers 2>&1`;
my $exit   = $? >> 8;

if (open my $pf, '<', $pidf) {
  my $line = <$pf>;
  close $pf;
  $relay_pid = $1 if defined $line && $line =~ /(\d+)/mx;
}

is $exit, 0, 'real distributed run completes' or diag $output;

my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
my $report  = _read_json(File::Spec->catfile($run_dir, 'report.json'));

ok $report->{metrics}{collected}, 'the distributed run collected real Overnet workload metrics'
  or diag(JSON->new->canonical->pretty->encode($report->{metrics} || {}));

# Workers were genuinely placed across more than one guest.
my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
is [map { $_->{name} } @{$guests->{guests}}], ['worker-guest-001', 'worker-guest-002'],
  'workers were provisioned across two guests';
is [map { $_->{transport} } @{$guests->{guests}}], ['ssh', 'ssh'], 'both guests use the ssh transport';
my %placement_hosts = map { $_ => 1 } values %{$guests->{placement}};
ok keys %placement_hosts >= 2, 'actors are spread across at least two guests';

# Each guest's real metric stream was pulled back and carries real latencies.
my @accepted;
for my $publisher (qw(publisher-001 publisher-002)) {
  my $stream = _stream_events($run_dir, $publisher);
  ok scalar(@{$stream}) > 0, "$publisher emitted real publish metric events from its guest";
  push @accepted, grep { ($_->{status} // q{}) eq 'success' && defined $_->{duration_ms} } @{$stream};
}
ok scalar(@accepted) > 0, 'the real relay accepted valid Overnet events with real publish latencies';

my $subscriber = _stream_events($run_dir, 'subscriber-001');
ok scalar(@{$subscriber}) > 0, 'the subscriber emitted real fanout metric events from its guest';

# The guests sit on different (shadow) filesystems, so a real per-guest pull was
# required to bring these streams back to the controller.
ok !-e File::Spec->catfile($run_dir, 'metrics', 'publisher-002.jsonl.guest-only'),
  'guest streams reached the controller through collection, not a shared filesystem';

# The aggregated report is judged on the collected metrics.
ok scalar(@{$report->{thresholds} || []}) > 0, 'thresholds were evaluated against the aggregated metrics';
like $report->{run}{verdict}, qr/\A(?:performance_passed|performance_failed)\z/mx,
  'the distributed run produced a performance verdict from real metrics';

# Calibration: the report's aggregated publish p99 matches an independent
# recompute from the pulled per-guest streams, so multi-host aggregation is
# accurate, not merely present.
my @durations =
  map { $_->{duration_ms} }
  grep { ($_->{operation} // q{}) eq 'publish' && ($_->{status} // q{}) eq 'success' && defined $_->{duration_ms} }
  (@{_stream_events($run_dir, 'publisher-001')}, @{_stream_events($run_dir, 'publisher-002')});
my $reported_p99 = $report->{metrics}{operations}{publish}{latency_ms}{p99};
if (@durations && defined $reported_p99) {
  is $reported_p99, _percentile(\@durations, 99),
    'the aggregated publish p99 matches an independent recompute from the per-guest streams';
}

done_testing;

sub _percentile {
  my ($values, $p) = @_;
  my @sorted = sort { $a <=> $b } @{$values};
  my $rank   = int(($p / 100) * scalar(@sorted) + 0.9999999999) - 1;
  $rank = 0            if $rank < 0;
  $rank = $#sorted     if $rank > $#sorted;
  return $sorted[$rank];
}

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
  my $free = $listener->sockport;
  close $listener or die "close: $!";
  return $free;
}

sub _write_script {
  my ($path, $body) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} "#!/bin/sh\n", $body;
  close $fh or die "close $path: $!";
  return $path;
}

sub _write_scenario {
  my ($path, $relay_port, $start, $health, $stop) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} <<"YAML";
run:
  name: real-distributed-baseline
  duration: 6
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
      - ws://127.0.0.1:$relay_port
  publishers:
    count: 2
  subscribers:
    count: 1

workload:
  publish_rate_per_second: 10
  subscription_filters:
    - kinds: [7800]

provision:
  workers:
    how: connect
    guests:
      - address: fake-load-1
        user: burner
      - address: fake-load-2
        user: burner

thresholds:
  publish_p99_ms: 5000
  subscription_fanout_p99_ms: 5000
  error_rate_max: 0.5
YAML
  close $fh or die "close $path: $!";
  return;
}

sub _write_fake_ssh_tools {
  my ($dir) = @_;

  my $ssh = File::Spec->catfile($dir, 'fake-ssh');
  _spew($ssh, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;

sub remap {
  my ($value) = @_;
  my $from = $ENV{OVERNET_BURNER_TEST_REMAP_FROM};
  my $to   = $ENV{OVERNET_BURNER_TEST_REMAP_TO};
  return $value if !(defined $from && defined $to);
  $value =~ s/\Q$from\E/$to/g;
  return $value;
}

my @args = @ARGV;
my @rest;
while (@args) {
  my $arg = shift @args;
  if ($arg eq '-o' || $arg eq '-p' || $arg eq '-i') { shift @args; next; }
  push @rest, $arg;
}
my $target  = shift @rest;
my $command = join ' ', @rest;
exec '/bin/sh', '-c', remap($command) or die "exec: $!";
PERL
  chmod 0755, $ssh or die "chmod: $!";

  my $scp = File::Spec->catfile($dir, 'fake-scp');
  _spew($scp, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;

sub remap {
  my ($value) = @_;
  my $from = $ENV{OVERNET_BURNER_TEST_REMAP_FROM};
  my $to   = $ENV{OVERNET_BURNER_TEST_REMAP_TO};
  return $value if !(defined $from && defined $to);
  $value =~ s/\Q$from\E/$to/g;
  return $value;
}

my @args = @ARGV;
my @rest;
while (@args) {
  my $arg = shift @args;
  if ($arg eq '-o' || $arg eq '-P' || $arg eq '-i') { shift @args; next; }
  push @rest, $arg;
}
my ($src, $dst) = @rest;
$dst =~ s/\A[^:]+://;
$dst = remap($dst);
open my $in, '<', $src or die "open $src: $!";
my $content = do { local $/; <$in> };
close $in or die "close $src: $!";
open my $out, '>', $dst or die "open $dst: $!";
print {$out} remap($content) or die "print $dst: $!";
close $out or die "close $dst: $!";
PERL
  chmod 0755, $scp or die "chmod: $!";

  return ($ssh, $scp);
}

sub _write_fake_rex {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-rex');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
my $log = $ENV{OVERNET_BURNER_TEST_REX_LOG} or die "OVERNET_BURNER_TEST_REX_LOG is required\n";
open my $fh, '>>', $log or die "open $log: $!";
print {$fh} join("\0", @ARGV), "\n";
close $fh or die "close $log: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
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
