use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo = "$FindBin::Bin/..";
my $bin  = "$repo/bin/overnet-burner";

my $tmp = tempdir(CLEANUP => 1);
my ($fake_ssh, $fake_scp) = _write_fake_ssh_tools($tmp);
my $fake_worker = _write_fake_worker($tmp);
my $fake_rex    = _write_fake_rex($tmp);

local $ENV{OVERNET_BURNER_SSH}          = $fake_ssh;
local $ENV{OVERNET_BURNER_SCP}          = $fake_scp;
local $ENV{OVERNET_BURNER_WORKER}       = "$^X $fake_worker";
local $ENV{OVERNET_BURNER_REX}          = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG} = File::Spec->catfile($tmp, 'fake-rex.log');

my $scenario = "$tmp/connect.yml";
_spew($scenario, <<'YAML');
run:
  name: connect-provision
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 2
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
provision:
  workers:
    how: connect
    guests:
      - address: fake-load-1
        user: burner
      - address: fake-load-2
        user: burner
YAML

subtest 'connect-provisioned workers run over the ssh transport' => sub {
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

  my $run_id = 'connect-run-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the run completes over the connect transport' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);

  my $manifest = _read_json(File::Spec->catfile($run_dir, 'manifest.json'));
  is $manifest->{status}, 'completed', 'manifest records completion';

  my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is [map { $_->{name} } @{$guests->{guests}}], ['worker-guest-001', 'worker-guest-002'],
    'guests.json records the provisioned guests';
  is [map { $_->{transport} } @{$guests->{guests}}], ['ssh', 'ssh'], 'connect guests use the ssh transport';
  is $guests->{guests}[0]{address},                  'fake-load-1',  'guest records carry their addresses';
  is $guests->{placement},
    {
    'publisher-001'  => 'worker-guest-001',
    'publisher-002'  => 'worker-guest-002',
    'subscriber-001' => 'worker-guest-001',
    },
    'actors are placed round-robin by ordinal within each role';

  my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
  is scalar @{$aggregated}, 3, 'every stream was pulled and aggregated';

  for my $actor_id (qw(publisher-001 publisher-002 subscriber-001)) {
    ok -s File::Spec->catfile($run_dir, 'metrics', "$actor_id.jsonl"),
      "the $actor_id stream was pulled into the local run directory";
    ok -e File::Spec->catfile($run_dir, 'logs', 'workers', "$actor_id.stdout"),
      "the $actor_id stdout log was pulled into the local run directory";
  }

  my @launched =
    grep { ($_->{event_kind} || q{}) eq 'worker' && $_->{status} eq 'launched' }
    @{_read_jsonl("$run_dir/logs/runner.jsonl")};
  is [map { $_->{guest} } @launched], ['worker-guest-001', 'worker-guest-001', 'worker-guest-002'],
    'launch events record which guest ran each worker';
};

subtest 'local provisioning still runs through the implicit local guest' => sub {
  my $local_scenario = "$tmp/local.yml";
  _spew($local_scenario, <<'YAML');
run:
  name: local-provision
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://127.0.0.1:59999
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
YAML

  my $run_id = 'local-run-001';
  my $output =
    `$^X $bin run --scenario $local_scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the local run completes' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
  my $guests  = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is [map { $_->{transport} } @{$guests->{guests}}], ['exec'], 'the default is one implicit exec guest';
  is $guests->{placement}{'publisher-001'},          'local',  'local placement names the implicit guest';
};

done_testing;

sub _write_fake_ssh_tools {
  my ($dir) = @_;

  my $ssh = File::Spec->catfile($dir, 'fake-ssh');
  _spew($ssh, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;

# Emulates a remote host with its own filesystem: every guest-side path is
# relocated under a shadow root, so nothing the "remote host" writes ever
# appears at the controller-side path.
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

sub _write_fake_worker {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-worker');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strictures 2;
use JSON::PP ();
my $input_path = $ENV{OVERNET_BURNER_WORKER_INPUT} or die "OVERNET_BURNER_WORKER_INPUT is required\n";
open my $in, '<', $input_path or die "open $input_path: $!";
my $input = JSON::PP::decode_json(do { local $/; <$in> });
close $in or die "close: $!";

open my $ready, '>', "$input->{run_dir}/$input->{ready_file}" or die "ready: $!";
close $ready or die "close ready: $!";

my %metric = (
    metric_version => 1,
    run_id         => $input->{run_id},
    worker_id      => $input->{worker_id},
    host           => 'fake-host',
    role           => $input->{role},
    operation      => 'noop_probe',
    started_at     => '2026-07-03T18:00:00Z',
    finished_at    => '2026-07-03T18:00:00.001Z',
    duration_ms    => 1,
    status         => 'success',
);
open my $stream, '>>', "$input->{run_dir}/$input->{metric_stream}" or die "stream: $!";
print {$stream} JSON::PP->new->canonical(1)->encode(\%metric), "\n" or die "print: $!";
close $stream or die "close stream: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _read_json {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return JSON::decode_json($content);
}

sub _read_jsonl {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return [map { JSON::decode_json($_) } grep {/\S/} split /\n/, $content];
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
