use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::ContainerEngine;

my $tmp = tempdir(CLEANUP => 1);
my $log = File::Spec->catfile($tmp, 'engine-argv.log');
local $ENV{OVERNET_BURNER_TEST_ENGINE_LOG} = $log;

my $fake_docker        = _write_fake_engine($tmp, 'fake-docker',        'Docker version 99.0-fake, build feedbeef');
my $fake_podman        = _write_fake_engine($tmp, 'fake-podman',        'podman version 99.0-fake');
my $fake_docker_podman = _write_fake_engine($tmp, 'fake-docker-podman', 'podman version 4.9-fake');

subtest 'auto prefers Docker when both engines answer' => sub {
  local $ENV{OVERNET_BURNER_DOCKER} = $fake_docker;
  local $ENV{OVERNET_BURNER_PODMAN} = $fake_podman;

  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'auto');
  is $engine->name, 'docker', 'auto picks Docker first';
  like $engine->version, qr/99\.0-fake/mx, 'the engine version is recorded';
};

subtest 'auto falls back to podman when Docker is unavailable' => sub {
  local $ENV{OVERNET_BURNER_DOCKER} = File::Spec->catfile($tmp, 'no-such-binary');
  local $ENV{OVERNET_BURNER_PODMAN} = $fake_podman;

  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'auto');
  is $engine->name, 'podman', 'auto falls back to podman';
};

subtest 'a docker alias that is really podman is recorded as podman' => sub {
  local $ENV{OVERNET_BURNER_DOCKER} = $fake_docker_podman;
  local $ENV{OVERNET_BURNER_PODMAN} = File::Spec->catfile($tmp, 'no-such-binary');

  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'docker');
  is $engine->name, 'podman', 'the real engine identity is recorded, never assumed';
};

subtest 'no engine available is a clean failure' => sub {
  local $ENV{OVERNET_BURNER_DOCKER} = File::Spec->catfile($tmp, 'no-such-binary');
  local $ENV{OVERNET_BURNER_PODMAN} = File::Spec->catfile($tmp, 'no-such-binary');

  my $error;
  eval { Overnet::Burner::ContainerEngine->detect(engine => 'auto'); 1 } or $error = $@;
  like $error, qr/no\ container\ engine/mx, 'detection failure names the problem';
};

subtest 'operations use the shared CLI surface' => sub {
  local $ENV{OVERNET_BURNER_DOCKER} = $fake_docker;
  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'docker');

  my $id = $engine->run_detached(
    name    => 'burner-test-guest-001',
    image   => 'example.test/worker:latest',
    network => 'host',
    command => ['sleep', 'infinity'],
  );
  is $id, 'fake-container-id', 'run_detached returns the container id';

  my ($output, $status) = $engine->exec_capture('burner-test-guest-001', 'echo hi');
  is $status, 0, 'exec_capture reports success';

  $engine->copy_to('burner-test-guest-001', "$tmp/engine-argv.log", '/tmp/dest');
  $engine->remove('burner-test-guest-001');
  $engine->network_create('burner-net-001');
  $engine->network_disconnect('burner-net-001', 'burner-test-guest-001');
  $engine->network_connect('burner-net-001', 'burner-test-guest-001');
  $engine->network_remove('burner-net-001');

  my $capped = $engine->run_detached(
    name    => 'burner-test-guest-002',
    image   => 'example.test/worker:latest',
    network => 'burner-net-001',
    cap_add => ['NET_ADMIN'],
    command => ['sleep', 'infinity'],
  );
  is $capped, 'fake-container-id', 'run_detached accepts capability grants';

  my $aliased = $engine->run_detached(
    name            => 'burner-test-relay-001',
    image           => 'example.test/reference:latest',
    network         => 'burner-net-001',
    network_aliases => ['relay-001'],
    command         => ['sleep', 'infinity'],
  );
  is $aliased, 'fake-container-id', 'run_detached accepts network aliases';

  $engine->build_image(tag => 'example.test/reference:latest', context => $tmp);

  my $argv = _slurp($log);
  like $argv, qr/run\x{0}-d\x{0}--name\x{0}burner-test-guest-001\x{0}--network\x{0}host\x{0}
                 example\.test\/worker:latest\x{0}sleep\x{0}infinity/mx, 'run_detached builds the shared run command';
  like $argv, qr/exec\x{0}burner-test-guest-001\x{0}\/bin\/sh\x{0}-c\x{0}echo\ hi/mx, 'exec_capture runs through sh -c';
  like $argv, qr/cp\x{0}[^\x{0}]+\x{0}burner-test-guest-001:\/tmp\/dest/mx,           'copy_to uses engine cp';
  like $argv, qr/rm\x{0}-f\x{0}burner-test-guest-001/mx,                              'remove forces removal';
  like $argv, qr/network\x{0}create\x{0}burner-net-001/mx,                            'network_create is available';
  like $argv, qr/network\x{0}disconnect\x{0}burner-net-001\x{0}burner-test-guest-001/mx,
    'network_disconnect cuts one container from a network';
  like $argv, qr/network\x{0}connect\x{0}burner-net-001\x{0}burner-test-guest-001/mx,
    'network_connect reattaches one container to a network';
  like $argv, qr/network\x{0}rm\x{0}burner-net-001/mx, 'network_remove is available';
  like $argv, qr/run\x{0}-d\x{0}--name\x{0}burner-test-guest-002\x{0}--network\x{0}burner-net-001\x{0}
                 --cap-add\x{0}NET_ADMIN\x{0}example\.test\/worker:latest/mx,
    'run_detached grants requested capabilities through --cap-add';
  like $argv, qr/run\x{0}-d\x{0}--name\x{0}burner-test-relay-001\x{0}--network\x{0}burner-net-001\x{0}
                 --network-alias\x{0}relay-001\x{0}example\.test\/reference:latest/mx,
    'run_detached attaches stable network aliases';
  like $argv, qr/build\x{0}-t\x{0}example\.test\/reference:latest\x{0}\Q$tmp\E/mx,
    'build_image builds the requested context with the requested tag';
};

