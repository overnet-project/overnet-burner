package Overnet::Burner::Runner::RexLocal;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Runner';

use Carp    qw(croak);
use English qw(-no_match_vars);
use File::Spec;
use JSON ();

use Overnet::Burner::RexBundle;
use Overnet::Burner::Util qw(checked_print read_file read_json_file);

our $VERSION = '0.001';

no Moo;

sub prepare {
  my ($self) = @_;

  my $bundle = Overnet::Burner::RexBundle->render(
    run_dir => $self->{run_dir},
    plan    => $self->{plan},
  );

  $self->{ledger}->record_rex_bundle(
    relative_dir => $bundle->{relative_dir},
    files        => $bundle->{files},
  );

  $self->{rex_bundle} = {
    path             => $bundle->{relative_dir},
    rendered         => 1,
    remote_execution => 'not_performed',
    files            => $bundle->{files},
  };
  $self->{rex_tasks} = [];

  return 1;
}

sub start {
  my ($self) = @_;

  my $bundle              = $self->_rex_bundle;
  my $bundle_dir          = $bundle->{path};
  my $rexfile             = File::Spec->catfile($bundle_dir, 'Rexfile');
  my $absolute_run_dir    = File::Spec->rel2abs($self->{run_dir});
  my $absolute_bundle_dir = File::Spec->catdir($absolute_run_dir, $bundle_dir);
  my $absolute_rexfile    = File::Spec->catfile($absolute_run_dir, $rexfile);
  my $lifecycle           = _read_json(File::Spec->catfile($absolute_bundle_dir, 'lifecycle.json'),);
  my $rexfile_text        = _read_file($absolute_rexfile);

  for my $command (@{$lifecycle->{commands} || []}) {
    my $task = $command->{rex_task} || croak "Rex lifecycle task is required\n";
    $self->_assert_rex_task($rexfile_text, $task, $rexfile);
    $self->_record_rex_task_event(
      task       => $task,
      status     => 'started',
      bundle_dir => $bundle_dir,
      rexfile    => $rexfile,
    );

    my $ok = eval {
      $self->_invoke_rex_task(
        task                => $task,
        absolute_bundle_dir => $absolute_bundle_dir,
        absolute_rexfile    => $absolute_rexfile,
      );
      1;
    };
    if (!$ok) {
      my $error = $EVAL_ERROR || 'Rex task failed';
      chomp $error;
      $self->_record_rex_task_event(
        task       => $task,
        status     => 'failed',
        bundle_dir => $bundle_dir,
        rexfile    => $rexfile,
        error      => $error,
      );
      push @{$self->{rex_tasks}},
        {
        task       => $task,
        status     => 'failed',
        bundle_dir => $bundle_dir,
        rexfile    => $rexfile,
        };
      croak "$error\n";
    }

    $self->_record_rex_task_event(
      task       => $task,
      status     => 'completed',
      bundle_dir => $bundle_dir,
      rexfile    => $rexfile,
    );
    push @{$self->{rex_tasks}},
      {
      task       => $task,
      status     => 'completed',
      bundle_dir => $bundle_dir,
      rexfile    => $rexfile,
      };
  }

  return 1;
}

sub observe { return 1 }
sub stop    { return 1 }
sub collect { return 1 }

sub summary_fields {
  my ($self) = @_;

  return (
    rex_bundle => $self->_rex_bundle,
    rex_tasks  => $self->{rex_tasks} || [],
  );
}

sub _record_rex_task_event {
  my ($self, %args) = @_;

  $self->{ledger}->append_runner_event(
    {
      runner     => $self->name,
      phase      => 'start',
      rex_task   => $args{task},
      status     => $args{status},
      bundle_dir => $args{bundle_dir},
      rexfile    => $args{rexfile},
      exists $args{error} ? (error => $args{error}) : (),
    }
  );

  return 1;
}

sub _rex_bundle {
  my ($self) = @_;

  return $self->{rex_bundle} || croak "Rex bundle has not been rendered\n";
}

sub _assert_rex_task {
  my ($self, $rexfile_text, $task, $rexfile) = @_;

  if (!($rexfile_text =~ /\btask\s+['"]\Q$task\E['"]/mxs)) {
    croak "Rex task not rendered in $rexfile: $task\n";
  }

  return 1;
}

sub _invoke_rex_task {
  my ($self, %args) = @_;

  my $task                = $args{task};
  my $absolute_rexfile    = $args{absolute_rexfile};
  my $absolute_bundle_dir = $args{absolute_bundle_dir};

  $self->_capture_command(
    cwd     => $absolute_bundle_dir,
    command => [$self->_rex_command, '-f', $absolute_rexfile, $task],
  );

  return 1;
}

sub _rex_command {
  return $ENV{OVERNET_BURNER_REX} || 'rex';
}

sub _capture_command {
  my ($self, %args) = @_;

  my $cwd     = $args{cwd}     || croak "cwd is required\n";
  my $command = $args{command} || croak "command is required\n";

  my $pid = open my $fh, q{-|};
  if (!defined $pid) {
    croak "fork Rex command: $OS_ERROR\n";
  }

  if ($pid == 0) {
    chdir $cwd or do {
      checked_print(\*STDERR, "chdir $cwd: $OS_ERROR\n");
      exit 127;
    };
    open STDERR, '>&', \*STDOUT
      or do {
      checked_print(\*STDERR, "redirect STDERR: $OS_ERROR\n");
      exit 127;
      };
    if (!exec @{$command}) {
      checked_print(\*STDERR, "exec $command->[0]: $OS_ERROR\n");
      exit 127;
    }
  }

  local $INPUT_RECORD_SEPARATOR = undef;
  my $output = <$fh>;
  my $ok     = close $fh;
  my $status = $CHILD_ERROR;
  if ($ok) {
    return $output;
  }

  my $error = "Rex task command failed: $command->[0] " . _child_status_detail($status);
  if (!defined $output) {
    $output = q{};
  }
  chomp $output;
  if (length $output) {
    $error .= ": $output";
  }
  croak "$error\n";
}

sub _child_status_detail {
  my ($status) = @_;

  if ($status & 127) {
    return 'ended by signal ' . ($status & 127);
  }

  return 'exited with status ' . ($status >> 8);
}

sub _read_json {
  my ($path) = @_;

  return read_json_file($path);
}

sub _read_file {
  my ($path) = @_;

  return read_file($path);
}

1;

=head1 NAME

Overnet::Burner::Runner::RexLocal - local Rex runner

=head1 DESCRIPTION

Renders a Rex bundle and invokes its local lifecycle tasks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(name => 'rex-local', %args);

=head1 SUBROUTINES/METHODS

=head2 prepare

=head2 start

=head2 observe

=head2 stop

=head2 collect

=head2 summary_fields

=head1 DIAGNOSTICS

Rex command failures are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

C<OVERNET_BURNER_REX> may override the Rex command used by the runner.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
