package Overnet::Burner::WorkerCommand;

use strictures 2;

use English qw(-no_match_vars);

use Overnet::Burner::Util qw(checked_print read_json_file);

our $VERSION = '0.001';

my %ROLE_CLASS = (
  publisher           => 'Overnet::Burner::Worker::Publisher',
  subscriber          => 'Overnet::Burner::Worker::Subscriber',
  query_reader        => 'Overnet::Burner::Worker::QueryReader',
  object_reader       => 'Overnet::Burner::Worker::ObjectReader',
  observer            => 'Overnet::Burner::Worker::Observer',
  flooder             => 'Overnet::Burner::Worker::Flooder',
  malformed_publisher => 'Overnet::Burner::Worker::MalformedPublisher',
  replayer            => 'Overnet::Burner::Worker::Replayer',
  subscription_abuser => 'Overnet::Burner::Worker::SubscriptionAbuser',
  sybil               => 'Overnet::Burner::Worker::Sybil',
  connection_flood    => 'Overnet::Burner::Worker::ConnectionFlood',
  provenance_forger   => 'Overnet::Burner::Worker::ProvenanceForger',
);

sub run_from_environment {
  my ($class) = @_;

  my $input_path = $ENV{OVERNET_BURNER_WORKER_INPUT};
  if (!(defined $input_path && length $input_path)) {
    _print_error("OVERNET_BURNER_WORKER_INPUT must name the worker input document");
    return 2;
  }
  if (!-f $input_path) {
    _print_error("worker input document does not exist: $input_path");
    return 2;
  }

  my $input = read_json_file($input_path);
  my $role  = ref($input) eq 'HASH' ? $input->{role} : undef;
  if (!(defined $role && !ref($role) && length $role)) {
    _print_error('worker input document does not declare a role');
    return 2;
  }

  my $worker_class = $ROLE_CLASS{$role};
  if (!$worker_class) {
    _print_error("unsupported worker role: $role");
    return 2;
  }

  my $loaded = eval "require $worker_class; 1";    ## no critic (BuiltinFunctions::ProhibitStringyEval)
  if (!$loaded) {
    _print_error("unable to load worker class $worker_class: $EVAL_ERROR");
    return 2;
  }

  my $worker;
  my $error;
  my $completed = eval {
    $worker = $worker_class->new(input => $input);
    $worker->run;
    1;
  };
  if (!$completed) {
    $error = $EVAL_ERROR || 'worker failed';
  }
  if ($error) {
    _print_error($error);
    return 1;
  }

  return 0;
}

sub _print_error {
  my ($message) = @_;

  $message //= q{};
  $message =~ s/\s+\z//mxs;
  checked_print(\*STDERR, "$message\n");

  return 1;
}

1;

=head1 NAME

Overnet::Burner::WorkerCommand - reference worker process command

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  exit Overnet::Burner::WorkerCommand->run_from_environment;

=head1 DESCRIPTION

Dispatches the reference Perl worker process from the worker input document
named by C<OVERNET_BURNER_WORKER_INPUT>. This module backs both
C<overnet-burner worker> and the legacy C<overnet-burner-worker> shim. The
language-neutral worker contract remains documented in F<docs/workers.md>.

=head1 SUBROUTINES/METHODS

=head2 run_from_environment

Run the worker named by the input document and return a process exit code.

=head1 DIAGNOSTICS

Worker command errors are written to standard error and reported through
non-zero exit codes.

=head1 CONFIGURATION AND ENVIRONMENT

C<OVERNET_BURNER_WORKER_INPUT> must point at a worker input document.

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
