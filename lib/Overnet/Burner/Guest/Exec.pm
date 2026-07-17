package Overnet::Burner::Guest::Exec;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest';

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Path ();
use File::Spec;
use File::Temp  ();
use POSIX       qw(WNOHANG);
use Time::HiRes ();

use Overnet::Burner::Util qw(checked_print);

# How long a timed-out command is given to exit on TERM before it is escalated
# to KILL.
my $KILL_GRACE_SECONDS = 2;
my $REAP_POLL_SECONDS  = 0.05;

our $VERSION = '0.001';

no Moo;

sub transport {
  return 'exec';
}

sub make_path {
  my ($self, $path) = @_;

  if (!-d $path) {
    File::Path::make_path($path);
  }

  return 1;
}

sub write_file {
  my ($self, $path, $content) = @_;

  Overnet::Burner::Util::write_file($path, $content);

  return 1;
}

sub read_file {
  my ($self, $path) = @_;

  if (!-e $path) {
    return;
  }

  open my $fh, '<', $path
    or croak "open $path: $OS_ERROR\n";    # uncoverable branch true reason: an existing file opens for read here
  local $INPUT_RECORD_SEPARATOR = undef;
  my $content = <$fh>;
  close $fh
    or croak "close $path: $OS_ERROR\n";    # uncoverable branch true reason: closing a read handle cannot fail here

  return $content;
}

sub run_command {
  my ($self, %args) = @_;

  my $command = $args{command} || croak "command is required\n";
  my $cwd     = $args{cwd};
  my $env     = ref $args{env} eq 'HASH' ? $args{env} : {};
  my $timeout = $args{timeout};

  my $out = File::Temp->new(UNLINK => 1);
  my $err = File::Temp->new(UNLINK => 1);

  my $pid = fork;
  if (!defined $pid) {    # uncoverable branch true reason: fork cannot be forced to fail in a test
    croak "fork guest command: $OS_ERROR\n";
  }
  if ($pid == 0) {
    local %ENV = (%ENV, %{$env});
    if (defined $cwd) {
      chdir $cwd or do {
        checked_print(\*STDERR, "chdir $cwd: $OS_ERROR\n");
        exit 127;
      };
    }
    open STDOUT, '>', $out->filename or exit 127;    # uncoverable branch true reason: a fresh temp file opens for write
    open STDERR, '>', $err->filename or exit 127;    # uncoverable branch true reason: a fresh temp file opens for write
    if (!exec '/bin/sh', '-c', $command) {           # uncoverable branch true reason: exec replaces the process
      exit 127;
    }
  }

  my $timed_out = $self->_await_command($pid, $timeout);
  my $status    = $CHILD_ERROR;

  my $result = {
    exit_code => ($status & 127) ? undef : ($status >> 8),
    stdout    => $self->read_file($out->filename) // q{},
    stderr    => $self->read_file($err->filename) // q{},
  };
  if ($timed_out) {

    # A killed command's exit code is meaningless; mark the timeout explicitly so
    # callers report it as a timeout rather than an ordinary failure.
    $result->{exit_code} = undef;
    $result->{timed_out} = 1;
  }

  return $result;
}

# Wait for a command child to exit. Without a timeout this blocks, preserving
# the original behavior. With a positive timeout it polls until the deadline and,
# if the command overruns, escalates TERM then KILL and reaps it so a hung
# command can never wedge the run. Returns true when the timeout was enforced.
sub _await_command {
  my ($self, $pid, $timeout) = @_;

  if (!$timeout) {
    if (waitpid($pid, 0) != $pid) {    # uncoverable branch true reason: waitpid on our own child returns it
      croak "wait guest command: $OS_ERROR\n";
    }
    return 0;
  }

  if ($self->_reap_before(Time::HiRes::time() + $timeout, $pid)) {
    return 0;
  }

  for my $signal (qw(TERM KILL)) {
    kill $signal, $pid;
    if ($self->_reap_before(Time::HiRes::time() + $KILL_GRACE_SECONDS, $pid)) {
      last;
    }
  }
  waitpid $pid, 0;

  return 1;
}

sub _reap_before {
  my ($self, $deadline, $pid) = @_;

  while (Time::HiRes::time() < $deadline) {
    if (waitpid($pid, WNOHANG) == $pid) {
      return 1;
    }
    Time::HiRes::sleep($REAP_POLL_SECONDS);
  }

  return 0;
}

sub launch {
  my ($self, %args) = @_;

  my $command = $args{command} || croak "command is required\n";
  my $stdout  = $args{stdout}  || croak "stdout is required\n";
  my $stderr  = $args{stderr}  || croak "stderr is required\n";
  my $env     = ref $args{env} eq 'HASH' ? $args{env} : {};

  my $pid = fork;
  if (!defined $pid) {    # uncoverable branch true reason: fork cannot be forced to fail in a test
    croak "fork guest process: $OS_ERROR\n";
  }
  if ($pid == 0) {
    local %ENV = (%ENV, %{$env});
    open STDOUT, '>', $stdout or do {
      checked_print(\*STDERR, "open $stdout: $OS_ERROR\n");
      exit 127;
    };
    open STDERR, '>', $stderr or exit 127;
    if (!exec '/bin/sh', '-c', $command) {    # uncoverable branch true reason: exec replaces the process on success
      exit 127;
    }
  }

  return $pid;
}

sub try_reap {
  my ($self, $handle) = @_;

  if (waitpid($handle, WNOHANG) == $handle) {
    return $CHILD_ERROR;
  }

  return;
}

sub signal {
  my ($self, $handle, $signal) = @_;

  kill $signal, $handle;

  return 1;
}

sub ready_actors {
  my ($self, $workers_root) = @_;

  if (!-d $workers_root) {
    return [];
  }

  opendir my $dh, $workers_root
    or croak "opendir $workers_root: $OS_ERROR\n";    # uncoverable branch true reason: a checked directory opens here
  my @entries = readdir $dh;
  closedir $dh;

  my @ready;
  for my $entry (@entries) {
    if ($entry =~ /\A[.]/mxs) {
      next;
    }
    if (-e File::Spec->catfile($workers_root, $entry, 'ready')) {
      push @ready, $entry;
    }
  }

  return \@ready;
}

1;

=head1 NAME

Overnet::Burner::Guest::Exec - the local exec guest transport

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $guest = Overnet::Burner::Guest::Exec->new(name => 'local', role => 'workers');

=head1 DESCRIPTION

Implements the guest contract on the controller host itself: files are
plain filesystem operations, processes are forked children of the runner
with redirected output, and the readiness probe is one directory scan.
This is the C<how: local> provisioning method of F<docs/provisioning.md>
and exactly the behavior the workers runner had before the guest interface
existed.

=head1 SUBROUTINES/METHODS

=head2 transport

=head2 make_path

=head2 write_file

=head2 read_file

=head2 run_command

=head2 launch

=head2 try_reap

=head2 signal

=head2 ready_actors

=head1 DIAGNOSTICS

Filesystem and fork failures are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

None.

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
