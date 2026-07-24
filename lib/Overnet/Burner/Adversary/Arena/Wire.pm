package Overnet::Burner::Adversary::Arena::Wire;

use strictures 2;
use Moo;

use Carp qw(croak);

extends 'Overnet::Burner::Adversary::Arena::Live';

use Overnet::Burner::Adversary::WireRelay;

our $VERSION = '0.001';

around reset => sub {
  my ($orig, $self, @args) = @_;
  my $existing = $self->{_sut};
  if ($existing && $existing->can('disconnect')) {
    $existing->disconnect;
  }
  return $self->$orig(@args);
};

sub baseline_ref {
  my ($self) = @_;
  return 'wire:' . $self->relay_url;
}

sub _build_sut {
  my ($self) = @_;
  my $wire = Overnet::Burner::Adversary::WireRelay->new(relay_url => $self->relay_url);
  $wire->connect;
  return $wire;
}

# A remote relay persists every accepted event itself, so force_store has no
# wire equivalent and is ignored: the relay's OK is the authoritative decision.
sub _submit_persisting {
  my ($self, $event) = @_;
  return $self->_sut->submit($event);
}

sub _persist_grant {
  my ($self, $grant) = @_;
  $self->_sut->submit($grant);
  return 1;
}

sub _submit_probe {
  my ($self) = @_;
  croak "capability/availability/state probes are not supported over the wire "
    . "(a real relay persists every accepted event); use the in-process Live "
    . "arena for the availability and convergence invariants\n";
}

1;

=head1 NAME

Overnet::Burner::Adversary::Arena::Wire - drive the adversary catalog against a real relay over a WebSocket

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $arena = Overnet::Burner::Adversary::Arena::Wire->new(
    relay_url        => 'ws://127.0.0.1:7448',
    snapshot_signers => ['snapshot-authority'],
    seed             => '1',
  );
  $arena->reset;
  my $observations = $arena->apply(
    {type => 'publish_control', payload => {...}},
  );

=head1 DESCRIPTION

A wire-backed adversary arena. It builds the same adversarial events as the
in-process L<Overnet::Burner::Adversary::Arena::Live> and reuses all of that
arena's action handlers, but submits each event to a B<real relay over a
WebSocket> (via L<Overnet::Burner::Adversary::WireRelay>) instead of calling an
in-process relay object's C<on_event>. The relay's own C<OK> accept/reject
decision (and reason) becomes the C<relay_outcome>, so the same authorization
and admission oracles judge a deployed endpoint end to end -- transport, framing
and all.

This exercises the deployed relay as a black box over the wire, complementing
the in-process arena, which exercises the authorization engine directly. Use it
to replay a known attack against a running relay container, or to confirm a
deployed relay still rejects what the in-process regression corpus rejects.

=head2 What it covers, and what it does not

The arena drives the write-decision actions -- C<publish_grant>,
C<publish_control>, C<publish_snapshot>, and C<join> -- whose oracle signal is
the relay's accept/reject of the submitted event. These feed the B<authorization>
and B<admission> invariants, which catch the d/h authorization-binding
differential and the tombstone-squat write, among others.

It does B<not> support the C<observe_capability>, C<observe_availability>, and
C<observe_state> actions: those authorize an event without persisting it (a
read-only probe of derived authority), which a real relay cannot do -- it stores
every accepted event. Those actions die with a clear message; run them through
the in-process L<Overnet::Burner::Adversary::Arena::Live> for the availability
and convergence invariants.

A wire episode also shares the remote relay's persistent state: C<reset>
reconnects but does not clear the relay's store, so this arena is intended for
single-episode attack replay against a live endpoint rather than many-episode
fuzzing with clean resets.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a wire arena. Takes the same arguments as
L<Overnet::Burner::Adversary::Arena::Live>; C<relay_url> is the endpoint of the
running relay to drive (default C<ws://127.0.0.1:7448>). C<snapshot_signers>
names the identities whose keys the target relay must have been started with as
its C<--snapshot-pubkey> authorities.

=head2 baseline_ref

Returns the opaque baseline reference identifying the wire endpoint under test.

=head2 reset

Disconnects any previous WebSocket connection, then reconnects to the target
relay and clears the arena's identity and grant registries. The remote relay's
store is not cleared.

=head1 DIAGNOSTICS

The C<observe_*> probe actions die with an explanation that they are unsupported
over the wire.

=head1 CONFIGURATION AND ENVIRONMENT

Requires a reachable relay at C<relay_url> and L<Net::Nostr::Client>.

=head1 DEPENDENCIES

Requires L<Moo>, L<Overnet::Burner::Adversary::Arena::Live>, and
L<Overnet::Burner::Adversary::WireRelay>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not support non-persisting capability probes, and does not reset remote
relay state between episodes.

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
