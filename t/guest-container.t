use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::ContainerEngine;
use Overnet::Burner::Guest::Container;

my $tmp = tempdir(CLEANUP => 1);
my $log = File::Spec->catfile($tmp, 'engine-argv.log');
local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $log;
local $ENV{OVERNET_BURNER_DOCKER}          = _write_emulating_engine($tmp);

my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'docker');
my $guest  = Overnet::Burner::Guest::Container->new(
  name      => 'worker-guest-001',
  role      => 'workers',
  engine    => $engine,
  container => 'burner-test-worker-guest-001',
);

subtest 'guest identity' => sub {
  is $guest->transport, 'container',                    'the container guest uses the container transport';
  is $guest->container, 'burner-test-worker-guest-001', 'the guest knows its container';
};

subtest 'file operations round trip through the engine' => sub {
  my $dir = File::Spec->catdir($tmp, 'inside', 'deep');
  $guest->make_path($dir);
  ok -d $dir, 'make_path creates directories through engine exec';

  my $path = File::Spec->catfile($dir, 'note.txt');
  $guest->write_file($path, "into the container\n");
  is $guest->read_file($path), "into the container\n", 'write_file and read_file round trip';

  is $guest->read_file(File::Spec->catfile($dir, 'absent.txt')), undef, 'reading a missing file returns undef';
};

subtest 'process lifecycle through engine exec' => sub {
  my $stdout = File::Spec->catfile($tmp, 'proc.stdout');
  my $handle = $guest->launch(
    command => 'printf "%s" "$GUEST_TEST_VALUE"; exit 7',
    env     => {GUEST_TEST_VALUE => 'container-value'},
    stdout  => $stdout,
    stderr  => File::Spec->catfile($tmp, 'proc.stderr'),
  );

  my $deadline = time + 10;
  my $status;
  while (time < $deadline) {
    $status = $guest->try_reap($handle);
    last if defined $status;
    sleep 0.1;
  }
  ok defined $status, 'the containerized process was reaped';
  is $status >> 8,               7,                 'the exit status crosses the engine';
  is $guest->read_file($stdout), 'container-value', 'environment and stdout cross the engine';
};

subtest 'readiness aggregates through one exec' => sub {
  my $workers_root = File::Spec->catdir($tmp, 'workers');
  $guest->make_path(File::Spec->catdir($workers_root, 'publisher-001'));
  $guest->write_file(File::Spec->catfile($workers_root, 'publisher-001', 'ready'), q{});
  is $guest->ready_actors($workers_root), ['publisher-001'], 'the aggregate probe works through exec';
};

subtest 'destroy removes the container exactly once' => sub {
  ok $guest->destroy, 'destroy removes the container';
  ok $guest->destroy, 'a second destroy is a quiet no-op';

  my $argv    = _slurp($log);
  my @removes = grep {/rm\x{0}-f\x{0}burner-test-worker-guest-001/mx} split /\n/, $argv;
  is scalar @removes, 1, 'the engine saw exactly one removal';
};

done_testing;

sub _write_emulating_engine {
  my ($dir) = @_;

  my $path = File::Spec->catfile($dir, 'emulating-engine');
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
use File::Copy qw(copy);

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
if ($subcommand eq 'run') {
  print "emulated-container-id\n";
  exit 0;
}
if ($subcommand eq 'exec') {
  my (undef, undef, undef, $command) = @ARGV;
  exec '/bin/sh', '-c', $command or die "exec: $!";
}
if ($subcommand eq 'cp') {
  my ($src, $dst) = @ARGV;
  $dst =~ s/\A[^:]+://;
  copy($src, $dst) or die "copy $src -> $dst: $!";
  exit 0;
}
exit 0;
PERL
  chmod 0755, $path or die "chmod: $!";

  return $path;
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
