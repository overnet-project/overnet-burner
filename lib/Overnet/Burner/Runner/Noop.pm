package Overnet::Burner::Runner::Noop;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Runner';

our $VERSION = '0.001';

no Moo;

sub prepare { return 1 }
sub start   { return 1 }
sub observe { return 1 }
sub stop    { return 1 }
sub collect { return 1 }

1;

=head1 NAME

Overnet::Burner::Runner::Noop - no-op runner

=head1 DESCRIPTION

Implements the lifecycle without remote execution for smoke tests and baseline wiring checks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(name => 'noop', %args);

=head1 SUBROUTINES/METHODS

=head2 prepare

=head2 start

=head2 observe

=head2 stop

=head2 collect

=head1 DIAGNOSTICS

No additional diagnostics are produced by this runner.

=head1 CONFIGURATION AND ENVIRONMENT

No environment configuration is required.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
