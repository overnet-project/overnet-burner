package Overnet::Burner::Guest::Virtual;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest::SSH';

use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

has pid_file  => (is => 'ro', required => 1);
has image     => (is => 'ro');
has memory_mb => (is => 'ro');
has cpus      => (is => 'ro');
has accel     => (is => 'ro');

no Moo;

my $DESTROY_GRACE_SECONDS = 5;

sub provision_method {
  return 'virtual';
}

sub _transport_options {

  # The VM's host key is generated fresh on every -snapshot boot, so there
  # is no prior knowledge to verify it against; the connect timeout bounds
  # reachability probes against a guest that accepts TCP but cannot finish
  # the handshake yet.
  return qw(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5);
}

sub destroy {
  my ($self) = @_;

  if ($self->{destroyed}) {
    return 1;
  }
  $self->{destroyed} = 1;

  my $pid = $self->_vm_pid;
  if (!$pid) {
    return 1;
  }
  kill 'TERM', $pid;
  my $deadline = time + $DESTROY_GRACE_SECONDS;
  while (kill(0, $pid) && time < $deadline) {
    sleep 0.1;
  }
  if (kill 0, $pid) {
    kill 'KILL', $pid;
  }

  return 1;
}

sub _vm_pid {
  my ($self) = @_;

  open my $fh, '<', $self->pid_file or return;
  my $line = <$fh>;
  close $fh or return;
  if (!defined $line) {
    return;
  }
  my ($pid) = $line =~ /([0-9]+)/mxs;

  return $pid;
}

1;

=head1 NAME

Overnet::Burner::Guest::Virtual - a QEMU virtual machine guest

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $guest = Overnet::Burner::Guest::Virtual->new(
    name     => 'worker-guest-001',
    role     => 'workers',
    address  => '127.0.0.1',
    port     => 40022,
    user     => 'burner',
    key      => '/run/dir/virtual/id_ed25519',
    pid_file => '/run/dir/virtual/worker-guest-001/qemu.pid',
  );

=head1 DESCRIPTION

A virtual machine guest is an SSH guest that the run constructed, per the
virtual method decisions in F<docs/provisioning.md>: the runner boots QEMU
with a cloud-init seed and a per-guest hostfwd SSH port, and once the
guest is reachable every operation is the plain SSH transport. This class
adds the two things a constructed VM needs beyond SSH: host-key checking
is disabled because a C<-snapshot> boot generates a fresh host key every
time, and C<destroy> terminates the QEMU process recorded in the pid file
(TERM, then KILL after a grace period), exactly once.

=head1 SUBROUTINES/METHODS

=head2 new

=head2 pid_file

=head2 image

=head2 memory_mb

=head2 cpus

=head2 accel

The accelerator the VM actually runs with (C<kvm> or C<tcg>), recorded in
the guest ledger so a TCG run never presents itself as KVM-fast.

=head2 provision_method

=head2 destroy

=head1 DIAGNOSTICS

Transport failures are reported through exceptions naming the guest;
C<destroy> is best-effort teardown and never dies.

=head1 CONFIGURATION AND ENVIRONMENT

None beyond the SSH transport's environment.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

C<destroy> trusts the QEMU pid file; a VM whose pid file was removed
out-of-band is not hunted down.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
