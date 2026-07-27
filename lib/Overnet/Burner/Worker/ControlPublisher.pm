package Overnet::Burner::Worker::ControlPublisher;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use AnyEvent;
use Carp    qw(croak);
use English qw(-no_match_vars);
use JSON    ();
use Net::Nostr::Client;
use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

my $PUBLISH_TIMEOUT    = 5;
my $DEFAULT_GRANT_KIND = 14_142;
my $GRANT_TTL_SECONDS  = 3600;
my $OPERATOR_ROLE      = 'irc.operator';
my $PUT_USER_KIND      = 9_000;

no Moo;

sub expected_role {
  return 'control_publisher';
}

sub run {
  my ($self) = @_;

  my $input = $self->input;

  # Two distinct deterministic identities: the authority/actor key that signs
  # the delegation grant, and the delegated session key that signs the control
  # events. The relay requires the two to differ.
  $self->{authority_key} = $self->derive_key($input->{seed}, "$input->{worker_id}/authority");
  $self->{session_key}   = $self->derive_key($input->{seed}, "$input->{worker_id}/session");

  my $control = ref $input->{workload}{control} eq 'HASH' ? $input->{workload}{control} : {};
  $self->{relay_url}  = $control->{relay_url}  // $input->{endpoints}{relays}[0];
  $self->{grant_kind} = $control->{grant_kind} // $DEFAULT_GRANT_KIND;
  $self->{group}      = $control->{group}      // "burner-$input->{run_id}-$input->{worker_id}";
  $self->{scope}      = $control->{scope}      // "overnet-burner://$input->{run_id}";
  $self->{session_id} = "$input->{worker_id}-session";

  $self->open_metric_stream;

  my %pending;
  my $client = Net::Nostr::Client->new;
  $client->on(
    ok => sub {
      my ($event_id, $accepted, $message) = @_;
      my $waiter = delete $pending{$event_id};
      if ($waiter) {
        $waiter->send([$accepted ? 1 : 0, $message]);
      }
    }
  );
  $client->connect($input->{endpoints}{relays}[0]);

  $self->{sequence} = 0;

  # Establish authority before declaring readiness: publish the delegation grant
  # and install the actor as the group operator. A relay that refuses the
  # bootstrap is a misconfigured target (wrong grant kind, or a relay whose
  # relay-url does not match the endpoint), which the worker cannot generate
  # authorized load against -- a fatal worker failure, not a metric.
  my ($ok, $reason) = $self->_establish_authority($client, \%pending);
  if (!$ok) {
    $client->disconnect;
    croak "control_publisher could not establish its delegated authority: $reason\n";
  }

  $self->write_ready_file;

  my $stop = 0;
  local $SIG{TERM} = sub { $stop = 1 };

  my $started = time;
  for my $phase (@{$self->phases}) {
    if ($stop) {
      last;
    }
    $self->_run_phase(
      client  => $client,
      pending => \%pending,
      phase   => $phase,
      started => $started,
      stop    => \$stop,
    );
  }

  $client->disconnect;
  $self->close_metric_stream;

  return;
}

# Publish the delegation grant (kind grant_kind, signed by the authority key,
# delegating to the session key and bound to this relay) and the initial
# operator put-user (kind 9000, signed by the session key, granting the
# authority key the operator role). On an empty group the relay accepts the
# operator self-grant, so afterward the actor is a retained operator and every
# subsequent control event authorizes against that role. Records the grant's
# event id, which each control event references as its authority.
sub _establish_authority {
  my ($self, $client, $pending) = @_;

  my $grant = $self->_grant_event;
  my ($grant_ok, $grant_reason) = $self->_publish_and_wait($client, $pending, $grant);
  if (!$grant_ok) {
    return (0, 'delegation grant rejected: ' . _reason($grant_reason, 'no reason given'));
  }
  $self->{grant_id} = $grant->id;

  my $bootstrap = $self->_put_user_event($self->{authority_key}->pubkey_hex, $OPERATOR_ROLE);
  my ($op_ok, $op_reason) = $self->_publish_and_wait($client, $pending, $bootstrap);
  if (!$op_ok) {
    return (0, 'operator bootstrap rejected: ' . _reason($op_reason, 'no reason given'));
  }

  return (1, undef);
}

