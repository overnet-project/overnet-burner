package Overnet::Burner::Worker::Syncer;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use AnyEvent;
use English qw(-no_match_vars);
use Net::Nostr::Client;
use Net::Nostr::Filter;
use Net::Nostr::Negentropy;
use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

my $DEFAULT_SYNC_TIMEOUT = 10;

no Moo;

sub expected_role {
  return 'syncer';
}

sub run {
  my ($self) = @_;

  my $input    = $self->input;
  my $endpoint = $input->{endpoints}{relays}[0];
  my $interval = $self->_sync_interval;

  $self->open_metric_stream;
  $self->write_ready_file;

  my $stop = 0;
  local $SIG{TERM} = sub { $stop = 1 };

  my $started  = time;
  my $deadline = $started + $input->{duration_seconds};
  my $tick     = 0;

  while (!$stop) {
    my $scheduled = $started + $tick * $interval;
    if ($scheduled >= $deadline) {
      last;
    }
    my $wait = $scheduled - time;
    if ($wait > 0) {
      sleep $wait;
    }
    if ($stop || time >= $deadline) {
      last;
    }

    $self->_sync_once(endpoint => $endpoint, phase => $self->phase_name_at(time - $started));
    $tick++;
  }

  $self->close_metric_stream;

  return;
}

# One negentropy reconciliation session against the relay. The syncer holds no
# events locally, so a session measures how much of the relay's visible set it
# would need to fetch and how many protocol rounds that reconciliation takes --
# the negentropy sync cost. Emits one sync_round metric per session.
sub _sync_once {
  my ($self, %args) = @_;

  my $endpoint   = $args{endpoint};
  my $filter     = Net::Nostr::Filter->new(%{$self->_sync_filter});
  my $negentropy = Net::Nostr::Negentropy->new;
  $negentropy->seal;
  my $initial = $negentropy->initiate;

  my $state = {
    client     => Net::Nostr::Client->new,
    negentropy => $negentropy,
    sub_id     => 'burner-' . $self->input->{worker_id} . '-sync',
    done       => AnyEvent->condvar,
    rounds     => 0,
    have       => [],
    need       => [],
    error      => undef,
  };
  my $client = $state->{client};
  $client->on(neg_msg => sub { $self->_reconcile_step($state, $_[1]) });
  $client->on(neg_err => sub { $self->_note_neg_error($state, $_[1]) });

  my $started_at = time;
  my $timeout    = AnyEvent->timer(after => $self->_sync_timeout, cb => sub { $state->{done}->send(0) });

  my $converged = eval {
    $client->connect($endpoint);
    $client->neg_open($state->{sub_id}, $filter, $initial);
    $state->{done}->recv;
  };
  if (!defined $converged) {
    my $connect_error = $EVAL_ERROR;
    chomp $connect_error;
    $state->{error} = $connect_error || 'sync connection failed';
    $converged = 0;
  }
  my $finished_at = time;

  # Best-effort teardown: a relay that never connected (or already dropped the
  # socket) makes neg_close/disconnect croak, which is not a session failure.
  if (!eval { $client->neg_close($state->{sub_id}); $client->disconnect; 1 }) {
    undef $timeout;
  }

  $self->emit_metric(
    operation   => 'sync_round',
    phase       => $args{phase},
    started_at  => $self->iso_timestamp($started_at),
    finished_at => $self->iso_timestamp($finished_at),
    duration_ms => ($finished_at - $started_at) * 1000,
    status      => $converged ? 'success' : 'error',
    relay_url   => $endpoint,
    rounds      => $state->{rounds},
    have_count  => scalar(@{$state->{have}}),
    need_count  => scalar(@{$state->{need}}),
    (
      $converged
      ? ()
      : (error => defined $state->{error} && length $state->{error} ? $state->{error} : 'sync did not converge')
    ),
  );

  return;
}

# Fold one relay NEG-MSG into the running reconciliation. Returns the next
# protocol message to the relay while negentropy has ranges left to resolve, or
# signals convergence once it is done. The syncer holds no local events, so in
# practice the relay answers in a single round; the multi-round branch keeps the
# handler protocol-complete for a relay that splits its answer.
sub _reconcile_step {
  my ($self, $state, $response) = @_;

  my ($next, $have, $need) = $state->{negentropy}->reconcile($response);
  push @{$state->{have}}, @{$have};
  push @{$state->{need}}, @{$need};
  $state->{rounds}++;
  if (defined $next) {
    $state->{client}->neg_msg($state->{sub_id}, $next);
  } else {
    $state->{done}->send(1);
  }

  return;
}

# Record a relay-reported negentropy failure and end the session as an error.
sub _note_neg_error {
  my ($self, $state, $message) = @_;

  $state->{error} = defined $message && length $message ? $message : 'negentropy error';
  $state->{done}->send(0);

  return;
}

sub _syncer_config {
  my ($self) = @_;

  my $phases = $self->phases;
  return ref $phases->[0]{syncer} eq 'HASH' ? $phases->[0]{syncer} : {};
}

sub _sync_interval {
  my ($self) = @_;

  my $interval = $self->_syncer_config->{interval_seconds};
  if (!(defined $interval && $interval > 0)) {
    $interval = 1;
  }

  return $interval;
}

sub _sync_timeout {
  my ($self) = @_;

  my $timeout = $self->_syncer_config->{timeout_seconds};
  if (!(defined $timeout && $timeout > 0)) {
    $timeout = $DEFAULT_SYNC_TIMEOUT;
  }

  return $timeout;
}

sub _sync_filter {
  my ($self) = @_;

  my $filters = $self->_syncer_config->{filters};
  if (ref $filters eq 'ARRAY' && @{$filters} && ref $filters->[0] eq 'HASH') {
    return $filters->[0];
  }

  return {};
}

1;

=head1 NAME

Overnet::Burner::Worker::Syncer - negentropy reconciliation workload

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # Invoked by the worker runner from a worker input document.
  Overnet::Burner::Worker::Syncer->new(input => $input)->run;

=head1 DESCRIPTION

Runs NIP-77 negentropy reconciliation sessions against a relay and measures
their cost. The syncer derives no local event set, so each session reconciles
its (empty) view against the relay's visible events, discovering how many events
it would need to fetch and how many protocol rounds the reconciliation takes.
See F<docs/workers.md>.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Returns C<syncer>.

=head2 run

Opens the metric stream, signals readiness, and paces one reconciliation session
per C<syncer.interval_seconds> until the run duration elapses. A C<SIGTERM>
stops the loop.

=head1 METRICS

Each session emits one C<sync_round> metric with C<duration_ms> (the session
time), C<status>, C<rounds> (protocol message exchanges), C<have_count>,
C<need_count>, and C<relay_url>.

=head1 DIAGNOSTICS

A missing relay endpoint is fatal. A session that cannot connect or does not
converge within the timeout is an C<error> metric, not a worker failure.

=head1 CONFIGURATION AND ENVIRONMENT

The C<syncer> workload block configures reconciliation:
C<syncer.interval_seconds> paces sessions (default one second);
C<syncer.filters> selects the reconciled event set (default: all visible
events); C<syncer.timeout_seconds> bounds a single reconciliation session
before it is abandoned as an error (default ten seconds).

=head1 DEPENDENCIES

Requires L<Net::Nostr::Client>, L<Net::Nostr::Negentropy>, and L<AnyEvent>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The syncer holds no local events, so it measures download-side reconciliation
cost; it does not upload events to the relay.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
