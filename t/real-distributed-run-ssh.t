use strictures 2;

use Cwd            qw(abs_path);
use File::Spec;
use File::Temp     qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

# The real-ssh variant of the distributed multi-host proof. Where
# real-distributed-run.t substitutes local fake ssh/scp tools that relocate
# guest-side paths, this run drives the SAME rex-local-workers orchestration --
# placement across guests, remote staging, remote launch, readiness polling, and
# per-guest metric collection -- over a REAL sshd. It closes the gap where the
# distributed worker path was only ever exercised over the substitute transport;
# the raw ssh primitives are covered by guest-ssh.t, the relay lifecycle over ssh
# by runner-rex-remote.t, but only this test runs the whole worker orchestration
# over the real ssh/scp shell-out. It needs a reachable sshd (CI provisions
# localhost); set OVERNET_BURNER_TEST_SSH_HOST to enable it.

plan skip_all => 'set OVERNET_BURNER_TEST_SSH_HOST to run the distributed path over a real sshd'
  if !$ENV{OVERNET_BURNER_TEST_SSH_HOST};

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

my $fake_rex = _write_fake_rex($tmp);

# The real worker binary runs on the guest over a real sshd, in a fresh login
# session that does not inherit this process's @INC, so the worker command
# carries the interpreter's library path (installed deps plus the sibling
# checkouts) explicitly. The relay stays on the controller.
local $ENV{OVERNET_BURNER_WORKER}       = _worker_command($worker_bin);
local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

my $scenario = File::Spec->catfile($tmp, 'distributed-ssh.yml');
_write_scenario($scenario, $port, "sh $start_sh", "sh $health_sh", "sh $stop_sh");

my $run_id = 'real-distributed-ssh';
my $output = `$^X "$bin" run --scenario "$scenario" --runs-dir "$tmp/runs" --run-id $run_id --runner rex-local-workers 2>&1`;
my $exit   = $? >> 8;

if (open my $pf, '<', $pidf) {
  my $line = <$pf>;
  close $pf;
  $relay_pid = $1 if defined $line && $line =~ /(\d+)/mx;
}

is $exit, 0, 'the distributed run completes over a real sshd' or diag $output;

my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
my $report  = _read_json(File::Spec->catfile($run_dir, 'report.json'));

ok $report->{metrics}{collected}, 'the run collected real Overnet workload metrics over ssh'
  or diag(JSON->new->canonical->pretty->encode($report->{metrics} || {}));

# Workers were placed across more than one guest, each reached over real ssh.
my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
is [map { $_->{name} } @{$guests->{guests}}], ['worker-guest-001', 'worker-guest-002'],
  'workers were provisioned across two guests';
is [map { $_->{transport} } @{$guests->{guests}}], ['ssh', 'ssh'], 'both guests use the ssh transport';
my %placement_hosts = map { $_ => 1 } values %{$guests->{placement}};
ok keys %placement_hosts >= 2, 'actors are spread across at least two guests';

# Each guest's real metric stream was pulled back over scp and carries real
# latencies.
my @accepted;
for my $publisher (qw(publisher-001 publisher-002)) {
  my $stream = _stream_events($run_dir, $publisher);
  ok scalar(@{$stream}) > 0, "$publisher emitted real publish metric events collected over ssh";
  push @accepted, grep { ($_->{status} // q{}) eq 'success' && defined $_->{duration_ms} } @{$stream};
}
ok scalar(@accepted) > 0, 'the real relay accepted valid Overnet events with real publish latencies';

my $subscriber = _stream_events($run_dir, 'subscriber-001');
ok scalar(@{$subscriber}) > 0, 'the subscriber emitted real fanout metric events collected over ssh';

# The aggregated report is judged on the collected metrics, and the aggregated
# publish p99 matches an independent recompute from the pulled per-guest
# streams -- so collection and aggregation over the real transport are accurate.
ok scalar(@{$report->{thresholds} || []}) > 0, 'thresholds were evaluated against the aggregated metrics';
like $report->{run}{verdict}, qr/\A(?:performance_passed|performance_failed)\z/mx,
  'the distributed run produced a performance verdict from real metrics';

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

# The worker runs in a fresh ssh session; carry the interpreter library path so
# it finds the burner, its dependencies, and the sibling checkouts.
sub _worker_command {
  my ($worker) = @_;
  my @libs = grep { defined && length } (
    "$FindBin::Bin/../lib",
    abs_path(File::Spec->catdir($FindBin::Bin, q{..}, q{..}, 'core-perl',  'lib')),
    abs_path(File::Spec->catdir($FindBin::Bin, q{..}, q{..}, 'relay-perl', 'lib')),
    split(/:/mx, ($ENV{PERL5LIB} // q{})),
  );
  my $perl5lib = join ':', @libs;
  return qq{PERL5LIB='$perl5lib' $^X "$worker"};
}

sub _percentile {
  my ($values, $p) = @_;
  my @sorted = sort { $a <=> $b } @{$values};
  my $rank   = int(($p / 100) * scalar(@sorted) + 0.9999999999) - 1;
  $rank = 0        if $rank < 0;
  $rank = $#sorted if $rank > $#sorted;
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
  my $host = $ENV{OVERNET_BURNER_TEST_SSH_HOST};
  my $user = $ENV{OVERNET_BURNER_TEST_SSH_USER};
  my $key  = $ENV{OVERNET_BURNER_TEST_SSH_KEY};
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} <<"YAML";
run:
  name: real-distributed-ssh-baseline
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
      - address: $host
@{[ $user ? "        user: $user" : '' ]}
@{[ $key  ? "        key: $key"   : '' ]}
      - address: $host
@{[ $user ? "        user: $user" : '' ]}
@{[ $key  ? "        key: $key"   : '' ]}

thresholds:
  publish_p99_ms: 5000
  subscription_fanout_p99_ms: 5000
  error_rate_max: 0.5
YAML
  close $fh or die "close $path: $!";
  return;
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
