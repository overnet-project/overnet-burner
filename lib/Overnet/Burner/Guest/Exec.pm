package Overnet::Burner::Guest::Exec;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest';

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Path ();
use File::Spec;
use POSIX qw(WNOHANG);

use Overnet::Burner::Util qw(checked_print);

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
    or croak "open $path: $OS_ERROR\n";
  local $INPUT_RECORD_SEPARATOR = undef;
  my $content = <$fh>;
  close $fh
    or croak "close $path: $OS_ERROR\n";

  return $content;
}

sub launch {
  my ($self, %args) = @_;

  my $command = $args{command} || croak "command is required\n";
  my $stdout  = $args{stdout}  || croak "stdout is required\n";
  my $stderr  = $args{stderr}  || croak "stderr is required\n";
  my $env     = ref $args{env} eq 'HASH' ? $args{env} : {};

  my $pid = fork;
  if (!defined $pid) {
    croak "fork guest process: $OS_ERROR\n";
  }
  if ($pid == 0) {
    local %ENV = (%ENV, %{$env});
    open STDOUT, '>', $stdout or do {
      checked_print(\*STDERR, "open $stdout: $OS_ERROR\n");
      exit 127;
    };
    open STDERR, '>', $stderr or exit 127;
    if (!exec '/bin/sh', '-c', $command) {
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
    or croak "opendir $workers_root: $OS_ERROR\n";
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