sub _run_phase {
  my ($self, %args) = @_;

  my $phase       = $args{phase};
  my $stop        = $args{stop};
  my $phase_start = $args{started} + $phase->{start_seconds};
  my $deadline    = $phase_start + $phase->{duration_seconds};
  my $rate        = $self->phase_rate($phase, 'publish_rate_per_second');

  if ($rate == 0) {
    return $self->idle_until($deadline, $stop);
  }

  my $paced = 0;
  while (!${$stop} && time < $deadline) {
    my $scheduled = $phase_start + $paced / $rate;
    if ($scheduled >= $deadline) {
      last;
    }
    my $wait = $scheduled - time;
    if ($wait > 0) {
      sleep $wait;
    }
    if (${$stop} || time >= $deadline) {
      last;
    }

    $paced++;
    $self->_publish_control_once(
      client   => $args{client},
      pending  => $args{pending},
      sequence => ++$self->{sequence},
      phase    => $phase->{name},
    );
  }

  return 1;
}

sub _publish_control_once {
  my ($self, %args) = @_;

  my $relay_url = $self->{relay_url};

  if ( !$args{client}->is_connected
    && !$self->_reconnect(client => $args{client}, pending => $args{pending}, phase => $args{phase})) {
    return;
  }

  # Each control operation is an authorized put-user adding a fresh synthetic
  # member. The relay must verify the delegation grant and the actor's operator
  # role for every event, so the load exercises the whole authorization path;
  # the growing member set makes each derivation progressively heavier, the way
  # a real busy channel would.
  my $member = $self->derive_key($self->input->{seed}, "$self->{group}/member/$args{sequence}");
  my $event  = $self->_put_user_event($member->pubkey_hex, undef);

  my $started_at = time;
  my ($accepted, $message) = $self->_publish_and_wait($args{client}, $args{pending}, $event);
  my $finished_at = time;

  $self->emit_metric(
    operation    => 'control_publish',
    phase        => $args{phase},
    started_at   => $self->iso_timestamp($started_at),
    finished_at  => $self->iso_timestamp($finished_at),
    duration_ms  => ($finished_at - $started_at) * 1000,
    status       => $accepted ? 'success' : 'error',
    event_id     => $event->id,
    control_kind => $PUT_USER_KIND,
    relay_url    => $relay_url,
    (
      $accepted
      ? ()
      : (error => defined $message && length $message ? $message : 'control event rejected')
    ),
  );

  return;
}

# Reconnect and re-establish authority. A relay restart drops its in-memory
# store, so the grant and operator role are gone; re-publishing them restores
# the authority the subsequent control events depend on. A reconnect that
# cannot re-establish authority records the operation as an error and keeps
# trying for the rest of the workload, per the worker contract's connection
# loss rules.
sub _reconnect {
  my ($self, %args) = @_;

  my $relay_url  = $self->{relay_url};
  my $started_at = time;

  my $connected = eval {
    $args{client}->connect($self->input->{endpoints}{relays}[0]);
    1;
  };
  my ($ok, $reason);
  if ($connected) {
    ($ok, $reason) = $self->_establish_authority($args{client}, $args{pending});
  } else {
    ($ok, $reason) = (0, 'relay connection lost and reconnect failed');
  }
  if ($ok) {
    return 1;
  }

  $self->emit_metric(
    operation    => 'control_publish',
    phase        => $args{phase},
    started_at   => $self->iso_timestamp($started_at),
    finished_at  => $self->iso_timestamp(time),
    duration_ms  => (time - $started_at) * 1000,
    status       => 'error',
    control_kind => $PUT_USER_KIND,
    relay_url    => $relay_url,
    error        => _reason($reason, 'relay connection lost and reconnect failed'),
  );

  return 0;
}

sub _publish_and_wait {
  my ($self, $client, $pending, $event) = @_;

  my $waiter = AnyEvent->condvar;
  $pending->{$event->id} = $waiter;
  my $timeout = AnyEvent->timer(
    after => $PUBLISH_TIMEOUT,
    cb    => sub {
      my $timed_out = delete $pending->{$event->id};
      if ($timed_out) {
        $timed_out->send([0, 'control event timed out']);
      }
    },
  );

  my $sent = eval {
    $client->publish($event);
    1;
  };
  if (!$sent) {
    delete $pending->{$event->id};
    return (0, 'relay connection lost');
  }

  return @{$waiter->recv};
}

