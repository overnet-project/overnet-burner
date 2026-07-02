package Overnet::Burner::Worker;

use strictures 2;
use Moo;

use Carp    qw(croak);
use English qw(-no_match_vars);
use File::Spec;
use JSON  ();
use POSIX qw(strftime);
use Sys::Hostname;
use Time::HiRes qw(time);

use Overnet::Burner::Metrics;
use Overnet::Burner::Util qw(checked_close checked_print write_file);

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

has input => (is => 'ro');

no Moo;

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = _constructor_args_hash(@args);

  my $input = $args{input};
  if (ref($input) ne 'HASH') {
    croak "input must be a hash reference\n";
  }
  for my $field (qw(input_version run_id run_dir worker_id role seed duration_seconds metric_stream ready_file)) {
    if (!defined $input->{$field}) {
      croak "input.$field is required\n";
    }
  }
  if ($input->{input_version} ne '1') {
    croak "input.input_version must be 1\n";
  }
  my $expected_role = $class->expected_role;
  if ($input->{role} ne $expected_role) {
    croak "input.role must be $expected_role\n";
  }
  my $relays = ref($input->{endpoints}) eq 'HASH' ? $input->{endpoints}{relays} : undef;
  if (!(ref($relays) eq 'ARRAY' && @{$relays} && !ref($relays->[0]) && length $relays->[0])) {
    croak "input.endpoints.relays must name at least one relay\n";
  }

  return {input => $input};
}

sub _constructor_args_hash {
  my (@args) = @_;
  return %{$args[0]} if @args == 1 && ref($args[0]) eq 'HASH';
  return @args       if @args % 2 == 0;
  die "constructor arguments must be a hash or hash reference\n";
}

sub expected_role {
  croak "worker classes must define expected_role\n";
}

sub run {
  croak "worker classes must define run\n";
}

sub open_metric_stream {
  my ($self) = @_;

  my $path = File::Spec->catfile($self->input->{run_dir}, $self->input->{metric_stream});
  open my $stream, '>>', $path
    or croak "open $path: $OS_ERROR\n";
  $stream->autoflush(1);
  $self->{metric_stream_handle} = $stream;
  $self->{metric_stream_path}   = $path;

  return $stream;
}

sub close_metric_stream {
  my ($self) = @_;

  if ($self->{metric_stream_handle}) {
    checked_close($self->{metric_stream_handle}, $self->{metric_stream_path});
    delete $self->{metric_stream_handle};
  }

  return 1;
}

sub write_ready_file {
  my ($self) = @_;

  write_file(File::Spec->catfile($self->input->{run_dir}, $self->input->{ready_file}), q{});

  return 1;
}

sub emit_metric {
  my ($self, %fields) = @_;

  my $input  = $self->input;
  my %metric = (
    metric_version => 1,
    run_id         => $input->{run_id},
    worker_id      => $input->{worker_id},
    host           => $self->host,
    role           => $input->{role},
    %fields,
  );

  my ($ok, $rule_error) = Overnet::Burner::Metrics->validate_event(\%metric);
  if (!$ok) {
    croak "worker produced an invalid metric event: $rule_error\n";
  }
  checked_print($self->{metric_stream_handle}, $JSON->encode(\%metric) . "\n");

  return 1;
}

sub host {
  my ($self) = @_;

  $self->{host} //= hostname;

  return $self->{host};
}

sub iso_timestamp {
  my ($class, $epoch) = @_;

  my $whole     = int $epoch;
  my $millis    = int(($epoch - $whole) * 1000);
  my $formatted = strftime('%Y-%m-%dT%H:%M:%S', gmtime $whole);

  return sprintf '%s.%03dZ', $formatted, $millis;
}

1;

=head1 NAME

Overnet::Burner::Worker - shared base for reference workers

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  package Overnet::Burner::Worker::SomeRole;
  use Moo;
  extends 'Overnet::Burner::Worker';

  sub expected_role { return 'some_role' }
  sub run           { ... }

=head1 DESCRIPTION

Shared plumbing for the Perl reference workers under the worker contract in
F<docs/workers.md>: input document validation, metric stream handling with
per-event validation against the metric event contract, readiness marker
creation, and timestamp formatting. Role behavior lives in subclasses; the
contract documents remain normative and workers in other languages are
equally valid.

=head1 SUBROUTINES/METHODS

=head2 new

Public API entry point.

=head2 input

Public API entry point.

=head2 expected_role

Public API entry point.

=head2 run

Public API entry point.

=head2 open_metric_stream

Public API entry point.

=head2 close_metric_stream

Public API entry point.

=head2 write_ready_file

Public API entry point.

=head2 emit_metric

Public API entry point.

=head2 host

Public API entry point.

=head2 iso_timestamp

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

No known bugs are documented.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
