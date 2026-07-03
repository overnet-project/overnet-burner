package Overnet::Burner::Worker::SubscriptionAbuser;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

use AnyEvent;
use Net::Nostr::Filter;
use Time::HiRes qw(time);

our $VERSION = '0.001';

my $SUBSCRIBE_TIMEOUT = 5;

no Moo;

sub expected_role {
  return 'subscription_abuser';
}

sub abuse_operation {
  return 'abusive_subscribe';
}

sub default_rate {
  return 20;
}

sub register_response_handlers {
  my ($self, $client, $pending) = @_;

  # Subscription abuse is measured on the subscription lifecycle, not on
  # OK: an EOSE means the subscription opened (the abuse got through), a
  # CLOSED means the relay refused it (the defense fired).
  my $resolve = sub {
    my ($subscription_id, $accepted, $message) = @_;
    my $waiter = delete $pending->{$subscription_id};
    if ($waiter) {
      $waiter->send([$accepted, $message]);
    }
  };
  $client->on(eose   => sub { $resolve->($_[0], 1, q{}); });
  $client->on(closed => sub { $resolve->($_[0], 0, $_[1]); });

  return 1;
}

sub perform_abuse {
  my ($self, %args) = @_;

  # Distinct subscription ids that are never closed, so they accumulate on
  # the connection until the relay's subscription bound (if any) refuses one.
  my $subscription_id = sprintf 'abuse-%s-%06d', $self->input->{worker_id}, $args{sequence};
  my $filter          = Net::Nostr::Filter->new(kinds => [7800]);

  my $waiter = AnyEvent->condvar;
  $args{pending}{$subscription_id} = $waiter;
  my $timeout = AnyEvent->timer(
    after => $SUBSCRIBE_TIMEOUT,
    cb    => sub {
      my $timed_out = delete $args{pending}{$subscription_id};
      if ($timed_out) {
        $timed_out->send([0, 'error: subscription timed out']);
      }
    },
  );

  my $started_at = time;
  my $sent       = eval {
    $args{client}->subscribe($subscription_id, $filter);
    1;
  };
  my ($accepted, $message);
  if ($sent) {
    ($accepted, $message) = @{$waiter->recv};
  } else {
    delete $args{pending}{$subscription_id};
    ($accepted, $message) = (0, 'error: relay connection lost');
  }

  return ($accepted, $message, $started_at, time);
}

1;

=head1 NAME

Overnet::Burner::Worker::SubscriptionAbuser - subscription-exhaustion abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::SubscriptionAbuser;

  Overnet::Burner::Worker::SubscriptionAbuser->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<subscription_abuser> abuse role
under the contract in F<docs/abuse.md>. It opens a stream of distinct
subscriptions and never closes them, so they accumulate on the connection,
and measures whether the relay bounds them: a C<CLOSED> refusal is the
correct defense, while an C<EOSE> that opens yet another unbounded
subscription is a defense failure. The abuse is subscription-count
exhaustion; deliberately expensive filters are future work.

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 register_response_handlers

=head2 perform_abuse

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a refused subscription is a
metric event, not a worker failure.

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
