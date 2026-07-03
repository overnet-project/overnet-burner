package Overnet::Burner::Worker::Abuse;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use AnyEvent;
use Carp qw(croak);
use JSON ();
use Net::Nostr::Client;
use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

my $JSON            = JSON->new->utf8->canonical;
my $PUBLISH_TIMEOUT = 5;

my %REJECTED_CATEGORY = (
  invalid         => 'invalid input',
  blocked         => 'policy rejection',
  'rate-limited'  => 'policy rejection',
  pow             => 'policy rejection',
  restricted      => 'authorization failure',
  'auth-required' => 'authentication failure',
  error           => 'internal failure',
);

# Per-role defense model: category is the error category a correct defense
# must use (undef when refusing is itself the correct mechanism);
# duplicate_is_defended lets the replayer treat an explicit duplicate accept
# as a defense. Identity churn (sybil) does not change the flooder's model.
my %DEFENSE_MODEL = (
  flooder             => {category => 'policy rejection'},
  malformed_publisher => {category => 'invalid input'},
  sybil               => {category => 'policy rejection'},
  replayer            => {category => undef, duplicate_is_defended => 1},
  subscription_abuser => {category => undef},
  connection_flood    => {category => undef},
);

no Moo;

sub abuse_operation {
  croak "abuse worker classes must define abuse_operation\n";
}

sub wants_persistent_client {
  return 1;
}

sub teardown_abuse {
  return 1;
}

sub native_event {
  my ($self, $key, $sequence, $text) = @_;

  my $input = $self->input;

  return $key->create_event(
    kind    => 7800,
    content => $JSON->encode(
      {
        provenance => {type => 'native'},
        body       => {text => $text, sequence => $sequence, sent_at => time * 1000},
      }
    ),
    tags => [
      ['overnet_v',   '0.1.0'],
      ['overnet_et',  'burner.publish'],
      ['overnet_ot',  'burner.workload'],
      ['overnet_oid', "burner-$input->{run_id}-$input->{worker_id}"],
      ['v',           '0.1.0'],
      ['t',           'burner.publish'],
      ['o',           'burner.workload'],
    ],
  );
}

sub register_response_handlers {
  my ($self, $client, $pending) = @_;

  # The default publish-abuse flow resolves each pending operation by the
  # relay's OK acknowledgement, keyed by event id.
  $client->on(
    ok => sub {
      my ($event_id, $accepted, $message) = @_;
      my $waiter = delete $pending->{$event_id};
      if ($waiter) {
        $waiter->send([$accepted ? 1 : 0, $message]);
      }
    }
  );

  return 1;
}

sub default_rate {
  return 1;
}

sub build_event {
  croak "abuse worker classes must define build_event\n";
}

sub classify_response {
  my ($class, $accepted, $message) = @_;

  my $text = defined $message ? $message : q{};
  my ($prefix) = $text =~ /\A([a-z][a-z-]*):/mxs;
  $prefix = defined $prefix ? $prefix : q{};

  if ($accepted) {
    return {
      status         => 'success',
      outcome        => 'accepted',
      error_category => undef,
      duplicate      => ($prefix eq 'duplicate' ? 1 : 0),
    };
  }

  return {
    status         => 'error',
    outcome        => ($prefix eq 'auth-required' ? 'unauthorized' : 'rejected'),
    error_category => ($REJECTED_CATEGORY{$prefix} || 'internal failure'),
    duplicate      => 0,
  };
}

sub defense_for {
  my ($class, $role, $classification) = @_;

  if (!exists $DEFENSE_MODEL{$role}) {
    croak "no defense model for abuse role $role\n";
  }
  my $model = $DEFENSE_MODEL{$role};

  # A publish/subscription/connection the relay refused is defended; a
  # replay is also defended when the relay recognized it as a duplicate. The
  # defense is *correct* when the role's required category is met, or
  # unconditionally when refusing is itself the correct mechanism (replays,
  # subscriptions, connections).
  my $accepted = $classification->{outcome} eq 'accepted';
  my $defended = !$accepted || ($model->{duplicate_is_defended} && $classification->{duplicate});
  my $correct =
      !$defended                  ? 0
    : !defined $model->{category} ? 1
    :   (defined $classification->{error_category} && $classification->{error_category} eq $model->{category});

  return {defended => $defended ? 1 : 0, defended_correct => $correct ? 1 : 0};
}

sub run {
  my ($self) = @_;

  my $input = $self->input;
  my $key   = $self->derive_key($input->{seed}, $input->{worker_id});

  $self->open_metric_stream;

  my %pending;
  my $client;
  if ($self->wants_persistent_client) {
    $client = Net::Nostr::Client->new;
    $self->register_response_handlers($client, \%pending);
    $client->connect($input->{endpoints}{relays}[0]);
  }

  $self->write_ready_file;

  my $stop = 0;
  local $SIG{TERM} = sub { $stop = 1 };

  my $started = time;
  $self->{sequence} = 0;
  for my $phase (@{$self->phases}) {
    if ($stop) {
      last;
    }
    $self->_run_phase(
      client  => $client,
      key     => $key,
      pending => \%pending,
      phase   => $phase,
      started => $started,
      stop    => \$stop,
    );
  }

  $self->teardown_abuse;
  if ($client) {
    $client->disconnect;
  }
  $self->close_metric_stream;

  return;
}

