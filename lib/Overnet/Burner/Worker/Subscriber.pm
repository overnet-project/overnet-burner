package Overnet::Burner::Worker::Subscriber;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use AnyEvent;
use Carp    qw(croak);
use English qw(-no_match_vars);
use JSON    ();
use Net::Nostr::Client;
use Net::Nostr::Filter;
use Time::HiRes qw(time);

our $VERSION = '0.001';

no Moo;

sub expected_role {
  return 'subscriber';
}

sub run {
  my ($self) = @_;

  my $input   = $self->input;
  my $filters = $input->{workload}{subscription_filters};
  if (!(ref($filters) eq 'ARRAY' && @{$filters})) {
    croak "subscriber requires workload.subscription_filters\n";
  }

  $self->open_metric_stream;

  $self->{workload_started} = time;
  my $relay_url       = $input->{endpoints}{relays}[0];
  my $subscription_id = "burner-$input->{worker_id}";
  my @filter_objects  = map { Net::Nostr::Filter->new(%{$_}) } @{$filters};
  my $replay_done     = 0;
  my $ready_written   = 0;
  my $reconnecting    = 0;
  my $done            = AnyEvent->condvar;

  my $client = Net::Nostr::Client->new;
  $client->on(
    eose => sub {
      $replay_done = 1;
      if (!$ready_written) {
        $ready_written = 1;
        $self->write_ready_file;
      }
    }
  );
  $client->on(
    event => sub {
      my (undef, $event) = @_;
      if (!$replay_done) {
        return;
      }
      $self->_measure_fanout(
        event           => $event,
        subscription_id => $subscription_id,
        received_at     => time,
      );
    }
  );
  $client->connect($relay_url);
  $client->subscribe($subscription_id, @filter_objects);

  my $reconnect_watchdog = AnyEvent->timer(
    after    => 0.25,
    interval => 0.25,
    cb       => sub {
      if ($client->is_connected || $reconnecting) {
        return;
      }
      $reconnecting = 1;
      $replay_done  = 0;
      $client->connect(
        $relay_url,
        sub {
          my ($error) = @_;
          $reconnecting = 0;
          if (!$error) {
            my $resubscribed = eval {
              $client->subscribe($subscription_id, @filter_objects);
              1;
            };
          }
          return;
        }
      );
    },
  );

  local $SIG{TERM} = sub { $done->send };
  my $deadline = AnyEvent->timer(
    after => $input->{duration_seconds},
    cb    => sub { $done->send },
  );
  $done->recv;

  $client->disconnect;
  $self->close_metric_stream;

  return;
}

sub _measure_fanout {
  my ($self, %args) = @_;

  my $event   = $args{event};
  my $content = eval { JSON::decode_json($event->content) };
  my $sent_at_ms =
    ref($content) eq 'HASH' && ref($content->{body}) eq 'HASH' ? $content->{body}{sent_at} : undef;
  if (!(defined $sent_at_ms && !ref($sent_at_ms) && $sent_at_ms =~ /\A[0-9]+(?:[.][0-9]+)?\z/mxs)) {
    return;
  }

  my $received_ms = $args{received_at} * 1000;
  my $duration_ms = $received_ms - $sent_at_ms;
  if ($duration_ms < 0) {
    $duration_ms = 0;
  }

  $self->emit_metric(
    operation       => 'subscription_fanout',
    phase           => $self->phase_name_at($args{received_at} - $self->{workload_started}),
    started_at      => $self->iso_timestamp($sent_at_ms / 1000),
    finished_at     => $self->iso_timestamp($args{received_at}),
    duration_ms     => $duration_ms,
    status          => 'success',
    event_id        => $event->id,
    subscription_id => $args{subscription_id},
    relay_url       => $self->input->{endpoints}{relays}[0],
  );

  return;
}

1;

=head1 NAME

Overnet::Burner::Worker::Subscriber - reference subscriber worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::Subscriber;

  my $subscriber = Overnet::Burner::Worker::Subscriber->new(input => $input);
  $subscriber->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<subscriber> role
under the worker contract in F<docs/workers.md>. It subscribes to the first
configured relay endpoint with the workload's subscription filters, writes
its readiness marker only after the stored-event replay boundary (C<EOSE>),
and emits one C<subscription_fanout> metric event for every live event whose
body carries a millisecond C<sent_at> stamp, measuring receive time against
that stamp. Events without a stamp are observed but not measured, because a
fanout latency that guesses its own start time is a lie.

If the relay connection is lost mid-workload the subscriber keeps trying to
reconnect and resubscribe for the rest of its duration, re-establishing the
replay boundary each time: deliveries after a reconnect are treated as
stored replay until the next C<EOSE>, so a replayed stamped event is never
measured against its original C<sent_at>. Workers in other languages are
equally valid; the contract documents are normative.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Public API entry point.

=head2 run

Public API entry point.

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration arrives through the worker input document; see
F<docs/workers.md>.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Fanout timing compares clocks across worker processes; it is trustworthy on
a single host and requires disciplined clock synchronization in distributed
mode.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
