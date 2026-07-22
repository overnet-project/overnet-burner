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
  my $relays   = $input->{endpoints}{relays} || [];
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

    $self->_converge_once(relays => $relays, phase => $self->phase_name_at(time - $started));
    $tick++;
  }

  $self->close_metric_stream;

  return;
}

# One convergence session across the relay set. Starting from an empty local
# copy the bridge folds over the relays twice: the first pass reconciles each
# relay in turn, fetching what it uniquely holds into the growing local copy and
# pushing back what earlier relays contributed; by the last relay the local copy
# is the full union. The second pass revisits every earlier relay to push it the
# union members it still lacked. After a session all relays hold the union of
# their filtered event sets. Emits one sync_converge metric per session. Reduces
# to the classic three-round primary/peer exchange when given exactly two relays.
sub _converge_once {
  my ($self, %args) = @_;

  my $relays     = $args{relays} || [];
  my $started_at = time;
  my %session    = (rounds => 0, fetched => 0, pushed => 0, error => undef);

  my $ok = eval {
    if (@{$relays} < 2) {
      die "sync bridge requires at least two relays\n";
    }
    $self->_converge($relays, \%session);
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
    left_url      => $relays->[0]  // q{},
    right_url     => $relays->[-1] // q{},
    relay_count   => scalar @{$relays},
    rounds        => $session{rounds},
    fetched_count => $session{fetched},
    pushed_count  => $session{pushed},
    ($ok ? () : (error => $session{error})),
  );

  return;
}

# Drive the whole relay set to the union of their event sets, accumulating a
# local copy and counting the fetch/push traffic into the session. The first
# pass reconciles each relay against the growing local copy, fetching what it
# uniquely holds and pushing back what the copy already carries; after it the
# copy is the union and the last relay already holds it. The second pass pushes
# that union to every earlier relay, filling the members each still lacked. For
# two relays this is exactly the primary-pull, peer-reconcile, primary-push
# exchange: three reconciliations, the union fetched, each relay pushed its gap.
sub _converge {
  my ($self, $relays, $session) = @_;

  my %local;

  for my $relay (@{$relays}) {
    my ($have, $need) = $self->_reconcile($relay, \%local, $session);
    $self->_absorb(\%local, $session, $self->_fetch($relay, $need));
    $session->{pushed} += $self->_push($relay, [map { $local{$_} } @{$have}]);
  }

  for my $relay (@{$relays}[0 .. $#{$relays} - 1]) {
    my ($have, undef) = $self->_reconcile($relay, \%local, $session);
    $session->{pushed} += $self->_push($relay, [map { $local{$_} } @{$have}]);
  }

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

Overnet::Burner::Worker::SyncBridge - negentropy convergence across a relay set

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # Invoked by the worker runner from a worker input document.
  Overnet::Burner::Worker::SyncBridge->new(input => $input)->run;

=head1 DESCRIPTION

Converges a set of relays through NIP-77 negentropy reconciliation. Each session
reconciles an accumulating local set against every relay in C<endpoints.relays>
in turn, fetches the events each relay is missing, and pushes them across so all
relays end the session holding the union of their filtered event sets. Two
relays are the pair case (a C<sync-pair> or C<partition-and-recover> bridge);
three or more are a convergence mesh (the C<sync-mesh> scenario). See
F<docs/workers.md>.

The bridge folds over the relays twice. The first pass reconciles each relay
against the growing local copy, fetching what that relay uniquely holds and
pushing back what the copy already carries, so by the last relay the copy is the
full union and that relay already holds it. The second pass revisits every
earlier relay to push it the union members it still lacked. The total cost is
C<2n-1> reconciliations for C<n> relays; for two relays that is exactly the
classic three-round primary-pull, peer-reconcile, primary-push exchange.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Returns C<sync_bridge>.

=head2 run

Opens the metric stream, signals readiness, and paces one convergence session
per C<sync_bridge.interval_seconds> until the run duration elapses. A C<SIGTERM>
stops the loop.

=head1 METRICS

Each session emits one C<sync_converge> metric with C<duration_ms> (the session
time), C<status>, C<rounds> (negentropy passes, C<2n-1> for C<n> relays),
C<fetched_count> (events pulled from the relays), C<pushed_count> (events
uploaded to converge them), C<relay_count> (how many relays were converged), and
C<left_url>/C<right_url> - the first and last relay of the reconciled set (the
same relay pair for the two-relay case).

=head1 DIAGNOSTICS

A topology that gives the bridge fewer than two relays, a relay it cannot
reach, or a session that does not converge within the timeout is an C<error>
metric, not a worker failure. A single unreachable relay in the set fails the
whole session, since the union cannot be completed without it.

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

Each session reconciles from an empty local set, so it measures full convergence
cost rather than incremental sync. The relays converge through the bridge's
local copy as a hub rather than reconciling with each other directly, so the
session cost grows linearly with the relay count rather than modelling an
arbitrary peer-to-peer sync topology.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
