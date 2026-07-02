package Overnet::Burner::Runner::RexLocalWorkers;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Runner::RexLocalProvider';

use Carp           qw(croak);
use English        qw(-no_match_vars);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Spec;
use JSON        ();
use POSIX       qw(WNOHANG);
use Time::HiRes qw(sleep time);

use Overnet::Burner::Util qw(checked_print json_text read_json_file write_file);

our $VERSION = '0.001';

no Moo;

my %WORKER_ROLES = (publisher => 1,);
my @LAUNCH_WAVES = ([qw(subscriber query_reader object_reader)], [qw(publisher)],);

my $READY_TIMEOUT_SECONDS = 10;
my $EXIT_GRACE_SECONDS    = 15;
my $KILL_GRACE_SECONDS    = 5;

sub prepare {
  my ($self) = @_;

  $self->SUPER::prepare;
  $self->{worker_results} = [];
  $self->{worker_pids}    = {};

  return 1;
}

sub observe {
  my ($self) = @_;

  $self->SUPER::observe;

  my @actors = $self->_worker_actors;
  my %by_role;
  for my $actor (@actors) {
    if (!$WORKER_ROLES{$actor->{role}}) {
      $self->_record_worker_event(
        actor_id => $actor->{id},
        role     => $actor->{role},
        status   => 'skipped_no_worker',
      );
      next;
    }
    push @{$by_role{$actor->{role}}}, $actor;
  }

  my @launchable = map { @{$by_role{$_} || []} } map { @{$_} } @LAUNCH_WAVES;
  if (!@launchable) {
    return 1;
  }

  my $endpoints = $self->_relay_endpoints;
  if (!@{$endpoints}) {
    croak "topology.relays.endpoints is required to launch workers\n";
  }

  for my $wave (@LAUNCH_WAVES) {
    my @wave_actors = map { @{$by_role{$_} || []} } @{$wave};
    for my $actor (@wave_actors) {
      $self->_launch_worker(actor => $actor, endpoints => $endpoints);
    }
    for my $actor (@wave_actors) {
      $self->_await_worker_ready($actor);
    }
  }

  $self->_await_worker_exits;

  return 1;
}

sub collect {
  my ($self) = @_;

  $self->SUPER::collect;

  my $plan = $self->{plan};
  my @collected;
  my $aggregated = q{};
  for my $stream (@{$plan->{metric_streams} || []}) {
    my $path = File::Spec->catfile($self->{run_dir}, $stream->{path});
    if (!(-e $path && -s $path)) {
      next;
    }
    open my $fh, '<', $path
      or croak "open $path: $OS_ERROR\n";
    local $INPUT_RECORD_SEPARATOR = undef;
    $aggregated .= <$fh>;
    close $fh
      or croak "close $path: $OS_ERROR\n";
    push @collected, $stream->{path};
  }

  if (@collected) {
    write_file(File::Spec->catfile($self->{run_dir}, 'metrics.jsonl'), $aggregated);
  }
  $self->_record_worker_event(
    status            => 'collected',
    phase             => 'collect',
    streams_collected => \@collected,
  );

  return 1;
}

sub summary_fields {
  my ($self) = @_;

  return ($self->SUPER::summary_fields, worker_results => $self->{worker_results} || [],);
}

sub _worker_actors {
  my ($self) = @_;

  my $plan = $self->{plan};
  return map { @{$plan->{$_} || []} } qw(subscribers query_readers object_readers publishers);
}

sub _relay_endpoints {
  my ($self) = @_;

  my @endpoints =
    grep { defined && length } map { $_->{endpoint} } @{$self->{plan}{relays} || []};

  return \@endpoints;
}

sub _launch_worker {
  my ($self, %args) = @_;

  my $actor      = $args{actor};
  my $actor_id   = $actor->{id};
  my $manifest   = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $worker_dir = File::Spec->catdir($self->{run_dir}, 'workers', $actor_id);
  my $logs_dir   = File::Spec->catdir($self->{run_dir}, 'logs',    'workers');
  my $stream_dir = dirname(File::Spec->catfile($self->{run_dir}, $actor->{metric_stream}));
  for my $dir ($worker_dir, $logs_dir, $stream_dir) {
    if (!-d $dir) {
      make_path($dir);
    }
  }

  my $input = {
    input_version    => 1,
    run_id           => $manifest->{run_id},
    run_dir          => File::Spec->rel2abs($self->{run_dir}),
    worker_id        => $actor_id,
    role             => $actor->{role},
    seed             => $actor->{seed},
    duration_seconds => $self->{plan}{run}{duration_seconds},
    metric_stream    => $actor->{metric_stream},
    ready_file       => File::Spec->catfile('workers', $actor_id, 'ready'),
    endpoints        => {relays => $args{endpoints}},
    workload         => $self->{plan}{workload}{phases}[0] || {},
  };
  my $input_path = File::Spec->catfile($worker_dir, 'input.json');
  write_file($input_path, json_text($input));

  my $command = $ENV{OVERNET_BURNER_WORKER} || 'overnet-burner-worker';
  my $stdout  = File::Spec->catfile($logs_dir, "$actor_id.stdout");
  my $stderr  = File::Spec->catfile($logs_dir, "$actor_id.stderr");

  my $pid = fork;
  if (!defined $pid) {
    croak "fork worker $actor_id: $OS_ERROR\n";
  }
  if ($pid == 0) {
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = File::Spec->rel2abs($input_path);
    open STDOUT, '>', $stdout or do {
      checked_print(\*STDERR, "open $stdout: $OS_ERROR\n");
      exit 127;
    };
    open STDERR, '>', $stderr or exit 127;
    if (!exec '/bin/sh', '-c', $command) {
      exit 127;
    }
  }

  $self->{worker_pids}{$actor_id} = $pid;
  $self->_record_worker_event(
    actor_id => $actor_id,
    role     => $actor->{role},
    status   => 'launched',
    command  => $command,
  );

  return 1;
}