subtest 'an engine whose version is neither docker nor podman is not usable' => sub {
  my $unknown = _write_fake_engine($tmp, 'fake-unknown', 'containerd version 1.0');
  local $ENV{OVERNET_BURNER_DOCKER} = $unknown;
  local $ENV{OVERNET_BURNER_PODMAN} = File::Spec->catfile($tmp, 'no-such-binary');
  like dies { Overnet::Burner::ContainerEngine->detect(engine => 'auto') }, qr/no\ container\ engine/mx,
    'an unidentifiable engine is rejected';
};

subtest 'failing engine commands surface as errors' => sub {
  my $failing = _write_failing_engine($tmp, 'fake-failing');
  local $ENV{OVERNET_BURNER_DOCKER} = $failing;
  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'docker');

  like dies { $engine->run_detached(name => 'g', image => 'img') }, qr/could\ not\ start\ container/mx,
    'a failed run_detached (no network, no command) croaks';
  like dies { $engine->build_image(tag => 't', context => $tmp) }, qr/could\ not\ build\ image/mx,
    'a failed build croaks';
  like dies { $engine->copy_to('g', "$tmp/engine-argv.log", '/tmp/dest') }, qr/could\ not\ copy/mx,
    'a failed copy croaks';
  like dies { $engine->network_create('net') }, qr/could\ not\ create\ network/mx, 'a failed network create croaks';
  like dies { $engine->network_disconnect('net', 'g') }, qr/could\ not\ disconnect/mx, 'a failed disconnect croaks';
  like dies { $engine->network_connect('net', 'g') }, qr/could\ not\ connect/mx, 'a failed connect croaks';

  is $engine->remove('g'),           0, 'remove reports failure without dying';
  is $engine->network_remove('net'), 0, 'network_remove reports failure without dying';
};

done_testing;

sub _write_failing_engine {
  my ($dir, $basename) = @_;
  my $path = File::Spec->catfile($dir, $basename);
  _spew($path, <<'PERL');
#!/usr/bin/env perl
use strict;
use warnings;
if (@ARGV && $ARGV[0] eq '--version') {
  print "Docker version 99.0-fake\n";
  exit 0;
}
exit 1;
PERL
  chmod 0755, $path or die "chmod: $!";
  return $path;
}

sub _write_fake_engine {
  my ($dir, $basename, $version_line) = @_;

  my $path = File::Spec->catfile($dir, $basename);
  _spew($path, <<"PERL");
#!/usr/bin/env perl
use strict;
use warnings;
if (my \$log = \$ENV{OVERNET_BURNER_TEST_ENGINE_LOG}) {
  open my \$fh, '>>', \$log or die "log: \$!";
  print {\$fh} join("\\0", \@ARGV), "\\n";
  close \$fh or die "close: \$!";
}
if (\@ARGV && \$ARGV[0] eq '--version') {
  print "$version_line\\n";
  exit 0;
}
if (\@ARGV && \$ARGV[0] eq 'run') {
  print "fake-container-id\\n";
  exit 0;
}
if (\@ARGV && \$ARGV[0] eq 'exec') {
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
