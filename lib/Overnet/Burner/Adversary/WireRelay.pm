package Overnet::Burner::Adversary::WireRelay;

use strictures 2;
use Moo;

use AnyEvent;
use Carp qw(croak);
use Net::Nostr::Client;

our $VERSION = '0.001';

my $DEFAULT_TIMEOUT = 5;

has relay_url => (is => 'ro', required => 1);
has timeout   => (is => 'ro', default  => sub {$DEFAULT_TIMEOUT});
has _client   => (is => 'rw');
has _pending  => (is => 'ro', default => sub { {} });

no Moo;

sub connect {    ## no critic (Subroutines::ProhibitBuiltinHomonyms)
  my ($self) = @_;

  my $client = Net::Nostr::Client->new;
  $client->on(
    ok => sub {
      my ($event_id, $accepted, $message) = @_;
      $self->_deliver($event_id, [$accepted ? 1 : 0, $message]);
    }
  );
  $client->connect($self->relay_url);
  $self->_client($client);

  return $self;
}

sub submit {
  my ($self, $event) = @_;

  my $client = $self->_client
    or croak "WireRelay is not connected; call connect first\n";

  my $event_id = $event->id;
  my $waiter   = AnyEvent->condvar;
  $self->_pending->{$event_id} = $waiter;

  my $timeout = $self->timeout;
  my $timer   = AnyEvent->timer(
    after => $timeout,
    cb    => sub {
      $self->_deliver($event_id, [undef, "timeout: no OK from relay within ${timeout}s"]);
    },
  );

  $client->publish($event);
  my $result = $waiter->recv;
  undef $timer;

  return @{$result};
}

# Hand a result to the waiter registered for an event id, if one is still
# pending. Shared by the OK handler and the timeout timer; whichever fires first
# claims the waiter and the other becomes a no-op.
sub _deliver {
  my ($self, $event_id, $payload) = @_;
  my $waiter = delete $self->_pending->{$event_id};
  if ($waiter) {
    $waiter->send($payload);
  }
  return 1;
}

sub disconnect {
  my ($self) = @_;

  my $client = $self->_client
    or return 1;
  $client->disconnect;
  $self->_client(undef);

  return 1;
}

1;

=head1 NAME

Overnet::Burner::Adversary::WireRelay - submit events to a real relay over a WebSocket

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $wire = Overnet::Burner::Adversary::WireRelay->new(
    relay_url => 'ws://127.0.0.1:7448',
  );
  $wire->connect;
  my ($accepted, $reason) = $wire->submit($event);
  $wire->disconnect;

=head1 DESCRIPTION

A thin adapter that publishes a signed event to a live Overnet relay over a real
WebSocket connection and returns the relay's own accept/reject decision. It is
the transport a wire-backed adversary arena
(L<Overnet::Burner::Adversary::Arena::Wire>) submits through, so the adversary
catalog can be replayed against a deployed relay endpoint rather than an
in-process relay object.

The relay answers each published event with a NIP-01/NIP-20 C<OK> command
result carrying an C<accepted> flag and a human-readable message; that message
includes the authorization reason on rejection. C<submit> correlates the C<OK>
to the event it published and returns C<(accepted, reason)>, which is the same
shape the in-process arena reads from the relay's C<on_event> callback -- so the
authorization and admission oracles judge a wire episode exactly as they judge
an in-process one.

Because a real relay persists every accepted event, this transport cannot
authorize an event without also storing it; read-only capability probes have no
faithful wire equivalent and are not offered here.

=head1 SUBROUTINES/METHODS

=head2 new

Constructs the adapter. Requires C<relay_url> and takes an optional C<timeout>
(seconds to wait for an C<OK>; default 5).

=head2 connect

Opens the WebSocket connection and registers the C<OK> handler. Returns the
adapter.

=head2 submit

Publishes an event and blocks until the relay's C<OK> for it arrives (or the
timeout elapses), returning C<(accepted, reason)>. On timeout C<accepted> is
C<undef> and the reason names the timeout.

=head2 disconnect

Closes the WebSocket connection. Safe to call when already disconnected.

=head1 DIAGNOSTICS

C<submit> dies if called before C<connect>.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a reachable relay at C<relay_url>.

=head1 DEPENDENCIES

Requires L<Moo>, L<AnyEvent>, and L<Net::Nostr::Client>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Cannot authorize an event without persisting it, so it does not support
non-persisting capability probes.

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
