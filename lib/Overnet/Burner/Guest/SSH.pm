package Overnet::Burner::Guest::SSH;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest';

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Temp ();

our $VERSION = '0.001';

has address => (is => 'ro', required => 1);
has user    => (is => 'ro');
has port    => (is => 'ro');
has key     => (is => 'ro');

no Moo;

sub transport {
  return 'ssh';
}

sub make_path {
  my ($self, $path) = @_;

  my ($output, $status) = $self->_capture('mkdir -p ' . _quote($path));
  if ($status != 0) {
    croak 'guest ' . $self->name . " could not create $path\n";
  }

  return 1;
}

sub write_file {
  my ($self, $path, $content) = @_;

  my $staged = File::Temp->new(UNLINK => 1);
  print {$staged} $content
    or croak "stage $path: $OS_ERROR\n";
  close $staged
    or croak "stage $path: $OS_ERROR\n";

  my $status = system $self->_scp_binary, $self->_scp_options, $staged->filename, $self->_target . ":$path";
  if ($status != 0) {
    croak 'guest ' . $self->name . " could not write $path\n";
  }

  return 1;
}

sub read_file {
  my ($self, $path) = @_;

  my $quoted = _quote($path);
  my ($content, $status) = $self->_capture("test -e $quoted && cat $quoted");
  if ($status != 0) {
    return;
  }

  return $content;
}

sub launch {
  my ($self, %args) = @_;

  my $command = $args{command} || croak "command is required\n";
  my $stdout  = $args{stdout}  || croak "stdout is required\n";
  my $stderr  = $args{stderr}  || croak "stderr is required\n";
  my $env     = ref $args{env} eq 'HASH' ? $args{env} : {};

  my $supervisor  = "$stdout.supervisor.sh";
  my $pid_file    = "$stdout.pid";
  my $status_file = "$stdout.status";

  my $script = "#!/bin/sh\n";
  for my $key (sort keys %{$env}) {
    $script .= "$key=" . _quote($env->{$key}) . "\nexport $key\n";
  }
  $script .= '/bin/sh -c ' . _quote($command) . ' > ' . _quote($stdout) . ' 2> ' . _quote($stderr) . " &\n";
  $script .= "child=\$!\n";
  $script .= "echo \"\$child\" > " . _quote($pid_file) . "\n";
  $script .= "wait \"\$child\"\n";
  $script .= "echo \$? > " . _quote($status_file) . "\n";

  $self->write_file($supervisor, $script);

  my ($pid, $status) =
    $self->_capture('nohup /bin/sh ' . _quote($supervisor) . " > /dev/null 2>&1 & echo \$!");
  if ($status != 0 || !defined $pid || $pid !~ /\A\s*\d+\s*\z/mxs) {
    croak 'guest ' . $self->name . " could not launch: $command\n";
  }
  chomp $pid;
  $pid =~ s/\s+//gmxs;

  return {
    supervisor_pid => $pid,
    pid_file       => $pid_file,
    status_file    => $status_file,
  };
}

sub try_reap {
  my ($self, $handle) = @_;

  my ($code, $status) = $self->_capture('cat ' . _quote($handle->{status_file}) . ' 2>/dev/null');
  if ($status == 0 && defined $code && $code =~ /\A\s*(\d+)\s*\z/mxs) {
    return $1 << 8;
  }

  my (undef, $alive) = $self->_capture("kill -0 $handle->{supervisor_pid} 2>/dev/null");
  if ($alive == 0) {
    return;
  }

  return 9;
}

sub signal {
  my ($self, $handle, $signal) = @_;

  $self->_capture("kill -$signal \"\$(cat " . _quote($handle->{pid_file}) . " 2>/dev/null)\" 2>/dev/null");

  return 1;
}

sub ready_actors {
  my ($self, $workers_root) = @_;

  my ($output, $status) =
    $self->_capture('cd '
      . _quote($workers_root)
      . " 2>/dev/null && for f in */ready; do [ -e \"\$f\" ] && printf '%s\\n' \"\${f%/ready}\"; done; true");
  if ($status != 0 || !defined $output) {
    return [];
  }

  my @ready = grep { length && $_ ne q{*} } split /\n/mxs, $output;

  return \@ready;
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

sub _quote {
  my ($value) = @_;

  my $quoted = defined $value ? $value : q{};
  $quoted =~ s/'/'\\''/gmxs;

  return "'$quoted'";
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

Implements the guest contract over OpenSSH for the C<how: connect>
provisioning method of F<docs/provisioning.md>: files move over scp and
C<cat>, directories come from C<mkdir -p>, and readiness is one aggregate
remote directory scan. Because a disowned remote process cannot be waited
on, C<launch> stages a small supervisor script that runs the worker,
records its pid for signal delivery, and writes its exit status to a file;
C<try_reap> reads that status back, and a supervisor that vanished without
writing one is reported as a killed process.

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

=head2 make_path

=head2 write_file

=head2 read_file

=head2 launch

=head2 try_reap

=head2 signal

=head2 ready_actors

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

Reaping polls one remote command per worker per cycle, which is fine for
moderate worker counts but will need batching at high scale. Remote paths
in scp destinations are not shell-quoted, so run directories with spaces
are unsupported over this transport.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
