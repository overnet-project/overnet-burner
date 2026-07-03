package Overnet::Burner::Guest;

use strictures 2;
use Moo;

use Carp qw(croak);

our $VERSION = '0.001';

has name => (is => 'ro', required => 1);
has role => (is => 'ro', required => 1);

no Moo;

sub transport {
  croak "guest classes must define transport\n";
}

sub make_path {
  croak "guest classes must define make_path\n";
}

sub write_file {
  croak "guest classes must define write_file\n";
}

sub read_file {
  croak "guest classes must define read_file\n";
}

sub run_command {
  croak "guest classes must define run_command\n";
}

sub launch {
  croak "guest classes must define launch\n";
}

sub try_reap {
  croak "guest classes must define try_reap\n";
}

sub signal {
  croak "guest classes must define signal\n";
}

sub ready_actors {
  croak "guest classes must define ready_actors\n";
}

sub destroy {
  return 1;
}

1;

=head1 NAME

Overnet::Burner::Guest - the uniform guest contract

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  package Overnet::Burner::Guest::SomeTransport;
  use Moo;
  extends 'Overnet::Burner::Guest';

=head1 DESCRIPTION

A guest is a place workers run, behind a uniform interface, so runners can
execute commands, move files, and probe readiness without knowing how the
guest came to exist (see F<docs/provisioning.md>). The interface is
deliberately small: create directories, write and read files, run a
one-shot command to completion, launch and reap long-running processes,
deliver signals, and aggregate worker readiness in one probe per guest.
Everything the local exec transport does today, an SSH or container
transport does tomorrow behind the same methods.

=head1 SUBROUTINES/METHODS

=head2 new

=head2 name

=head2 role

=head2 transport

=head2 make_path

=head2 write_file

=head2 read_file

=head2 run_command

Run one command on the guest to completion and return its result as a hash
reference with C<exit_code> (the integer exit status, or C<undef> when the
command was killed by a signal), C<stdout>, and C<stderr>. Unlike C<launch>,
which supervises a long-running worker, this is for the short lifecycle
commands (a relay start, health probe, or stop) a runner needs to run on
whichever guest a relay was placed on.

=head2 launch

=head2 try_reap

=head2 signal

=head2 ready_actors

=head2 destroy

Release any provisioned resources backing the guest. The default is a
no-op because attached and local guests own nothing; constructed guests
(containers, virtual machines) override it.

=head1 DIAGNOSTICS

Calling an interface method on the base class croaks; transports implement
the full interface.

=head1 CONFIGURATION AND ENVIRONMENT

None.

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
