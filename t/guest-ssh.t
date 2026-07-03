use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Guest::SSH;

my $tmp = tempdir(CLEANUP => 1);
my ($fake_ssh, $fake_scp, $ssh_log) = _write_fake_ssh_tools($tmp);

local $ENV{OVERNET_BURNER_SSH}      = $fake_ssh;
local $ENV{OVERNET_BURNER_SCP}      = $fake_scp;
local $ENV{OVERNET_BURNER_TEST_SSH} = $ssh_log;

my $guest = Overnet::Burner::Guest::SSH->new(
  name    => 'worker-guest-001',
  role    => 'workers',
  address => 'testhost',
  user    => 'burner',
  port    => 2222,
  key     => '/keys/burner',
);

subtest 'guest identity' => sub {
  is $guest->name,      'worker-guest-001', 'guest records its name';
  is $guest->transport, 'ssh',              'the connect guest uses the ssh transport';
};

subtest 'file operations round trip through the transport' => sub {
  my $dir = File::Spec->catdir($tmp, 'remote', 'deep');
  $guest->make_path($dir);
  ok -d $dir, 'make_path creates directories through ssh';

  my $path = File::Spec->catfile($dir, 'note.txt');
  $guest->write_file($path, "over the wire\n");
  is $guest->read_file($path), "over the wire\n", 'write_file and read_file round trip';

  is $guest->read_file(File::Spec->catfile($dir, 'absent.txt')), undef, 'reading a missing file returns undef';

  my $argv = _slurp($ssh_log);
  like $argv, qr/burner\@testhost/mx,      'commands target user\@address';
  like $argv, qr/-p\x{0}2222/mx,           'ssh commands carry the port';
  like $argv, qr/-i\x{0}\/keys\/burner/mx, 'ssh commands carry the key';
  like $argv, qr/BatchMode=yes/mx,         'ssh commands never prompt';
  like $argv, qr/-P\x{0}2222/mx,           'scp transfers carry the port';
};

subtest 'process lifecycle over ssh' => sub {
  my $stdout = File::Spec->catfile($tmp, 'proc.stdout');
  my $stderr = File::Spec->catfile($tmp, 'proc.stderr');

  my $handle = $guest->launch(
    command => 'printf "%s" "$GUEST_TEST_VALUE"; exit 7',
    env     => {GUEST_TEST_VALUE => 'remote-value'},
    stdout  => $stdout,
    stderr  => $stderr,
  );
  ok $handle, 'launch returns a process handle';

  my $status = _reap_within($guest, $handle, 10);
  ok defined $status, 'the remote process was reaped';
  is $status >> 8,               7,              'the exit status crosses the transport';
  is $guest->read_file($stdout), 'remote-value', 'environment and stdout cross the transport';
};

subtest 'signals reach the remote worker' => sub {
  my $handle = $guest->launch(
    command => 'sleep 60',
    stdout  => File::Spec->catfile($tmp, 'sleeper.stdout'),
    stderr  => File::Spec->catfile($tmp, 'sleeper.stderr'),
  );
  is $guest->try_reap($handle), undef, 'a running remote process is not reaped';

  sleep 0.2;
  $guest->signal($handle, 'TERM');
  my $status = _reap_within($guest, $handle, 10);
  ok defined $status, 'a signaled remote process is reaped';
  isnt $status, 0, 'the termination is visible in the status';
};

subtest 'readiness aggregates in one remote command' => sub {
  my $workers_root = File::Spec->catdir($tmp, 'workers');
  $guest->make_path(File::Spec->catdir($workers_root, 'publisher-001'));
  $guest->make_path(File::Spec->catdir($workers_root, 'subscriber-001'));

  is $guest->ready_actors($workers_root), [], 'no actors are ready before ready files exist';

  $guest->write_file(File::Spec->catfile($workers_root, 'publisher-001',  'ready'), q{});
  $guest->write_file(File::Spec->catfile($workers_root, 'subscriber-001', 'ready'), q{});
  is [sort @{$guest->ready_actors($workers_root)}], ['publisher-001', 'subscriber-001'],
    'the aggregate probe reports every ready actor';

  is $guest->ready_actors(File::Spec->catdir($tmp, 'no-such-root')), [], 'a missing workers root reports nothing ready';
};

subtest 'a real sshd exercises the transport when available' => sub {
  skip_all 'set OVERNET_BURNER_TEST_SSH_HOST to run against a real sshd'
    if !$ENV{OVERNET_BURNER_TEST_SSH_HOST};

  delete local $ENV{OVERNET_BURNER_SSH};
  delete local $ENV{OVERNET_BURNER_SCP};

  my $real = Overnet::Burner::Guest::SSH->new(
    name    => 'real-guest-001',
    role    => 'workers',
    address => $ENV{OVERNET_BURNER_TEST_SSH_HOST},
    $ENV{OVERNET_BURNER_TEST_SSH_USER} ? (user => $ENV{OVERNET_BURNER_TEST_SSH_USER}) : (),
    $ENV{OVERNET_BURNER_TEST_SSH_KEY}  ? (key  => $ENV{OVERNET_BURNER_TEST_SSH_KEY})  : (),
  );

  my $real_tmp = tempdir(CLEANUP => 1);
  my $path     = File::Spec->catfile($real_tmp, 'real-note.txt');
  $real->make_path($real_tmp);
  $real->write_file($path, "really remote\n");
  is $real->read_file($path), "really remote\n", 'file operations work against a real sshd';

  my $handle = $real->launch(
    command => 'printf "%s" "$GUEST_TEST_VALUE"; exit 5',
    env     => {GUEST_TEST_VALUE => 'sshd-value'},
    stdout  => File::Spec->catfile($real_tmp, 'real.stdout'),
    stderr  => File::Spec->catfile($real_tmp, 'real.stderr'),
  );
  my $status = _reap_within($real, $handle, 20);
  ok defined $status, 'a real remote process is reaped';
  is $status >> 8, 5, 'the real exit status crosses sshd';
  is $real->read_file(File::Spec->catfile($real_tmp, 'real.stdout')), 'sshd-value',
    'environment and stdout cross a real sshd';
};

done_testing;

sub _reap_within {
  my ($target_guest, $handle, $limit) = @_;
  my $deadline = time + $limit;
  while (time < $deadline) {
    my $status = $target_guest->try_reap($handle);
    return $status if defined $status;
    sleep 0.1;
  }
  return undef;
}

sub _write_fake_ssh_tools {
  my ($dir) = @_;

  my $log = File::Spec->catfile($dir, 'ssh-argv.log');

  my $ssh = File::Spec->catfile($dir, 'fake-ssh');
  _spew($ssh, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
if (my $log = $ENV{OVERNET_BURNER_TEST_SSH}) {
  open my $fh, '>>', $log or die "log: $!";
  print {$fh} join("\0", @ARGV), "\n";
  close $fh or die "close: $!";
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
exec '/bin/sh', '-c', $command or die "exec: $!";
PERL
  chmod 0755, $ssh or die "chmod: $!";

  my $scp = File::Spec->catfile($dir, 'fake-scp');
  _spew($scp, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
use File::Copy qw(copy);
if (my $log = $ENV{OVERNET_BURNER_TEST_SSH}) {
  open my $fh, '>>', $log or die "log: $!";
  print {$fh} join("\0", 'scp', @ARGV), "\n";
  close $fh or die "close: $!";
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
copy($src, $dst) or die "copy $src -> $dst: $!";
PERL
  chmod 0755, $scp or die "chmod: $!";

  return ($ssh, $scp, $log);
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
