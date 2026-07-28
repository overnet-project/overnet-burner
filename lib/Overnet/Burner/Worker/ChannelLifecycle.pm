package Overnet::Burner::Worker::ChannelLifecycle;

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

my $PUT_USER_KIND       = 9_000;
my $REMOVE_USER_KIND    = 9_001;
my $EDIT_METADATA_KIND  = 9_002;
my $GROUP_METADATA_KIND = 39_000;
my $CHAT_KIND           = 9;

my $DEFAULT_MEMBERS_PER_CYCLE  = 3;
my $DEFAULT_MESSAGES_PER_CYCLE = 3;
my $DEFAULT_BANS_PER_CYCLE     = 1;

no Moo;

sub expected_role {
  return 'channel_lifecycle';
}

sub run {
  my ($self) = @_;

  my $input = $self->input;

  # Two distinct deterministic identities, as the relay requires: the
  # authority/actor key that signs the delegation grant, and the delegated
  # session key that signs every authoritative write.
  $self->{authority_key} = $self->derive_key($input->{seed}, "$input->{worker_id}/authority");
  $self->{session_key}   = $self->derive_key($input->{seed}, "$input->{worker_id}/session");

  my $control = ref $input->{workload}{control} eq 'HASH' ? $input->{workload}{control} : {};
  $self->{relay_url}  = $control->{relay_url}  // $input->{endpoints}{relays}[0];
  $self->{grant_kind} = $control->{grant_kind} // $DEFAULT_GRANT_KIND;
  $self->{group}      = $control->{group}      // "burner-$input->{run_id}-$input->{worker_id}";
  $self->{scope}      = $control->{scope}      // "overnet-burner://$input->{run_id}";
  $self->{session_id} = "$input->{worker_id}-session";

  my $lifecycle = ref $input->{workload}{lifecycle} eq 'HASH' ? $input->{workload}{lifecycle} : {};
  $self->{channel_name}       = $lifecycle->{channel_name}       // "#$self->{group}";
  $self->{members_per_cycle}  = $lifecycle->{members_per_cycle}  // $DEFAULT_MEMBERS_PER_CYCLE;
  $self->{messages_per_cycle} = $lifecycle->{messages_per_cycle} // $DEFAULT_MESSAGES_PER_CYCLE;
  $self->{bans_per_cycle}     = $lifecycle->{bans_per_cycle}     // $DEFAULT_BANS_PER_CYCLE;

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
  $self->{members}  = [];
  $self->{cycle}    = 0;

  # Establish authority before declaring readiness. A relay that refuses the
  # bootstrap is a misconfigured target the worker cannot drive at all, which is
  # a fatal worker failure rather than a metric.
  my ($ok, $reason) = $self->_establish_authority($client, \%pending);
  if (!$ok) {
    $client->disconnect;
    croak "channel_lifecycle could not establish its delegated authority: $reason\n";
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

sub _establish_authority {
  my ($self, $client, $pending) = @_;

  my $grant = $self->_grant_event;
  my ($grant_ok, $grant_reason) = $self->_publish_and_wait($client, $pending, $grant);
  if (!$grant_ok) {
    return (0, 'delegation grant rejected: ' . _reason($grant_reason, 'no reason given'));
  }
  $self->{grant_id} = $grant->id;

  my $bootstrap = $self->_control_event(
    kind => $PUT_USER_KIND,
    tags => [['p', $self->{authority_key}->pubkey_hex, $OPERATOR_ROLE]],
  );
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
    $self->_run_step(
      client  => $args{client},
      pending => $args{pending},
      phase   => $phase->{name},
    );
  }

  return 1;
}

# The lifecycle is an ordered script, not a uniform stream: each paced tick
# performs the next operation a real channel operator would perform, so the
# relay sees a realistic ordering (a channel is created before members are
# added, members chat before they are banned, settings change over the
# channel's life). The script repeats, each repetition being one cycle.
sub _steps_for_cycle {
  my ($self) = @_;

  my @steps = (
    ($self->{cycle} == 0 ? ({step => 'create_channel'}) : ()),
    (map { {step => 'add_user'} } 1 .. $self->{members_per_cycle}),
    (map { {step => 'chat'} } 1 .. $self->{messages_per_cycle}),
    (map { {step => 'ban'} } 1 .. $self->{bans_per_cycle}),
    {step => 'edit_settings'},
  );

  return \@steps;
}

sub _run_step {
  my ($self, %args) = @_;

  if ( !$args{client}->is_connected
    && !$self->_reconnect(client => $args{client}, pending => $args{pending}, phase => $args{phase})) {
    return;
  }

  if (!$self->{queue} || !@{$self->{queue}}) {
    $self->{queue} = $self->_steps_for_cycle;
    $self->{cycle}++;
  }
  my $next = shift @{$self->{queue}};

  my $step  = $next->{step};
  my $event = $self->_event_for_step($step);
  if (!$event) {
    return;
  }

  my $started_at = time;
  my ($accepted, $message) = $self->_publish_and_wait($args{client}, $args{pending}, $event);
  my $finished_at = time;

  $self->emit_metric(
    operation      => 'channel_lifecycle',
    lifecycle_step => $step,
    phase          => $args{phase},
    started_at     => $self->iso_timestamp($started_at),
    finished_at    => $self->iso_timestamp($finished_at),
    duration_ms    => ($finished_at - $started_at) * 1000,
    status         => $accepted ? 'success' : 'error',
    event_id       => $event->id,
    control_kind   => $event->kind,
    group          => $self->{group},
    relay_url      => $self->{relay_url},
    (
      $accepted
      ? ()
      : (error => defined $message && length $message ? $message : 'lifecycle event rejected')
    ),
  );

  return;
}

# Build the event for one lifecycle step. Returns undef when a step has nothing
# to do (a ban with no member left to remove), which the caller skips.
sub _event_for_step {
  my ($self, $step) = @_;

  if ($step eq 'create_channel') {
    return $self->_create_channel_event;
  }
  if ($step eq 'add_user') {
    return $self->_add_user_event;
  }
  if ($step eq 'chat') {
    return $self->_chat_event;
  }
  if ($step eq 'ban') {
    return $self->_ban_event;
  }
  if ($step eq 'edit_settings') {
    return $self->_edit_settings_event;
  }

  croak "unknown lifecycle step: $step\n";
}

# Channel creation: a delegated kind-39000 group metadata write, which the
# relay accepts from a current channel operator (the role the bootstrap
# established). The 'd' tag binds the metadata to the group.
sub _create_channel_event {
  my ($self) = @_;

  $self->{sequence}++;
  return $self->{session_key}->create_event(
    kind    => $GROUP_METADATA_KIND,
    content => q{},
    tags    => [
      ['d',                 $self->{group}],
      ['overnet_actor',     $self->{authority_key}->pubkey_hex],
      ['overnet_authority', $self->{grant_id}],
      ['overnet_sequence',  "$self->{sequence}"],
      ['name',              $self->{channel_name}],
      ['about',             "burner lifecycle channel $self->{group}"],
    ],
  );
}

sub _add_user_event {
  my ($self) = @_;

  # The ordinal must advance monotonically, never track the current member
  # count: bans shrink the member list, so a count-derived ordinal would
  # re-derive an identity that was already admitted (and possibly already
  # banned), silently turning distinct-member load into repeated re-adds of the
  # same pubkey.
  $self->{member_ordinal} = ($self->{member_ordinal} // 0) + 1;
  my $member = $self->derive_key($self->input->{seed}, "$self->{group}/member/$self->{member_ordinal}");
  push @{$self->{members}}, $member;

  return $self->_control_event(
    kind => $PUT_USER_KIND,
    tags => [['p', $member->pubkey_hex]],
  );
}

# Channel chat: an ordinary NIP-29 kind-9 message scoped to the group. An
# authority relay does not gate content kinds, so this is the traffic that
# flows alongside the gated control plane rather than through it.
sub _chat_event {
  my ($self) = @_;

  $self->{message_ordinal} = ($self->{message_ordinal} // 0) + 1;
  my $speaker =
    @{$self->{members}}
    ? $self->{members}[$self->{message_ordinal} % scalar @{$self->{members}}]
    : $self->{session_key};

  return $speaker->create_event(
    kind    => $CHAT_KIND,
    content => "burner lifecycle message $self->{message_ordinal} in $self->{channel_name}",
    tags    => [['h', $self->{group}]],
  );
}

# A ban is the authoritative exclusion mechanism: kind-9001 pubkey removal.
# Bans consume the oldest member still present, so a cycle's added members are
# the ones later removed.
sub _ban_event {
  my ($self) = @_;

  if (!@{$self->{members}}) {
    return;
  }
  my $victim = shift @{$self->{members}};

  return $self->_control_event(
    kind => $REMOVE_USER_KIND,
    tags => [['p', $victim->pubkey_hex]],
  );
}

# Changing channel settings: a kind-9002 edit-metadata control write. The
# settings change each cycle so successive writes are observably distinct.
sub _edit_settings_event {
  my ($self) = @_;

  return $self->_control_event(
    kind => $EDIT_METADATA_KIND,
    tags => [['name', $self->{channel_name}], ['about', "burner lifecycle channel, cycle $self->{cycle}"],],
  );
}

# A delegated NIP-29 control event: signed by the session key, naming the
# authority actor and the grant that delegates to this session, and bound to
# the group by its 'h' tag.
sub _control_event {
  my ($self, %args) = @_;

  $self->{sequence}++;

  return $self->{session_key}->create_event(
    kind    => $args{kind},
    content => q{},
    tags    => [
      ['h',                 $self->{group}],
      ['overnet_actor',     $self->{authority_key}->pubkey_hex],
      ['overnet_authority', $self->{grant_id}],
      ['overnet_sequence',  "$self->{sequence}"],
      @{$args{tags}},
    ],
  );
}

sub _reconnect {
  my ($self, %args) = @_;

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
    operation      => 'channel_lifecycle',
    lifecycle_step => 'reconnect',
    phase          => $args{phase},
    started_at     => $self->iso_timestamp($started_at),
    finished_at    => $self->iso_timestamp(time),
    duration_ms    => (time - $started_at) * 1000,
    status         => 'error',
    group          => $self->{group},
    relay_url      => $self->{relay_url},
    error          => _reason($reason, 'relay connection lost and reconnect failed'),
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
        $timed_out->send([0, 'lifecycle event timed out']);
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

sub _reason {
  my ($reason, $default) = @_;

  return defined $reason && length $reason ? $reason : $default;
}

1;

=head1 NAME

Overnet::Burner::Worker::ChannelLifecycle - authoritative channel lifecycle worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::ChannelLifecycle;

  my $worker = Overnet::Burner::Worker::ChannelLifecycle->new(input => $input);
  $worker->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<channel_lifecycle>
role under the worker contract in F<docs/workers.md>. Where the
C<control_publisher> streams one repeated control operation to measure the
authorization path under uniform load, this worker drives the B<ordered
lifecycle of a hosted channel> the way an operator and its members would: it
creates the channel, admits members, carries chat traffic, bans members, and
changes channel settings, then repeats.

The ordering is the point. A channel is created before members are admitted,
members speak before they are banned, and settings change over the channel's
life, so the relay sees state transitions in a realistic sequence rather than a
uniform stream of identical writes.

At startup, before declaring readiness, it establishes its authority
peer-to-relay exactly as the control publisher does: it derives an
authority/actor key and a delegated session key, publishes a delegation grant
(kind C<grant_kind>, default 14142) binding the session key to this relay, and
publishes an operator put-user (kind 9000) that the relay accepts as the empty
group's operator self-grant.

=head2 Lifecycle steps

Each paced tick performs the next step of the script:

=over

=item C<create_channel>

A delegated kind-39000 group metadata write, accepted from a current channel
operator. Performed once, on the first cycle.

=item C<add_user>

A kind-9000 put-user admitting a fresh deterministic member.

=item C<chat>

An ordinary NIP-29 kind-9 message scoped to the group, signed by an admitted
member. Content kinds are not gated by an authority relay, so this is the
traffic that flows alongside the control plane rather than through it.

=item C<ban>

A kind-9001 pubkey removal, the authoritative exclusion mechanism, consuming
the oldest member still present.

=item C<edit_settings>

A kind-9002 edit-metadata write changing the channel's settings.

=back

Each attempt is one C<channel_lifecycle> metric event carrying the
C<lifecycle_step> and the C<control_kind> actually published: C<success> on
acceptance, C<error> with the relay's reason on rejection or timeout. On a lost
connection the worker reconnects and re-establishes its authority before
resuming, per the worker contract's connection loss rules.

=head2 Parameters

C<workload.control> carries the authority parameters (C<grant_kind>, C<group>,
C<scope>, C<relay_url>) exactly as for the control publisher.
C<workload.lifecycle> may carry C<channel_name>, C<members_per_cycle>,
C<messages_per_cycle>, and C<bans_per_cycle>; each defaults sensibly.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Public API entry point.

=head2 run

Public API entry point.

=head1 DIAGNOSTICS

A relay that refuses the startup authority bootstrap is a fatal worker failure
raised via C<croak>; failures of the system under test mid-workload are metric
events with C<status: error>, not worker failures.

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