sub _grant_event {
  my ($self) = @_;

  my $expires_at = int(time) + $GRANT_TTL_SECONDS;

  return $self->{authority_key}->create_event(
    kind    => $self->{grant_kind},
    content => q{},
    tags    => [
      ['relay',      $self->{relay_url}],
      ['server',     $self->{scope}],
      ['delegate',   $self->{session_key}->pubkey_hex],
      ['session',    $self->{session_id}],
      ['expires_at', "$expires_at"],
    ],
  );
}

# A delegated NIP-29 put-user (kind 9000) signed by the session key: it names
# the authority actor and the grant that delegates to this session, targets the
# group, and grants the target pubkey the given role (an operator role for the
# bootstrap self-grant, or no role for a plain member).
sub _put_user_event {
  my ($self, $target_pubkey, $role) = @_;

  return $self->{session_key}->create_event(
    kind    => $PUT_USER_KIND,
    content => q{},
    tags    => [
      ['h',                 $self->{group}],
      ['overnet_actor',     $self->{authority_key}->pubkey_hex],
      ['overnet_authority', $self->{grant_id}],
      ['overnet_sequence',  "$self->{sequence}"],
      (defined $role ? ['p', $target_pubkey, $role] : ['p', $target_pubkey]),
    ],
  );
}

sub _reason {
  my ($reason, $default) = @_;

  return defined $reason && length $reason ? $reason : $default;
}

1;

=head1 NAME

Overnet::Burner::Worker::ControlPublisher - authorized NIP-29 control-load worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::ControlPublisher;

  my $worker = Overnet::Burner::Worker::ControlPublisher->new(input => $input);
  $worker->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<control_publisher>
role under the worker contract in F<docs/workers.md>. Unlike the C<publisher>,
whose ordinary content events an authority relay accepts from anyone, the
control publisher generates the load an Overnet B<authority> relay actually
gates: delegated NIP-29 group-control traffic that the relay must authorize per
event.

At startup, before declaring readiness, it establishes its own authority
entirely peer-to-relay -- no IRC frontend required. It derives two
deterministic identities (an authority/actor key and a delegated session key),
publishes a delegation grant (kind C<grant_kind>, default 14142) that binds the
session key to this relay, then publishes an initial operator put-user
(kind 9000) that the relay accepts as the empty group's operator self-grant.
From then on the actor is a retained operator.

Its workload is a stream of authorized put-user (kind 9000) control events, each
adding a fresh synthetic member, paced by C<workload.publish_rate_per_second>.
The relay verifies the delegation grant and the actor's operator role for every
event, so the load measures the authorization path -- and because the member
set grows, each authorization derivation gets heavier, as a busy channel's
would. Each attempt is one C<control_publish> metric event: C<success> on
acceptance, C<error> with the relay's reason on rejection or timeout.

If the relay connection is lost mid-workload the worker reconnects and
re-establishes its authority (the grant and operator role, which a restarted
relay's fresh store no longer holds) before resuming, recording affected
operations as C<error> metric events per the worker contract's connection loss
rules. Workers in other languages are equally valid; the contract documents are
normative.

=head2 Authority parameters

C<workload.control> may carry C<grant_kind>, C<group>, C<scope>, and
C<relay_url>; each defaults sensibly (grant kind 14142, a run-and-worker-scoped
group and scope, and the first relay endpoint). The grant's C<relay> tag must
byte-match the target relay's configured relay-url, so C<relay_url> defaults to
the endpoint the worker connects to.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Public API entry point.

=head2 run

Public API entry point.

=head1 DIAGNOSTICS

A relay that refuses the startup authority bootstrap is a fatal worker failure
raised via C<croak> (a misconfigured target the worker cannot load-test);
failures of the system under test mid-workload are metric events with
C<status: error>, not worker failures.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration arrives through the worker input document; see
F<docs/workers.md>.

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
