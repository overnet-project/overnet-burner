package Overnet::Burner::Guest::SSH;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest::Remote';

use Carp    qw(croak);
use English qw(-no_match_vars);

our $VERSION = '0.001';

has address => (is => 'ro', required => 1);
has user    => (is => 'ro');
has port    => (is => 'ro');
has key     => (is => 'ro');

no Moo;

sub transport {
  return 'ssh';
}

sub _capture {
  my ($self, $command) = @_;

  open my $fh, q{-|}, $self->_ssh_binary, $self->_ssh_options, $self->_target, $command
    or croak 'guest ' . $self->name . " could not run ssh: $OS_ERROR\n";
  local $INPUT_RECORD_SEPARATOR = undef;
  my $output = <$fh>;
  my $status = close $fh ? 0 : ($CHILD_ERROR || -1);

  return ($output, $status);
}

sub _push_file {
  my ($self, $local_path, $remote_path) = @_;

  my $status = system $self->_scp_binary, $self->_scp_options, $local_path, $self->_target . ":$remote_path";
  if ($status != 0) {
    croak 'guest ' . $self->name . " could not write $remote_path\n";
  }

  return 1;
}

sub _target {
  my ($self) = @_;

  return defined $self->user ? $self->user . q{@} . $self->address : $self->address;
}

sub _ssh_binary {
  my ($self) = @_;

  return $ENV{OVERNET_BURNER_SSH} || 'ssh';
}

sub _scp_binary {
  my ($self) = @_;

  return $ENV{OVERNET_BURNER_SCP} || 'scp';
}

sub _ssh_options {
  my ($self) = @_;

  return (
    qw(-o BatchMode=yes -o StrictHostKeyChecking=accept-new),
    defined $self->port ? (q{-p}, $self->port) : (),
    defined $self->key  ? (q{-i}, $self->key)  : (),
  );
}

sub _scp_options {
  my ($self) = @_;

  return (
    qw(-o BatchMode=yes -o StrictHostKeyChecking=accept-new),
    defined $self->port ? (q{-P}, $self->port) : (),
    defined $self->key  ? (q{-i}, $self->key)  : (),
  );
}

1;

=head1 NAME

Overnet::Burner::Guest::SSH - the connect guest transport

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $guest = Overnet::Burner::Guest::SSH->new(
    name    => 'worker-guest-001',
    role    => 'workers',
    address => 'load-1.example.net',
    user    => 'burner',
    key     => '/keys/burner',
  );

=head1 DESCRIPTION

Implements the two remote transport primitives of
L<Overnet::Burner::Guest::Remote> over OpenSSH for the C<how: connect>
provisioning method of F<docs/provisioning.md>: commands run through
C<ssh> in batch mode, and files move over C<scp>. All process supervision
comes from the shared remote guest base.

The C<OVERNET_BURNER_SSH> and C<OVERNET_BURNER_SCP> environment variables
override the client binaries, which lets the test suite drive the exact
same command construction through local fakes; a real sshd exercises the
transport when the gated test environment provides one.

=head1 SUBROUTINES/METHODS

=head2 new

=head2 address

=head2 user

=head2 port

=head2 key

=head2 transport

=head1 DIAGNOSTICS

Transport failures are reported through exceptions naming the guest.

=head1 CONFIGURATION AND ENVIRONMENT

C<OVERNET_BURNER_SSH> and C<OVERNET_BURNER_SCP> override the ssh and scp
binaries.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Remote paths in scp destinations are not shell-quoted, so run directories
with spaces are unsupported over this transport.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
