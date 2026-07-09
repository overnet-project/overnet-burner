package Overnet::Burner::Runner::RexLocalProvider;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Runner::RexLocal';

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Path qw(make_path);
use File::Spec;
use JSON ();

use Overnet::Burner::Guest::Exec;
use Overnet::Burner::Util qw(read_json_file write_file);

our $VERSION = '0.001';

no Moo;

sub prepare {
  my ($self) = @_;

  $self->SUPER::prepare;
  $self->{topology_provider_commands}       = [];
  $self->{topology_provider_started}        = {};
  $self->{topology_provider_needs_stop}     = 0;
  $self->{topology_provider_stop_attempted} = 0;

  return 1;
}

sub start {
  my ($self) = @_;

  $self->_run_topology_provider_start;
  $self->SUPER::start;

  return 1;
}

sub stop {
  my ($self) = @_;

  if ($self->{topology_provider_stop_attempted}) {
    return 1;
  }
  if (!$self->{topology_provider_needs_stop}) {
    return 1;
  }

  $self->{topology_provider_stop_attempted} = 1;

  for my $relay ($self->_topology_provider_command_relays) {
    my $actor_id = $relay->{actor_id};
    if (!$actor_id) {
      next;
    }
    if (!$self->{topology_provider_started}{$actor_id}) {
      next;
    }

    $self->_run_topology_provider_command(
      actor_id => $actor_id,
      kind     => 'stop',
      command  => $relay->{lifecycle}{stop}{command},
    );
  }

  $self->{topology_provider_needs_stop} = 0;

  return 1;
}

sub summary_fields {
  my ($self) = @_;

  return ($self->SUPER::summary_fields, topology_provider_commands => $self->{topology_provider_commands} || [],);
}

sub cleanup_after_lifecycle_failure {
  my ($self, %args) = @_;

  if (($args{failed_phase} || q{}) eq 'stop') {
    return 1;
  }
  if (!$self->{topology_provider_needs_stop}) {
    return 1;
  }
  if ($self->{topology_provider_stop_attempted}) {
    return 1;
  }

  my $actor_counts = $args{actor_counts} || $self->actor_counts;
  $self->{ledger}->append_runner_event(
    {
      runner       => $self->name,
      phase        => 'stop',
      status       => 'started',
      actor_counts => $actor_counts,
    }
  );

  my $ok = eval {
    $self->stop;
    1;
  };
  if (!$ok) {
    my $error = $EVAL_ERROR || 'runner stop cleanup failed';
    chomp $error;
    if (ref $args{phases} eq 'HASH') {
      $args{phases}{stop} = 'failed';
    }
    $self->{ledger}->append_runner_event(
      {
        runner       => $self->name,
        phase        => 'stop',
        status       => 'failed',
        actor_counts => $actor_counts,
        error        => $error,
      }
    );
    croak "$error\n";
  }

  if (ref $args{phases} eq 'HASH') {
    $args{phases}{stop} = 'completed';
  }
  $self->{ledger}->append_runner_event(
    {
      runner       => $self->name,
      phase        => 'stop',
      status       => 'completed',
      actor_counts => $actor_counts,
    }
  );

  return 1;
}

sub _run_topology_provider_start {
  my ($self) = @_;

  for my $relay ($self->_topology_provider_command_relays) {
    my $actor_id = $relay->{actor_id};
    if (!$actor_id) {
      next;
    }

    $self->_run_topology_provider_command(
      actor_id => $actor_id,
      kind     => 'start',
      command  => $relay->{lifecycle}{start}{command},
    );
    $self->{topology_provider_started}{$actor_id} = 1;
    $self->{topology_provider_needs_stop} = 1;

    $self->_run_topology_provider_command(
      actor_id => $actor_id,
      kind     => 'health',
      command  => $relay->{lifecycle}{health}{command},
    );
  }

  return 1;
}

sub _topology_provider_command_relays {
  my ($self) = @_;

  my $bundle            = $self->_rex_bundle;
  my $path              = File::Spec->catfile($self->{run_dir}, $bundle->{path}, 'topology-provider.json',);
  my $topology_provider = _read_json($path);

  return grep {
         ref $_->{lifecycle} eq 'HASH'
      && ref $_->{lifecycle}{start} eq 'HASH'
      && ref $_->{lifecycle}{health} eq 'HASH'
      && ref $_->{lifecycle}{stop} eq 'HASH'
  } @{$topology_provider->{relays} || []};
}

