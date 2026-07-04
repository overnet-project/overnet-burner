use strictures 2;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

my $repo = "$FindBin::Bin/..";
my $bin  = "$repo/bin/overnet-burner";

my $tmp         = tempdir(CLEANUP => 1);
my $engine_log  = File::Spec->catfile($tmp, 'engine-argv.log');
my $fake_engine = _write_emulating_engine($tmp);
my $fake_rex    = _write_fake_rex($tmp);
my $fake_worker = _write_fake_overnet_burner($tmp);
my $fake_relay  = _write_fake_relay($tmp);

local $ENV{OVERNET_BURNER_DOCKER}          = $fake_engine;
local $ENV{OVERNET_BURNER_REX}             = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $engine_log;
local $ENV{OVERNET_BURNER_TEST_REX_LOG}    = File::Spec->catfile($tmp, 'fake-rex.log');
local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');
local $ENV{PATH}                           = join ':', $tmp, $ENV{PATH};

subtest 'managed local-containers run builds and tears down a complete reference stack' => sub {
  my $scenario = File::Spec->catfile($tmp, 'managed.yml');
  _spew($scenario, <<'YAML');
environment:
  kind: local-containers
  engine: docker
run:
  name: managed-local-containers
  duration: 2
  seed: 12345
topology:
  relays:
    count: 2
  publishers:
    count: 2
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
YAML

  my $run_id = 'managed-local-containers-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the managed container run completes' or diag($output);
  like $output,
    qr/completed\ run:\ \Q$tmp\E\/runs\/\Q$run_id\E\nwrote\ report:\ \Q$tmp\E\/runs\/\Q$run_id\E\/report\.json/mx,
    'the CLI reports completion and automatic report generation';

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
  ok -f File::Spec->catfile($run_dir, 'report.json'), 'the run writes report.json';

  my $config = _read_json(File::Spec->catfile($run_dir, 'config.normalized.json'));
  is $config->{topology}{relays}{endpoints}, ['ws://relay-001:7447', 'ws://relay-002:7447'],
    'the run ledger records synthesized relay endpoints';

  my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is [map { $_->{transport} } @{$guests->{guests}}], ['container', 'container', 'container'],
    'worker guests are container provisioned';
  is $guests->{network}, {name => "burner-$run_id", mode => 'bridge'},
    'the worker guest ledger records the per-run bridge network';

  my $relay_guests = _read_json(File::Spec->catfile($run_dir, 'relay-guests.json'));
  is [map { $_->{alias} } @{$relay_guests->{guests}}], ['relay-001', 'relay-002'],
    'relay guests record their stable network aliases';
  is $relay_guests->{network}, {name => "burner-$run_id", mode => 'bridge'},
    'the relay guest ledger records the shared run network';

  my $manifest = _read_json(File::Spec->catfile($run_dir, 'manifest.json'));
  is $manifest->{status}, 'completed', 'the manifest records a completed run';
  is [map { $_->{command_kind} } @{$manifest->{lifecycle}{topology_provider_commands}}],
    ['start', 'health', 'start', 'health', 'stop', 'stop'],
    'relay lifecycle commands ran for every managed relay';

  my $argv = _slurp($engine_log);
  like $argv, qr/build\x{0}-t\x{0}overnet-burner-reference:local/mx, 'the managed run builds the reference image';
  like $argv, qr/^network\x{0}create\x{0}burner-\Q$run_id\E$/mx,     'the run creates a bridge network';
  is scalar(grep {/\Arun\x{0}-d\x{0}--name\x{0}burner-\Q$run_id\E-relay-guest-/mx} split /\n/, $argv), 2,
    'the run starts one relay container per configured relay';
  is scalar(grep {/\Arun\x{0}-d\x{0}--name\x{0}burner-\Q$run_id\E-worker-guest-/mx} split /\n/, $argv), 3,
    'the run starts one worker container per worker actor';
  like $argv, qr/--network-alias\x{0}relay-001/mx,           'relay one gets a stable network alias';
  like $argv, qr/--network-alias\x{0}relay-002/mx,           'relay two gets a stable network alias';
  like $argv, qr/^network\x{0}rm\x{0}burner-\Q$run_id\E$/mx, 'the run removes the bridge network';
  is scalar(grep {/\Arm\x{0}-f\x{0}burner-\Q$run_id\E-/mx} split /\n/, $argv), 5,
    'the run removes every managed container';
};

