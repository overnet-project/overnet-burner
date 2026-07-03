package Overnet::Burner::ContainerEngine;

use strictures 2;
use Moo;

use Carp    qw(croak);
use English qw(-no_match_vars);

our $VERSION = '0.001';

has name    => (is => 'ro', required => 1);
has binary  => (is => 'ro', required => 1);
has version => (is => 'ro', required => 1);

no Moo;

sub detect {
  my ($class, %args) = @_;

  my $requested = $args{engine} || 'auto';
  my %binary    = (
    docker => $ENV{OVERNET_BURNER_DOCKER} || 'docker',
    podman => $ENV{OVERNET_BURNER_PODMAN} || 'podman',
  );

  my @candidates = $requested eq 'auto' ? qw(docker podman) : ($requested);
  for my $candidate (@candidates) {
    my $engine = $class->_probe($binary{$candidate});
    if ($engine) {
      return $engine;
    }
  }

  croak "no container engine available (tried: @candidates)\n";
}

sub _probe {
  my ($class, $binary) = @_;

  my ($output, $status) = _capture_argv($binary, '--version');
  if ($status != 0 || !defined $output || !length $output) {
    return;
  }
  chomp $output;

  my $identity =
      $output =~ /podman/imxs ? 'podman'
    : $output =~ /docker/imxs ? 'docker'
    :                           undef;
  if (!$identity) {
    return;
  }

  return $class->new(name => $identity, binary => $binary, version => $output);
}

sub run_detached {
  my ($self, %args) = @_;

  my $name    = $args{name}  || croak "container name is required\n";
  my $image   = $args{image} || croak "image is required\n";
  my @command = ref $args{command} eq 'ARRAY' ? @{$args{command}} : ();
  my @cap_add = ref $args{cap_add} eq 'ARRAY' ? @{$args{cap_add}} : ();

  my ($output, $status) = _capture_argv(
    $self->binary, 'run', '-d', '--name', $name,
    defined $args{network} ? ('--network', $args{network}) : (),
    (map { ('--cap-add', $_) } @cap_add),
    $image, @command,
  );
  if ($status != 0 || !defined $output || !length $output) {
    croak $self->name . " could not start container $name from $image\n";
  }
  chomp $output;
  my ($id) = split /\n/mxs, $output;

  return $id;
}

sub exec_capture {
  my ($self, $container, $command) = @_;

  return _capture_argv($self->binary, 'exec', $container, '/bin/sh', '-c', $command);
}

sub copy_to {
  my ($self, $container, $local_path, $remote_path) = @_;

  my (undef, $status) = _capture_argv($self->binary, 'cp', $local_path, "$container:$remote_path");
  if ($status != 0) {
    croak $self->name . " could not copy into $container:$remote_path\n";
  }

  return 1;
}

sub remove {
  my ($self, $container) = @_;

  my (undef, $status) = _capture_argv($self->binary, 'rm', '-f', $container);

  return $status == 0 ? 1 : 0;
}

sub network_create {
  my ($self, $name) = @_;

  my (undef, $status) = _capture_argv($self->binary, 'network', 'create', $name);
  if ($status != 0) {
    croak $self->name . " could not create network $name\n";
  }

  return 1;
}

sub network_remove {
  my ($self, $name) = @_;

  my (undef, $status) = _capture_argv($self->binary, 'network', 'rm', $name);

  return $status == 0 ? 1 : 0;
}

sub network_disconnect {
  my ($self, $network, $container) = @_;

  my (undef, $status) = _capture_argv($self->binary, 'network', 'disconnect', $network, $container);
  if ($status != 0) {
    croak $self->name . " could not disconnect $container from $network\n";
  }

  return 1;
}

sub network_connect {
  my ($self, $network, $container) = @_;

  my (undef, $status) = _capture_argv($self->binary, 'network', 'connect', $network, $container);
  if ($status != 0) {
    croak $self->name . " could not connect $container to $network\n";
  }

  return 1;
}

sub _capture_argv {
  my (@argv) = @_;

  my $pid = open my $fh, q{-|};
  if (!defined $pid) {
    croak "fork engine command: $OS_ERROR\n";
  }
  if ($pid == 0) {
    open STDERR, '>', '/dev/null' or exit 127;
    exec {$argv[0]} @argv or exit 127;
  }
  local $INPUT_RECORD_SEPARATOR = undef;
  my $output = <$fh>;
  my $status = close $fh ? 0 : ($CHILD_ERROR || -1);

  return ($output, $status);
}

1;

=head1 NAME

Overnet::Burner::ContainerEngine - one adapter over Docker and podman

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'auto');
  my $id     = $engine->run_detached(name => 'g1', image => 'worker:latest',
    network => 'host', command => ['sleep', 'infinity']);

=head1 DESCRIPTION

The container provisioning method supports both Docker and podman behind
this one adapter, per the decided design in F<docs/provisioning.md>: only
the CLI surface the two engines share is used (run, exec, cp, rm, network
create and rm), C<detect> with C<auto> prefers Docker and falls back to
podman, and the probed engine's real identity is recorded - a C<docker>
alias that actually invokes podman is detected by its version string and
recorded as podman, never assumed. The C<OVERNET_BURNER_DOCKER> and
C<OVERNET_BURNER_PODMAN> environment variables override the binaries so
the test suite can drive the adapter through local fakes and gated tests
can pin a specific real engine.

=head1 SUBROUTINES/METHODS

=head2 detect

=head2 new

=head2 name

=head2 binary

=head2 version

=head2 run_detached

=head2 exec_capture

=head2 copy_to

=head2 remove

=head2 network_create

=head2 network_remove

=head2 network_disconnect

=head2 network_connect

=head1 DIAGNOSTICS

Engine command failures are reported through exceptions naming the engine;
C<remove> and C<network_remove> are best-effort teardown and return false
instead of dying.

=head1 CONFIGURATION AND ENVIRONMENT

C<OVERNET_BURNER_DOCKER> and C<OVERNET_BURNER_PODMAN> override the engine
binaries.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
