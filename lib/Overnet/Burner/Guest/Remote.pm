package Overnet::Burner::Guest::Remote;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Guest';

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Temp ();

our $VERSION = '0.001';

no Moo;

sub _capture {
  croak "remote guest classes must define _capture\n";
}

sub _push_file {
  croak "remote guest classes must define _push_file\n";
}

sub shell_quote {
  my ($class, $value) = @_;

  my $quoted = defined $value ? $value : q{};
  $quoted =~ s/'/'\\''/gmxs;

  return "'$quoted'";
}

sub make_path {
  my ($self, $path) = @_;

  my (undef, $status) = $self->_capture('mkdir -p ' . $self->shell_quote($path));
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

  $self->_push_file($staged->filename, $path);

  return 1;
}

sub read_file {
  my ($self, $path) = @_;

  my $quoted = $self->shell_quote($path);
  my ($content, $status) = $self->_capture("test -e $quoted && cat $quoted");
  if ($status != 0) {
    return;
  }

  return $content;
}

sub run_command {
  my ($self, %args) = @_;

  my $command = $args{command} || croak "command is required\n";
  my $env     = ref $args{env} eq 'HASH' ? $args{env} : {};

  my ($dir, $mkstatus) = $self->_capture('mktemp -d');
  if ($mkstatus != 0 || !defined $dir) {
    croak 'guest ' . $self->name . " could not allocate a command work dir\n";
  }
  chomp $dir;
  $dir =~ s/\s+\z//mxs;

  my $out    = "$dir/stdout";
  my $err    = "$dir/stderr";
  my $prefix = q{};
  for my $key (sort keys %{$env}) {
    $prefix .= 'export ' . $key . q{=} . $self->shell_quote($env->{$key}) . '; ';
  }

  # The transport status reflects the trailing echo, so the command's own
  # exit code is reported inline and parsed back out.
  my ($marker, $status) =
    $self->_capture($prefix
      . '/bin/sh -c '
      . $self->shell_quote($command) . ' > '
      . $self->shell_quote($out) . ' 2> '
      . $self->shell_quote($err)
      . "; echo \"OVERNET_EXIT:\$?\"");
  my ($exit_code) = ($status == 0 && defined $marker) ? $marker =~ /OVERNET_EXIT:(\d+)/mxs : ();

  my $stdout = $self->read_file($out) // q{};
  my $stderr = $self->read_file($err) // q{};
  $self->_capture('rm -rf ' . $self->shell_quote($dir));

  return {
    exit_code => (defined $exit_code ? 0 + $exit_code : undef),
    stdout    => $stdout,
    stderr    => $stderr,
  };
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
    $script .= "$key=" . $self->shell_quote($env->{$key}) . "\nexport $key\n";
  }
  $script .=
      '/bin/sh -c '
    . $self->shell_quote($command) . ' > '
    . $self->shell_quote($stdout) . ' 2> '
    . $self->shell_quote($stderr) . " &\n";
  $script .= "child=\$!\n";
  $script .= "echo \"\$child\" > " . $self->shell_quote($pid_file) . "\n";
  $script .= "wait \"\$child\"\n";
  $script .= "echo \$? > " . $self->shell_quote($status_file) . "\n";

  $self->write_file($supervisor, $script);

  my ($pid, $status) =
    $self->_capture('nohup /bin/sh ' . $self->shell_quote($supervisor) . " > /dev/null 2>&1 & echo \$!");
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

  my $reaped = $self->_read_exit_status($handle);
  if (defined $reaped) {
    return $reaped;
  }

  my ($probe, $status) = $self->_capture("kill -0 $handle->{supervisor_pid} 2>/dev/null && echo alive || echo dead");
  my ($state) = defined $probe ? $probe =~ /\A\s*(alive|dead)\s*\z/mxs : ();
  if ($status != 0 || !defined $state) {

    # A probe that failed or answered garbage is a transport problem, not a
    # dead supervisor: report nothing and let the next reap pass try again.
    return;
  }
  if ($state eq 'alive') {
    return;
  }

  # The supervisor can write the status file and exit between the read above
  # and the liveness probe; only a status file that is still missing after
  # the supervisor is known dead means the worker was killed.
  $reaped = $self->_read_exit_status($handle);
  if (defined $reaped) {
    return $reaped;
  }

  return 9;
}

sub _read_exit_status {
  my ($self, $handle) = @_;

  my ($code, $status) = $self->_capture('cat ' . $self->shell_quote($handle->{status_file}) . ' 2>/dev/null');
  if ($status == 0 && defined $code && $code =~ /\A\s*(\d+)\s*\z/mxs) {
    return $1 << 8;
  }

  return;
}

sub signal {
  my ($self, $handle, $signal) = @_;

  $self->_capture("kill -$signal \"\$(cat " . $self->shell_quote($handle->{pid_file}) . " 2>/dev/null)\" 2>/dev/null");

  return 1;
}

sub reachable {
  my ($self) = @_;

  my (undef, $status) = $self->_capture('true');

  return $status == 0 ? 1 : 0;
}

sub ready_actors {
  my ($self, $workers_root) = @_;

  my ($output, $status) =
    $self->_capture('cd '
      . $self->shell_quote($workers_root)
      . " 2>/dev/null && for f in */ready; do [ -e \"\$f\" ] && printf '%s\\n' \"\${f%/ready}\"; done; true");
  if ($status != 0 || !defined $output) {
    return [];
  }

  my @ready = grep { length && $_ ne q{*} } split /\n/mxs, $output;

  return \@ready;
}

1;

=head1 NAME

Overnet::Burner::Guest::Remote - shared remote guest plumbing

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  package Overnet::Burner::Guest::SomeRemoteTransport;
  use Moo;
  extends 'Overnet::Burner::Guest::Remote';

  sub transport   { ... }
  sub _capture    { ... }  # run a remote shell command, return (output, status)
  sub _push_file  { ... }  # copy a local file to a remote path

=head1 DESCRIPTION

Every remote transport shares the same problem shape: shell commands on the
guest, files pushed to the guest, and a worker process that must be
launched, signaled, and reaped even though a disowned remote process cannot
be waited on. This base implements the whole guest contract in terms of two
transport primitives - run a remote command capturing output and status,
and push a local file to a remote path. C<launch> stages a supervisor
script that records the worker's pid for signal delivery and writes its
exit status to a file; C<try_reap> reads that status back, and a supervisor
that vanished without writing one is reported as a killed process. A
liveness probe that fails at the transport level reports nothing rather
than a synthetic kill, so a transient connection problem never masquerades
as a dead worker.

=head1 SUBROUTINES/METHODS

=head2 shell_quote

=head2 make_path

=head2 write_file

=head2 read_file

=head2 run_command

Runs one command to completion on the guest, capturing its stdout, stderr,
and exit code back over the transport by staging them in a guest-side temp
directory. Remote guests run in the transport's default working directory,
so a C<cwd> is not accepted here; lifecycle commands placed on a remote
relay guest must not assume the controller's run directory.

=head2 launch

=head2 try_reap

=head2 signal

=head2 reachable

True when the guest answers a trivial command over its transport; used to
wait for constructed guests (containers, virtual machines) to come up.

=head2 ready_actors

=head1 DIAGNOSTICS

Transport failures are reported through exceptions naming the guest.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Reaping polls one remote command per worker per cycle, which will need
batching at very high worker counts.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