sub _run_topology_provider_command {
  my ($self, %args) = @_;

  my $actor_id         = $args{actor_id}  || croak "actor_id is required\n";
  my $kind             = $args{kind}      || croak "provider command kind is required\n";
  my $command          = $args{command}   || croak "provider command is required\n";
  my $log_label        = $args{log_label} || "$actor_id-$kind";
  my $relative_stdout  = File::Spec->catfile('logs', 'provider', "$log_label.stdout",);
  my $relative_stderr  = File::Spec->catfile('logs', 'provider', "$log_label.stderr",);
  my $provider_log_dir = File::Spec->catdir($self->{run_dir}, 'logs', 'provider',);

  if (!-d $provider_log_dir) {
    make_path($provider_log_dir);
  }

  my %event_base = (
    actor_id     => $actor_id,
    command_kind => $kind,
    command      => $command,
    stdout_path  => $relative_stdout,
    stderr_path  => $relative_stderr,
    exists $args{phase} ? (phase => $args{phase}) : (),
  );

  my $executor = $self->_provider_command_executor($actor_id);
  $self->_record_topology_provider_event(%event_base, guest => $executor, status => 'started');

  my $outcome = $self->_provider_command_outcome(actor_id => $actor_id, kind => $kind, command => $command,);
  write_file(File::Spec->rel2abs(File::Spec->catfile($self->{run_dir}, $relative_stdout)), $outcome->{stdout} // q{},);
  write_file(File::Spec->rel2abs(File::Spec->catfile($self->{run_dir}, $relative_stderr)), $outcome->{stderr} // q{},);

  my $exit_code     = $outcome->{exit_code};
  my $result_status = defined $exit_code && $exit_code == 0 ? 'completed' : 'failed';
  my %result        = (
    %event_base,
    guest  => $executor,
    status => $result_status,
    defined $exit_code ? (exit_code => $exit_code) : (),
  );

  push @{$self->{topology_provider_commands}}, \%result;
  $self->_record_topology_provider_event(%result);

  if ($result_status eq 'completed') {
    return 1;
  }

  my $detail =
    defined $exit_code
    ? "exited with status $exit_code"
    : 'ended by a signal or transport failure';
  croak "provider command failed: $actor_id $kind $detail\n";
}

# Execute one provider command and return {stdout, stderr, exit_code}. The base
# provider runner runs it through the relay's guest (the controller host, or the
# guest a relay was placed on). A Rex-backed runner overrides this to run the
# command as a real Rex task instead.
sub _provider_command_outcome {
  my ($self, %args) = @_;

  my $guest = $self->_relay_guest_for($args{actor_id});
  return $guest->run_command(
    command => $args{command},
    cwd     => File::Spec->rel2abs($self->{run_dir}),
  );
}

# A label naming what executed the provider command, recorded on each command
# event. The base runner names the guest; a Rex runner names its backend.
sub _provider_command_executor {
  my ($self, $actor_id) = @_;

  return $self->_relay_guest_for($actor_id)->name;
}

sub _relay_guest_for {
  my ($self, $actor_id) = @_;

  # The base provider runner runs relay lifecycle on the controller host.
  # A runner that provisions relay guests overrides this to return the guest
  # a relay was placed on, so the same lifecycle commands run there instead.
  $self->{local_relay_guest} ||= Overnet::Burner::Guest::Exec->new(name => 'local', role => 'relays');
  return $self->{local_relay_guest};
}

sub _record_topology_provider_event {
  my ($self, %args) = @_;

  $self->{ledger}->append_runner_event(
    {
      runner       => $self->name,
      phase        => $args{phase} || ($args{command_kind} eq 'stop' ? 'stop' : 'start'),
      actor_id     => $args{actor_id},
      command_kind => $args{command_kind},
      status       => $args{status},
      stdout_path  => $args{stdout_path},
      stderr_path  => $args{stderr_path},
      command      => $args{command},
      exists $args{exit_code} ? (exit_code => $args{exit_code}) : (),
    }
  );

  return 1;
}

sub _read_json {
  my ($path) = @_;

  return read_json_file($path);
}

1;

=head1 NAME

Overnet::Burner::Runner::RexLocalProvider - Rex runner with provider commands

=head1 DESCRIPTION

Runs explicit topology provider commands around the Rex local lifecycle.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(name => 'rex-local-provider', %args);

=head1 SUBROUTINES/METHODS

=head2 prepare

=head2 start

=head2 stop

=head2 summary_fields

=head2 cleanup_after_lifecycle_failure

=head1 DIAGNOSTICS

Provider command failures are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Provider commands are supplied by topology provider descriptors.

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
