package Overnet::Burner::Worker::SyncBridge;

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
  return 'sync_bridge';
}

sub run {
  my ($self) = @_;

  my $input    = $self->input;
  my $primary  = $input->{endpoints}{relays}[0];
  my $peer     = $input->{endpoints}{relays}[1];
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

    $self->_converge_once(left => $primary, right => $peer, phase => $self->phase_name_at(time - $started));
    $tick++;
  }

  $self->close_metric_stream;

  return;
}

# One convergence session between the two relays. Starting from an empty local
# set the bridge pulls the primary, then reconciles the peer (fetching the
# peer's extra events and pushing the primary's), then pushes the completed
# union back to the primary. After a session both relays hold the union of their
# filtered event sets. Emits one sync_converge metric per session.
sub _converge_once {
  my ($self, %args) = @_;

  my ($primary, $peer) = @args{qw(left right)};
  my $started_at = time;
  my %session    = (rounds => 0, fetched => 0, pushed => 0, error => undef);

  my $ok = eval {
    if (!(defined $peer && length $peer)) {
      die "sync bridge requires a primary and a peer relay\n";
    }
    $self->_converge($primary, $peer, \%session);
    1;
  };
  if (!$ok) {
    my $error = $EVAL_ERROR;
    chomp $error;
    $session{error} = $error || 'sync convergence failed';
  }
  my $finished_at = time;

  $self->emit_metric(
    operation     => 'sync_converge',
    phase         => $args{phase},
    started_at    => $self->iso_timestamp($started_at),
    finished_at   => $self->iso_timestamp($finished_at),
    duration_ms   => ($finished_at - $started_at) * 1000,
    status        => $ok ? 'success' : 'error',
    left_url      => $primary,
    right_url     => $peer // q{},
    rounds        => $session{rounds},
    fetched_count => $session{fetched},
    pushed_count  => $session{pushed},
    ($ok ? () : (error => $session{error})),
  );

  return;
}

# Drive the two relays to the union of their event sets, accumulating a local
# copy and counting the fetch/push traffic into the session.
sub _converge {
  my ($self, $primary, $peer, $session) = @_;

  my %local;

  my (undef, $primary_need) = $self->_reconcile($primary, \%local, $session);
  $self->_absorb(\%local, $session, $self->_fetch($primary, $primary_need));

  my ($peer_have, $peer_need) = $self->_reconcile($peer, \%local, $session);
  $self->_absorb(\%local, $session, $self->_fetch($peer, $peer_need));
  $session->{pushed} += $self->_push($peer, [map { $local{$_} } @{$peer_have}]);

  my ($primary_have, undef) = $self->_reconcile($primary, \%local, $session);
  $session->{pushed} += $self->_push($primary, [map { $local{$_} } @{$primary_have}]);

  return;
}

sub _absorb {
  my ($self, $local, $session, @events) = @_;

  for my $event (@events) {
    $local->{$event->id} = $event;
  }
  $session->{fetched} += scalar @events;

  return;
}

# One bounded client operation against a relay: connect, let $setup register
# handlers and issue the request, then wait for $setup to signal completion by
# sending a defined value to the condvar. Returns that value, or dies with
# $label context on connection failure or timeout (an undef signal).
sub _client_op {
  my ($self, $endpoint, $label, $setup) = @_;

  my $client   = Net::Nostr::Client->new;
  my $done     = AnyEvent->condvar;
  my $deadline = AnyEvent->timer(after => $self->_sync_timeout, cb => sub { $done->send(undef) });

  my $result = eval {
    $client->connect($endpoint);
    $setup->($client, $done);
    $done->recv;
  };
  my $error = $EVAL_ERROR;
  $client->disconnect;

  if (!defined $result) {
    chomp(my $reason = length $error ? $error : 'timed out');
    die "$label $endpoint failed: $reason\n";
  }

  return $result;
}

# One negentropy reconciliation of our local set against a relay. Returns the
# ids we hold that the relay lacks (have) and the ids the relay holds that we
# lack (need). Dies (through _client_op) on connection failure or timeout.
sub _reconcile {
  my ($self, $endpoint, $local, $session) = @_;

  my $negentropy = Net::Nostr::Negentropy->new;
  for my $event (values %{$local}) {
    $negentropy->add_item($event->created_at, $event->id);
  }
  $negentropy->seal;
  my $initial = $negentropy->initiate;

  my $state = {
    negentropy => $negentropy,
    sub_id     => 'burner-' . $self->input->{worker_id} . '-bridge',
    have       => [],
    need       => [],
  };
  $self->_client_op(
    $endpoint,
    'reconcile against',
    sub {
      my ($client, $done) = @_;
      $state->{client} = $client;
      $state->{done}   = $done;
      $client->on(neg_msg => sub { $self->_reconcile_step($state, $_[1]) });
      $client->on(neg_err => sub { $done->send(undef) });
      $client->neg_open($state->{sub_id}, Net::Nostr::Filter->new(%{$self->_sync_filter}), $initial);
    },
  );
  $session->{rounds}++;

  return ($state->{have}, $state->{need});
}

