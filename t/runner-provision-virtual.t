use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON         ();
use MIME::Base64 ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo = "$FindBin::Bin/..";
my $bin  = "$repo/bin/overnet-burner";

my $tmp = tempdir(CLEANUP => 1);
my ($fake_ssh, $fake_scp) = _write_fake_ssh_tools($tmp);
my $fake_worker = _write_fake_worker($tmp);
my $fake_rex    = _write_fake_rex($tmp);
my $fake_image  = File::Spec->catfile($tmp, 'fake-image.qcow2');
_spew($fake_image, "not a real image\n");

local $ENV{OVERNET_BURNER_SSH}           = $fake_ssh;
local $ENV{OVERNET_BURNER_SCP}           = $fake_scp;
local $ENV{OVERNET_BURNER_WORKER}        = "$^X $fake_worker";
local $ENV{OVERNET_BURNER_REX}           = $fake_rex;
local $ENV{OVERNET_BURNER_TEST_REX_LOG}  = File::Spec->catfile($tmp, 'fake-rex.log');
local $ENV{OVERNET_BURNER_QEMU}          = _write_fake_qemu($tmp);
local $ENV{OVERNET_BURNER_GENISOIMAGE}   = _write_fake_genisoimage($tmp);
local $ENV{OVERNET_BURNER_SSH_KEYGEN}    = _write_fake_ssh_keygen($tmp);
local $ENV{OVERNET_BURNER_QEMU_ACCEL}    = 'tcg';
local $ENV{OVERNET_BURNER_TEST_QEMU_LOG} = File::Spec->catfile($tmp, 'fake-qemu.log');

my $scenario = "$tmp/virtual.yml";
_spew($scenario, <<'YAML');
run:
  name: virtual-provision
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://10.0.2.2:59999
  publishers:
    count: 2
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
provision:
  workers:
    how: virtual
    image: __IMAGE__
    count: 2
    hardware:
      memory: ">= 2 GiB"
      cpu:
        cores: ">= 2"
YAML
_rewrite($scenario, '__IMAGE__', $fake_image);

subtest 'virtual-provisioned workers boot VMs and run over ssh' => sub {
  local $ENV{OVERNET_BURNER_TEST_REMAP_FROM} = File::Spec->catdir($tmp, 'runs');
  local $ENV{OVERNET_BURNER_TEST_REMAP_TO}   = File::Spec->catdir($tmp, 'guest-fs', 'runs');

  my $run_id = 'virtual-run-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  is $?, 0, 'the run completes on virtual guests' or diag($output);

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);

  my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is [map { $_->{transport} } @{$guests->{guests}}], ['ssh',     'ssh'],     'virtual guests speak the ssh transport';
  is [map { $_->{method} } @{$guests->{guests}}],    ['virtual', 'virtual'], 'the ledger records how guests were built';
  is [map { $_->{accel} } @{$guests->{guests}}],     ['tcg',     'tcg'],    'the accelerator actually used is recorded';
  is [map { $_->{memory_mb} } @{$guests->{guests}}], [2048,      2048],     'memory honors the hardware requirement';
  is [map { $_->{cpus} } @{$guests->{guests}}],      [2,         2],        'cores honor the hardware requirement';
  is [map { $_->{user} } @{$guests->{guests}}],      ['burner',  'burner'], 'guests are reached as the burner user';
  is $guests->{hardware_requirements}, {memory => '>= 2 GiB', cpu => {cores => '>= 2'}},
    'the declared requirement is recorded verbatim';
  is $guests->{placement},
    {
    'publisher-001'  => 'worker-guest-001',
    'publisher-002'  => 'worker-guest-002',
    'subscriber-001' => 'worker-guest-001',
    },
    'actors are placed round-robin across virtual guests';

  my @launches = grep {/-daemonize/} split /\n/, _slurp($ENV{OVERNET_BURNER_TEST_QEMU_LOG});
  is scalar @launches, 2, 'one VM boots per guest';
  like $launches[0], qr/-m\x{0}2048M/mx,   'qemu gets the constructed memory';
  like $launches[0], qr/-smp\x{0}2/mx,     'qemu gets the constructed cores';
  like $launches[0], qr/-accel\x{0}tcg/mx, 'qemu uses the recorded accelerator';
  like $launches[0], qr/-snapshot/mx,      'disks are ephemeral';
  like $launches[0], qr/format=qcow2/mx,   'the image format follows the file extension';
  like $launches[0], qr/-drive\x{0}file=[^\x{0}]*seed\.iso,format=raw,if=virtio,readonly=on/mx,
    'the cloud-init seed rides a virtio disk so cloud kernels can see it';
  like $launches[0], qr/-serial\x{0}file:[^\x{0}]*console\.log/mx, 'the guest console is captured as run evidence';
  my @ports;

  for my $launch (@launches) {
    my ($port) = $launch =~ /hostfwd=tcp:127\.0\.0\.1:([0-9]+)-:22/mx;
    push @ports, $port;
  }
  is scalar(grep {defined} @ports), 2,         'each VM forwards ssh on a host port';
  isnt $ports[0],                   $ports[1], 'the forwarded ports are distinct';

  my $user_data = _slurp(File::Spec->catfile($run_dir, 'virtual', 'worker-guest-001', 'user-data'));
  like $user_data, qr/name:\ burner/mx,       'cloud-init creates the burner user';
  like $user_data, qr/ssh_authorized_keys/mx, 'cloud-init injects the per-run key';

  my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
  is scalar @{$aggregated}, 3, 'every stream was pulled from its VM and aggregated';

  for my $guest_name (qw(worker-guest-001 worker-guest-002)) {
    my $pid = _slurp(File::Spec->catfile($run_dir, 'virtual', $guest_name, 'qemu.pid'));
    chomp $pid;
    is kill(0, $pid), 0, "the $guest_name VM process is gone after the run";
  }
};