sub _run_phase {
  my ($self, %args) = @_;

  my $phase       = $args{phase};
  my $stop        = $args{stop};
  my $phase_start = $args{started} + $phase->{start_seconds};
  my $deadline    = $phase_start + $phase->{duration_seconds};
  my $rate        = $self->_abuse_rate($phase);

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
    $self->_abuse_once(
      client   => $args{client},
      key      => $args{key},
      pending  => $args{pending},
      sequence => ++$self->{sequence},
      phase    => $phase->{name},
    );
  }

  return 1;
}

sub _abuse_rate {
  my ($self, $phase) = @_;

  my $abuse = ref $phase->{abuse} eq 'HASH' ? $phase->{abuse}{$self->expected_role} : undef;
  my $rate  = ref $abuse eq 'HASH'          ? $abuse->{publish_rate_per_second}     : undef;
  if (!defined $rate) {
    return $self->default_rate;
  }

  return 0 + $rate;
}

sub _abuse_once {
  my ($self, %args) = @_;

  my $relay_url = $self->input->{endpoints}{relays}[0];
  my ($accepted, $message, $started_at, $finished_at) = $self->perform_abuse(%args, relay_url => $relay_url);

  my ($classification, $defense) = $self->classify_abuse(
    %args,
    accepted  => $accepted,
    message   => $message,
    relay_url => $relay_url,
  );

  $self->emit_metric(
    operation        => $self->abuse_operation,
    phase            => $args{phase},
    started_at       => $self->iso_timestamp($started_at),
    finished_at      => $self->iso_timestamp($finished_at),
    duration_ms      => ($finished_at - $started_at) * 1000,
    status           => $classification->{status},
    relay_url        => $relay_url,
    outcome          => $classification->{outcome},
    defended         => $defense->{defended}         ? JSON::true : JSON::false,
    defended_correct => $defense->{defended_correct} ? JSON::true : JSON::false,
    (defined $classification->{error_category} ? (error_category => $classification->{error_category}) : ()),
    (
      $classification->{status} eq 'error'
      ? (error => (defined $message && length $message ? $message : 'rejected'))
      : ()
    ),
  );

  return;
}

sub classify_abuse {
  my ($self, %args) = @_;

  # The default abuse flow classifies the relay's own acknowledgement.
  # Roles whose defense lives at a different boundary (for example the
  # provenance verification boundary) override this to classify that
  # boundary's decision instead.
  my $classification = $self->classify_response($args{accepted}, $args{message});
  my $defense        = $self->defense_for($self->expected_role, $classification);

  return ($classification, $defense);
}

sub perform_abuse {
  my ($self, %args) = @_;

  my $event = $self->build_event($args{key}, $args{sequence});

  return $self->publish_event($args{client}, $event, $args{pending});
}

sub publish_event {
  my ($self, $client, $event, $pending) = @_;

  my $waiter = AnyEvent->condvar;
  $pending->{$event->id} = $waiter;
  my $timeout = AnyEvent->timer(
    after => $PUBLISH_TIMEOUT,
    cb    => sub {
      my $timed_out = delete $pending->{$event->id};
      if ($timed_out) {
        $timed_out->send([0, 'error: abuse operation timed out']);
      }
    },
  );

  my $started_at = time;
  my $sent       = eval {
    $client->publish($event);
    1;
  };
  my ($accepted, $message);
  if ($sent) {
    ($accepted, $message) = @{$waiter->recv};
  } else {
    delete $pending->{$event->id};
    ($accepted, $message) = (0, 'error: relay connection lost');
  }

  return ($accepted, $message, $started_at, time);
}

1;

=head1 NAME

Overnet::Burner::Worker::Abuse - shared base for adversarial workers

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  package Overnet::Burner::Worker::Flooder;
  use Moo;
  extends 'Overnet::Burner::Worker::Abuse';

  sub expected_role   { 'flooder' }
  sub abuse_operation { 'flood_publish' }
  sub build_event     { ... }

=head1 DESCRIPTION

Shared plumbing for the Perl reference abuse workers under the contract in
F<docs/abuse.md>: relay connection, paced abuse operations, and the honest
classification of each relay response. C<classify_response> maps a Nostr
C<OK> acknowledgement (the machine-readable NIP-01 prefixes C<invalid:>,
C<blocked:>, C<rate-limited:>, C<pow:>, C<restricted:>, C<auth-required:>,
C<error:>, C<duplicate:>) onto the Overnet core outcome and error
categories, and C<defense_for> decides, per role, whether the relay
defended itself and whether it used the spec-correct semantics. Each
metric event records that ground truth through the C<outcome>,
C<error_category>, C<defended>, and C<defended_correct> members.

Abuse targets only the relay endpoints named in the worker input, which the
runner draws from the run's own topology; these workers are red-teaming a
deployment's own defenses, never third-party relays.

=head1 SUBROUTINES/METHODS

=head2 classify_response

=head2 classify_abuse

=head2 defense_for

=head2 register_response_handlers

=head2 wants_persistent_client

=head2 teardown_abuse

=head2 native_event

=head2 abuse_operation

=head2 default_rate

=head2 build_event

=head2 perform_abuse

=head2 publish_event

=head2 run

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a relay that rejects or limits
the abuse is a metric event, not a worker failure.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration arrives through the worker input document; see
F<docs/workers.md> and F<docs/abuse.md>.

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