# Fold one relay NEG-MSG into the running reconciliation, continuing while the
# protocol has ranges left to resolve and signalling convergence when done.
sub _reconcile_step {
  my ($self, $state, $response) = @_;

  my ($next, $have, $need) = $state->{negentropy}->reconcile($response);
  push @{$state->{have}}, @{$have};
  push @{$state->{need}}, @{$need};
  if (defined $next) {
    $state->{client}->neg_msg($state->{sub_id}, $next);
  } else {
    $state->{done}->send(1);
  }

  return;
}

# Fetch specific events by id from a relay. Dies (through _client_op) on
# connection failure or timeout so a failed fetch aborts the session.
sub _fetch {
  my ($self, $endpoint, $ids) = @_;

  if (!@{$ids}) {
    return ();
  }

  my %events;
  $self->_client_op(
    $endpoint,
    'fetch from',
    sub {
      my ($client, $done) = @_;
      $client->on(event => sub { $events{$_[1]->id} = $_[1] });
      $client->on(eose  => sub { $done->send(1) });
      $client->subscribe('burner-' . $self->input->{worker_id} . '-fetch', Net::Nostr::Filter->new(ids => [@{$ids}]));
    },
  );

  return values %events;
}

# Publish events to a relay and return how many it acknowledged. Dies (through
# _client_op) on connection failure or timeout.
sub _push {
  my ($self, $endpoint, $events) = @_;

  if (!@{$events}) {
    return 0;
  }

  my %ok;
  $self->_client_op(
    $endpoint,
    'push to',
    sub {
      my ($client, $done) = @_;
      $client->on(
        ok => sub {
          $ok{$_[0]} = $_[1];
          if (keys %ok == @{$events}) {
            $done->send(1);
          }
        }
      );
      for my $event (@{$events}) {
        $client->publish($event);
      }
    },
  );

  return scalar grep { $ok{$_} } keys %ok;
}

sub _sync_bridge_config {
  my ($self) = @_;

  my $phases = $self->phases;
  return ref $phases->[0]{sync_bridge} eq 'HASH' ? $phases->[0]{sync_bridge} : {};
}

sub _sync_interval {
  my ($self) = @_;

  my $interval = $self->_sync_bridge_config->{interval_seconds};
  if (!(defined $interval && $interval > 0)) {
    $interval = 1;
  }

  return $interval;
}

sub _sync_timeout {
  my ($self) = @_;

  my $timeout = $self->_sync_bridge_config->{timeout_seconds};
  if (!(defined $timeout && $timeout > 0)) {
    $timeout = $DEFAULT_SYNC_TIMEOUT;
  }

  return $timeout;
}

sub _sync_filter {
  my ($self) = @_;

  my $filters = $self->_sync_bridge_config->{filters};
  if (ref $filters eq 'ARRAY' && @{$filters} && ref $filters->[0] eq 'HASH') {
    return $filters->[0];
  }

  return {};
}

1;

=head1 NAME

Overnet::Burner::Worker::SyncBridge - negentropy convergence between two relays

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # Invoked by the worker runner from a worker input document.
  Overnet::Burner::Worker::SyncBridge->new(input => $input)->run;

=head1 DESCRIPTION

Converges two relays through NIP-77 negentropy reconciliation. Each session
reconciles an accumulating local set against the primary relay
(C<endpoints.relays[0]>) and the peer relay (C<endpoints.relays[1]>), fetches
the events each relay is missing, and pushes them across so both relays end the
session holding the union of their filtered event sets. See F<docs/workers.md>.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Returns C<sync_bridge>.

=head2 run

Opens the metric stream, signals readiness, and paces one convergence session
per C<sync_bridge.interval_seconds> until the run duration elapses. A C<SIGTERM>
stops the loop.

=head1 METRICS

Each session emits one C<sync_converge> metric with C<duration_ms> (the session
time), C<status>, C<rounds> (negentropy passes), C<fetched_count> (events pulled
from the relays), C<pushed_count> (events uploaded to converge them), and the
C<left_url>/C<right_url> of the reconciled pair.

=head1 DIAGNOSTICS

A topology that gives the bridge fewer than two relays, a relay it cannot
reach, or a session that does not converge within the timeout is an C<error>
metric, not a worker failure.

=head1 CONFIGURATION AND ENVIRONMENT

The C<sync_bridge> workload block configures reconciliation:
C<sync_bridge.interval_seconds> paces sessions (default one second);
C<sync_bridge.filters> selects the reconciled event set (default: all visible
events); C<sync_bridge.timeout_seconds> bounds a single relay exchange before
it is abandoned as an error (default ten seconds).

=head1 DEPENDENCIES

Requires L<Net::Nostr::Client>, L<Net::Nostr::Negentropy>, and L<AnyEvent>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The bridge converges exactly two relays; larger relay graphs are the province
of the planned C<sync-mesh> scenario. Each session reconciles from an empty
local set, so it measures full convergence cost rather than incremental sync.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
