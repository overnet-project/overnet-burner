package Overnet::Burner::Worker::ConnectionFlood;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker::Abuse';

use Net::Nostr::Client;
use Time::HiRes qw(time);

our $VERSION = '0.001';

no Moo;

sub expected_role {
  return 'connection_flood';
}

sub abuse_operation {
  return 'abusive_connect';
}

sub default_rate {
  return 20;
}

sub wants_persistent_client {
  return 0;
}

sub perform_abuse {
  my ($self, %args) = @_;

  # Each operation opens a fresh connection and holds it open, so the
  # connections accumulate until the relay refuses one at its concurrent
  # connection limit. The client connects synchronously and croaks on
  # failure, so an eval captures the refusal.
  my $started_at = time;
  my $client     = Net::Nostr::Client->new;
  my $connected  = eval {
    $client->connect($args{relay_url});
    1;
  };

  my ($accepted, $message);
  if ($connected && $client->is_connected) {
    $accepted = 1;
    $message  = q{};
    push @{$self->{held_connections}}, $client;
  } else {
    $accepted = 0;
    $message  = 'blocked: connection refused';
  }

  return ($accepted, $message, $started_at, time);
}

sub teardown_abuse {
  my ($self) = @_;

  for my $client (@{$self->{held_connections} || []}) {
    eval { $client->disconnect; 1 } or next;    # best-effort teardown
  }
  $self->{held_connections} = [];

  return 1;
}

1;

=head1 NAME

Overnet::Burner::Worker::ConnectionFlood - connection-exhaustion abuse worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::ConnectionFlood;

  Overnet::Burner::Worker::ConnectionFlood->new(input => $input)->run;

=head1 DESCRIPTION

The Perl reference implementation of the C<connection_flood> abuse role
under the contract in F<docs/abuse.md>. It opens a stream of WebSocket
connections and holds them open, so they accumulate until the relay refuses
one at its concurrent connection limit: a refused connection is the correct
defense, while yet another accepted connection is a defense failure. Unlike
the publish-abuse roles it uses no persistent client - each operation is its
own connection - and it tears down every held connection when the run ends.

=head1 SUBROUTINES/METHODS

=head2 expected_role

=head2 abuse_operation

=head2 default_rate

=head2 wants_persistent_client

=head2 perform_abuse

=head2 teardown_abuse

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; a refused connection is a
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