subtest 'a VM that fails to launch fails the run cleanly' => sub {
  local $ENV{OVERNET_BURNER_TEST_QEMU_FAIL} = 1;

  my $run_id = 'virtual-run-fail-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'the run fails when qemu cannot launch';

  my $manifest = _read_json(File::Spec->catfile($tmp, 'runs', $run_id, 'manifest.json'));
  is $manifest->{status}, 'failed', 'manifest records the failure';
};

subtest 'a VM that never becomes reachable fails the run and is destroyed' => sub {
  local $ENV{OVERNET_BURNER_TEST_SSH_DOWN}        = 1;
  local $ENV{OVERNET_BURNER_VIRTUAL_BOOT_TIMEOUT} = 1;

  my $run_id = 'virtual-run-unreachable-001';
  my $output =
    `$^X $bin run --scenario $scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  isnt $?, 0, 'the run fails when ssh never comes up';
  like $output, qr/did\ not\ become\ reachable/mx, 'the failure names the boot timeout';

  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
  for my $guest_name (qw(worker-guest-001 worker-guest-002)) {
    my $pid = _slurp(File::Spec->catfile($run_dir, 'virtual', $guest_name, 'qemu.pid'));
    chomp $pid;
    is kill(0, $pid), 0, "failure cleanup destroys the $guest_name VM";
  }
};

subtest 'a real cloud image boots and runs the whole virtual path' => sub {
  my $image = $ENV{OVERNET_BURNER_TEST_VIRTUAL_IMAGE};
  skip_all 'set OVERNET_BURNER_TEST_VIRTUAL_IMAGE to a cloud image to run against real qemu' if !$image;

  delete local @ENV{
    qw(
      OVERNET_BURNER_SSH OVERNET_BURNER_SCP OVERNET_BURNER_WORKER
      OVERNET_BURNER_QEMU OVERNET_BURNER_GENISOIMAGE OVERNET_BURNER_SSH_KEYGEN
      OVERNET_BURNER_QEMU_ACCEL OVERNET_BURNER_TEST_QEMU_LOG
    )
  };

  my $python = MIME::Base64::encode_base64(<<'PYTHON', q{});
import json, os
with open(os.environ['OVERNET_BURNER_WORKER_INPUT']) as fh:
    inp = json.load(fh)
open(os.path.join(inp['run_dir'], inp['ready_file']), 'w').close()
metric = {
    'metric_version': 1, 'run_id': inp['run_id'], 'worker_id': inp['worker_id'],
    'host': 'vm', 'role': inp['role'], 'operation': 'noop_probe',
    'started_at': '2026-07-03T18:00:00Z', 'finished_at': '2026-07-03T18:00:00.001Z',
    'duration_ms': 1, 'status': 'success',
}
with open(os.path.join(inp['run_dir'], inp['metric_stream']), 'a') as fh:
    fh.write(json.dumps(metric, sort_keys=True) + '\n')
PYTHON

  my $real_scenario = "$tmp/virtual-real.yml";
  _spew($real_scenario, <<"YAML");
run:
  name: virtual-real
  duration: 2
  seed: 12345
topology:
  relays:
    count: 1
    provider: generic-relay
    endpoints:
      - ws://10.0.2.2:59999
  publishers:
    count: 1
  subscribers:
    count: 1
workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
provision:
  workers:
    how: virtual
    image: $image
    count: 1
    worker: "python3 -c \\"import base64;exec(base64.b64decode('$python'))\\""
YAML

  my $run_id = 'virtual-real-001';
  my $output =
    `$^X $bin run --scenario $real_scenario --runs-dir $tmp/runs --run-id $run_id --runner rex-local-workers 2>&1`;
  my $status  = $?;
  my $run_dir = File::Spec->catdir($tmp, 'runs', $run_id);
  is $status, 0, 'the run completes on a real VM' or diag($output);
  my $console = File::Spec->catfile($run_dir, 'virtual', 'worker-guest-001', 'console.log');
  if ($status != 0 && -e $console) {
    my $tail = _slurp($console);
    if (length($tail) > 4000) {
      $tail = substr $tail, -4000;
    }
    diag("guest console tail: $tail");
  }

  my $guests = _read_json(File::Spec->catfile($run_dir, 'guests.json'));
  is $guests->{guests}[0]{method}, 'virtual', 'the ledger records the virtual method';
  ok $guests->{guests}[0]{accel}, 'the accelerator used is recorded';

  my $aggregated = Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics.jsonl'));
  is scalar @{$aggregated}, 2, 'every stream came back from the real VM';

  # real qemu unlinks its pid file when it exits, so a missing pid file is
  # itself proof the VM is down
  my $pid_path = File::Spec->catfile($run_dir, 'virtual', 'worker-guest-001', 'qemu.pid');
  if (-e $pid_path) {
    my $pid = _slurp($pid_path);
    chomp $pid;
    is kill(0, $pid), 0, 'the real VM does not outlive the run';
  } else {
    pass 'the real VM does not outlive the run (qemu removed its pid file on exit)';
  }
};

done_testing;

sub _write_fake_qemu {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-qemu');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
if (my $log = $ENV{OVERNET_BURNER_TEST_QEMU_LOG}) {
  open my $fh, '>>', $log or die "log: $!";
  print {$fh} join("\0", @ARGV), "\n";
  close $fh or die "close: $!";
}
exit 1 if $ENV{OVERNET_BURNER_TEST_QEMU_FAIL};
my $pid_file;
for my $index (0 .. $#ARGV - 1) {
  $pid_file = $ARGV[$index + 1] if $ARGV[$index] eq '-pidfile';
}
die "no -pidfile\n" if !$pid_file;
my $child = fork;
die "fork: $!" if !defined $child;
if (!$child) {
  # emulate the daemonized VM process; drop inherited stdio so the
  # controller's captured output is not held open
  open STDIN,  '<', '/dev/null' or die "stdin: $!";
  open STDOUT, '>', '/dev/null' or die "stdout: $!";
  open STDERR, '>', '/dev/null' or die "stderr: $!";
  for (1 .. 600) { sleep 1; }
  exit 0;
}
open my $fh, '>', $pid_file or die "pidfile: $!";
print {$fh} "$child\n";
close $fh or die "close pidfile: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _write_fake_genisoimage {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-genisoimage');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
my $output;
for my $index (0 .. $#ARGV - 1) {
  $output = $ARGV[$index + 1] if $ARGV[$index] eq '-output';
}
die "no -output\n" if !$output;
open my $fh, '>', $output or die "output: $!";
print {$fh} "fake iso\n";
close $fh or die "close: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _write_fake_ssh_keygen {
  my ($dir) = @_;
  my $path = File::Spec->catfile($dir, 'fake-ssh-keygen');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
my $key;
for my $index (0 .. $#ARGV - 1) {
  $key = $ARGV[$index + 1] if $ARGV[$index] eq '-f';
}
die "no -f\n" if !$key;
open my $fh, '>', $key or die "key: $!";
print {$fh} "fake private key\n";
close $fh or die "close: $!";
open my $pub, '>', "$key.pub" or die "pub: $!";
print {$pub} "ssh-ed25519 AAAAFAKEKEY burner\n";
close $pub or die "close pub: $!";
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
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

exit 1 if $ENV{OVERNET_BURNER_TEST_SSH_DOWN};

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
use strict;
use warnings;
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
    host           => 'fake-vm',
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
  return JSON::decode_json(_slurp($path));
}

sub _rewrite {
  my ($path, $from, $to) = @_;
  my $content = _slurp($path);
  $content =~ s/\Q$from\E/$to/gmxs;
  _spew($path, $content);
  return;
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
