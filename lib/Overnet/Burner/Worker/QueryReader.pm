package Overnet::Burner::Worker::QueryReader;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use AnyEvent;
use Carp    qw(croak);
use English qw(-no_match_vars);
use Net::Nostr::Client;
use Net::Nostr::Filter;
use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

my $QUERY_TIMEOUT = 5;

no Moo;

sub expected_role {
  return 'query_reader';
}

sub run {
  my ($self) = @_;

  my $input   = $self->input;
  my $filters = $input->{workload}{query_filters};
  if (!(ref($filters) eq 'ARRAY' && @{$filters})) {
    croak "query_reader requires workload.query_filters\n";
  }
  my @filters = map { Net::Nostr::Filter->new(%{$_}) } @{$filters};

  $self->open_metric_stream;

  my %pending;
  my $client = Net::Nostr::Client->new;
  $client->on(
    event => sub {
      my ($subscription_id) = @_;
      my $query = $pending{$subscription_id};
      if ($query) {
        $query->{result_count}++;
      }
    }
  );
  $client->on(
    eose => sub {
      my ($subscription_id) = @_;
      my $query = $pending{$subscription_id};
      if ($query) {
        $query->{waiter}->send(1);
      }
    }
  );
  $client->connect($input->{endpoints}{relays}[0]);

  $self->write_ready_file;

  my $stop = 0;
  local $SIG{TERM} = sub { $stop = 1 };

  my $rate = 0 + ($input->{workload}{query_rate_per_second} || 1);
  if ($rate <= 0) {
    $rate = 1;
  }
  my $started  = time;
  my $deadline = $started + $input->{duration_seconds};
  my $sequence = 0;

  while (!$stop && time < $deadline) {
    my $scheduled = $started + $sequence / $rate;
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

    $sequence++;
    $self->_query_once(
      client   => $client,
      filters  => \@filters,
      pending  => \%pending,
      sequence => $sequence,
    );
  }

  $client->disconnect;
  $self->close_metric_stream;

  return;
}

sub _query_once {
  my ($self, %args) = @_;

  my $input           = $self->input;
  my $subscription_id = "burner-$input->{worker_id}-q$args{sequence}";

  my $waiter = AnyEvent->condvar;
  $args{pending}{$subscription_id} = {
    result_count => 0,
    waiter       => $waiter,
  };
  my $timeout = AnyEvent->timer(
    after => $QUERY_TIMEOUT,
    cb    => sub { $waiter->send(0) },
  );

  my $started_at = time;
  $args{client}->subscribe($subscription_id, @{$args{filters}});
  my $bounded     = $waiter->recv;
  my $finished_at = time;

  my $query = delete $args{pending}{$subscription_id};
  $args{client}->close($subscription_id);

  $self->emit_metric(
    operation       => 'query',
    started_at      => $self->iso_timestamp($started_at),
    finished_at     => $self->iso_timestamp($finished_at),
    duration_ms     => ($finished_at - $started_at) * 1000,
    status          => $bounded ? 'success' : 'error',
    subscription_id => $subscription_id,
    relay_url       => $input->{endpoints}{relays}[0],
    (
      $bounded
      ? (result_count => $query->{result_count})
      : (error => 'query timed out')
    ),
  );

  return;
}

1;

=head1 NAME

Overnet::Burner::Worker::QueryReader - reference query reader worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::QueryReader;

  my $reader = Overnet::Burner::Worker::QueryReader->new(input => $input);
  $reader->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<query_reader> role
under the worker contract in F<docs/workers.md>. It issues the workload's
C<query_filters> against the first configured relay endpoint at
C<workload.query_rate_per_second>, measuring each request from submission to
the stored-result boundary (C<EOSE>) and emitting one C<query> metric event
per request with the stored C<result_count>. Each query uses a distinct
subscription id and is closed at the boundary, so live deliveries never
stretch a query's duration. A request that never reaches the boundary within
the timeout is a metric event with C<status: error>, not a worker failure.
Workers in other languages are equally valid; the contract documents are
normative.

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
