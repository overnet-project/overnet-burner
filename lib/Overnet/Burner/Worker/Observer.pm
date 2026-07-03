package Overnet::Burner::Worker::Observer;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use AnyEvent;
use English qw(-no_match_vars);
use Net::Nostr::Client;
use Net::Nostr::Filter;
use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

my $PROBE_TIMEOUT = 5;

no Moo;

sub expected_role {
  return 'observer';
}

sub run {
  my ($self) = @_;

  my $input     = $self->input;
  my $endpoints = $input->{endpoints}{relays};
  my $interval  = $self->_probe_interval;

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

    for my $endpoint (@{$endpoints}) {
      if ($stop || time >= $deadline) {
        last;
      }
      $self->_ping_once(
        endpoint => $endpoint,
        phase    => $self->phase_name_at(time - $started),
      );
    }
    $tick++;
  }

  $self->close_metric_stream;

  return;
}

sub _probe_interval {
  my ($self) = @_;

  my $phases   = $self->phases;
  my $observer = ref $phases->[0]{observer} eq 'HASH' ? $phases->[0]{observer} : {};
  my $interval = $observer->{probe_interval_seconds};
  if (!(defined $interval && $interval > 0)) {
    $interval = 1;
  }

  return $interval;
}

sub _ping_once {
  my ($self, %args) = @_;

  my $endpoint   = $args{endpoint};
  my $started_at = time;
  my $probed     = eval {
    my $client = Net::Nostr::Client->new;
    my $done   = AnyEvent->condvar;
    my $timer  = AnyEvent->timer(
      after => $PROBE_TIMEOUT,
      cb    => sub { $done->send(0) },
    );
    $client->on(eose => sub { $done->send(1) });
    $client->connect($endpoint);
    $client->subscribe('burner-' . $self->input->{worker_id} . '-ping', Net::Nostr::Filter->new(limit => 0),);
    my $bounded = $done->recv;
    $client->disconnect;

    if (!$bounded) {
      die "relay ping timed out\n";
    }
    1;
  };
  my $finished_at = time;

  my $error;
  if (!$probed) {
    ($error) = split /\n/mxs, ($EVAL_ERROR || 'relay ping failed');
  }

  $self->emit_metric(
    operation   => 'relay_ping',
    phase       => $args{phase},
    started_at  => $self->iso_timestamp($started_at),
    finished_at => $self->iso_timestamp($finished_at),
    duration_ms => ($finished_at - $started_at) * 1000,
    status      => $probed ? 'success' : 'error',
    relay_url   => $endpoint,
    (
      $probed
      ? ()
      : (error => defined $error && length $error ? $error : 'relay ping failed')
    ),
  );

  return;
}

1;

=head1 NAME

Overnet::Burner::Worker::Observer - reference observer worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::Observer;

  my $observer = Overnet::Burner::Worker::Observer->new(input => $input);
  $observer->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<observer> role
under the worker contract in F<docs/workers.md>: the relay-side black-box
evidence producer. Every C<workload.observer.probe_interval_seconds> it
probes every relay endpoint of the run with a fresh connection and an
empty subscription, emitting one C<relay_ping> metric event per endpoint
per tick, measured from opening the connection to the stored-result
boundary. An unreachable relay is an error metric, never an observer
failure: watching relays die is the observer's job, so it declares
readiness immediately and probes through every workload phase, tagging
each event with the phase it ran in. Workers in other languages are
equally valid; the contract documents are normative.

=head1 SUBROUTINES/METHODS

=head2 expected_role

Public API entry point.

=head2 run

Public API entry point.

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; failures of the system under
test are metric events with C<status: error>, not worker failures.

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
