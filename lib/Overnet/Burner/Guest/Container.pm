package Overnet::Burner::Guest::Container;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest::Remote';

our $VERSION = '0.001';

has engine    => (is => 'ro', required => 1);
has container => (is => 'ro', required => 1);
has image     => (is => 'ro');
has cap_add   => (is => 'ro', default => sub { [] });
has alias     => (is => 'ro');

no Moo;

sub transport {
  return 'container';
}

sub destroy {
  my ($self) = @_;

  if ($self->{destroyed}) {
    return 1;
  }
  $self->{destroyed} = 1;

  return $self->engine->remove($self->container);
}

sub _capture {
  my ($self, $command) = @_;

  return $self->engine->exec_capture($self->container, $command);
}

sub _push_file {
  my ($self, $local_path, $remote_path) = @_;

  $self->engine->copy_to($self->container, $local_path, $remote_path);

  return 1;
}

1;

=head1 NAME

Overnet::Burner::Guest::Container - the container guest transport

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $engine = Overnet::Burner::ContainerEngine->detect(engine => 'auto');
  my $id     = $engine->run_detached(
    name    => 'burner-run-worker-guest-001',
    image   => 'worker:latest',
    network => 'host',
    command => ['sleep', 'infinity'],
  );
  my $guest = Overnet::Burner::Guest::Container->new(
    name      => 'worker-guest-001',
    role      => 'workers',
    engine    => $engine,
    container => 'burner-run-worker-guest-001',
  );

=head1 DESCRIPTION

Implements the two remote transport primitives of
L<Overnet::Burner::Guest::Remote> against a running container through
L<Overnet::Burner::ContainerEngine>: commands run through the engine's
C<exec>, and files move through the engine's C<cp>. One worker runs per
container per the decided design in F<docs/provisioning.md>. C<destroy>
force-removes the container exactly once; the runner calls it after
collection and on failure cleanup so guests never outlive their run.

=head1 SUBROUTINES/METHODS

=head2 new

=head2 engine

=head2 container

=head2 image

=head2 cap_add

The Linux capabilities the container was granted at creation (for example
C<NET_ADMIN> for netem chaos actions), recorded so the guest ledger never
understates the privilege a guest ran with.

=head2 alias

Stable network alias assigned on the run bridge network, when one is needed.

=head2 transport

=head2 destroy

=head1 DIAGNOSTICS

Transport failures are reported through exceptions naming the guest.

=head1 CONFIGURATION AND ENVIRONMENT

None beyond the engine adapter's environment.

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