subtest 'managed container runs stage guest files with absolute paths when runs-dir is relative' => sub {
  my $relative_log = File::Spec->catfile($tmp, 'relative-engine-argv.log');
  my $scenario     = File::Spec->catfile($tmp, 'managed-relative.yml');
  _spew($scenario, <<'YAML');
environment:
  kind: local-containers
  engine: docker
run:
  name: managed-local-containers-relative
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
  publishers:
    count: 1
workload:
  publish_rate_per_second: 5
YAML

  my $old_cwd = getcwd();
  chdir $tmp or die "chdir $tmp: $!";
  local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $relative_log;
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'relative-runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'relative-runs');

  my $run_id = 'managed-relative-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir relative-runs --run-id $run_id --runner rex-local-workers 2>&1`;
  my $status = $?;
  chdir $old_cwd or die "chdir $old_cwd: $!";

  is $status, 0, 'the managed container run completes with a relative runs-dir' or diag($output);

  my $argv = _slurp($relative_log);
  like $argv, qr/cp\x{0}[^\x{0}]+\x{0}burner-\Q$run_id\E-worker-guest-001:\Q$tmp\E\/relative-runs/mx,
    'worker input files are copied to absolute guest paths';
};

done_testing;

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

sub _write_fake_relay {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'overnet-relay.pl');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();
use Time::HiRes qw(sleep);

my %opt;
while (@ARGV) {
  my $key = shift @ARGV;
  my $value = shift @ARGV;
  $key =~ s/\A--//;
  $opt{$key} = $value;
}

if (my $health = $opt{'health-file'}) {
  open my $fh, '>', $health or die "health: $!";
  print {$fh} JSON::PP->new->canonical(1)->encode({status => 'ready'});
  close $fh or die "close health: $!";
}

$SIG{TERM} = sub { exit 0 };
$SIG{INT}  = sub { exit 0 };
sleep 60 while 1;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _write_fake_overnet_burner {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'overnet-burner');
  _spew($path, _fake_worker_source());
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _write_emulating_engine {
  my ($dir) = @_;

  my $path = File::Spec->catfile($dir, 'emulating-engine');
  _spew($path, <<'PERL');
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

if (my $log = $ENV{OVERNET_BURNER_TEST_ENGINE_LOG}) {
  open my $fh, '>>', $log or die "log: $!";
  print {$fh} join("\0", @ARGV), "\n";
  close $fh or die "close: $!";
}

my $subcommand = shift @ARGV // '';
if ($subcommand eq '--version') {
  print "Docker version 99.0-emulated\n";
  exit 0;
}
if ($subcommand eq 'build') {
  exit 0;
}
if ($subcommand eq 'run') {
  print "emulated-container-id\n";
  exit 0;
}
if ($subcommand eq 'exec') {
  my (undef, undef, undef, $command) = @ARGV;
  if ($command =~ /\bip\s+-o\s+route\b/) {
    print "default via 172.18.0.1 dev eth0\n";
    exit 0;
  }
  exec '/bin/sh', '-c', remap($command) or die "exec: $!";
}
if ($subcommand eq 'cp') {
  my ($src, $dst) = @ARGV;
  $dst =~ s/\A[^:]+://;
  exit 1 if $dst !~ m{\A/}mxs;
  $dst = remap($dst);
  open my $in, '<', $src or die "open $src: $!";
  my $content = do { local $/; <$in> };
  close $in or die "close $src: $!";
  open my $out, '>', $dst or die "open $dst: $!";
  print {$out} remap($content) or die "print $dst: $!";
  close $out or die "close $dst: $!";
  exit 0;
}
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";

  return $path;
}

sub _fake_worker_source {
  return <<'PERL';
#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();

if (@ARGV && $ARGV[0] ne 'worker') {
    die "unsupported fake overnet-burner command: @ARGV\n";
}

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
}

sub _read_json {
  my ($path) = @_;
  return JSON::decode_json(_slurp($path));
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