sub _await_worker_ready {
  my ($self, $actor) = @_;

  my $actor_id   = $actor->{id};
  my $ready_path = File::Spec->catfile($self->{run_dir}, 'workers', $actor_id, 'ready');
  my $deadline   = time + $READY_TIMEOUT_SECONDS;

  while (time < $deadline) {
    if (-e $ready_path) {
      $self->_record_worker_event(actor_id => $actor_id, role => $actor->{role}, status => 'ready');
      return 1;
    }
    my $pid = $self->{worker_pids}{$actor_id};
    if ($pid && waitpid($pid, WNOHANG) == $pid) {
      $self->_reap_worker($actor_id, $CHILD_ERROR);
      croak "worker $actor_id exited before becoming ready\n";
    }
    sleep 0.05;
  }

  croak "worker $actor_id was not ready within ${READY_TIMEOUT_SECONDS}s\n";
}

sub _await_worker_exits {
  my ($self) = @_;

  my $deadline = time + $self->{plan}{run}{duration_seconds} + $EXIT_GRACE_SECONDS;
  $self->_reap_until($deadline);

  if (%{$self->{worker_pids}}) {
    for my $actor_id (sort keys %{$self->{worker_pids}}) {
      kill 'TERM', $self->{worker_pids}{$actor_id};
    }
    $self->_reap_until(time + $KILL_GRACE_SECONDS);
  }
  if (%{$self->{worker_pids}}) {
    for my $actor_id (sort keys %{$self->{worker_pids}}) {
      kill 'KILL', $self->{worker_pids}{$actor_id};
    }
    $self->_reap_until(time + $KILL_GRACE_SECONDS);
  }

  my @failed = grep { !defined $_->{exit_code} || $_->{exit_code} != 0 } @{$self->{worker_results}};
  if (@failed) {
    my $described = join ', ', map { $_->{actor_id} } @failed;
    croak "worker $described did not complete cleanly\n";
  }

  return 1;
}

sub _reap_until {
  my ($self, $deadline) = @_;

  while (%{$self->{worker_pids}} && time < $deadline) {
    my $reaped = 0;
    for my $actor_id (sort keys %{$self->{worker_pids}}) {
      my $pid = $self->{worker_pids}{$actor_id};
      if (waitpid($pid, WNOHANG) == $pid) {
        $self->_reap_worker($actor_id, $CHILD_ERROR);
        $reaped = 1;
      }
    }
    if (!$reaped) {
      sleep 0.05;
    }
  }

  return 1;
}

sub _reap_worker {
  my ($self, $actor_id, $status) = @_;

  delete $self->{worker_pids}{$actor_id};
  my $exit_code = ($status & 127) ? undef : ($status >> 8);
  my %result    = (
    actor_id => $actor_id,
    status   => 'exited',
    defined $exit_code ? (exit_code => $exit_code) : (signal => ($status & 127)),
  );
  push @{$self->{worker_results}}, \%result;
  $self->_record_worker_event(%result);

  return 1;
}

sub _record_worker_event {
  my ($self, %args) = @_;

  $self->{ledger}->append_runner_event(
    {
      runner     => $self->name,
      phase      => delete $args{phase} || 'observe',
      event_kind => 'worker',
      %args,
    }
  );

  return 1;
}

1;

=head1 NAME

Overnet::Burner::Runner::RexLocalWorkers - local runner that launches workers

=head1 DESCRIPTION

Extends the provider runner to launch worker processes for plan actors under
the worker contract in F<docs/workers.md>: it writes each actor's
worker-input-v1 document, starts one worker process per actor whose role has
a reference worker, sequences readiness (subscribers and readers before
publishers), waits for orderly exits within the run duration plus grace,
and concatenates the collected metric streams into the run's aggregated
C<metrics.jsonl> artifact. Actor roles without a reference worker are
recorded as explicitly skipped.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(name => 'rex-local-workers', %args);

=head1 SUBROUTINES/METHODS

=head2 prepare

=head2 observe

=head2 collect

=head2 summary_fields

=head1 DIAGNOSTICS

Worker launch, readiness, and exit failures are reported through exceptions
after being recorded as runner events.

=head1 CONFIGURATION AND ENVIRONMENT

C<OVERNET_BURNER_WORKER> may override the worker command used for every
launched actor; it defaults to the installed C<overnet-burner-worker>.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Only the C<publisher> role has a reference worker so far; other roles are
skipped with an explicit runner event.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
