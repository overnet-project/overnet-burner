package Overnet::Burner::Metrics;

use strictures 2;

use Carp    qw(croak);
use English qw(-no_match_vars);
use File::Spec;
use JSON       ();
use List::Util qw(max min sum);
use POSIX      qw(ceil);

use Overnet::Burner::Util qw(checked_close);

our $VERSION = '0.001';

my $RFC3339_DATE    = qr/[0-9]{4}-[0-9]{2}-[0-9]{2}/mxs;
my $RFC3339_TIME    = qr/[0-9]{2}:[0-9]{2}:[0-9]{2}(?:[.][0-9]+)?/mxs;
my $RFC3339_UTC     = qr/\A $RFC3339_DATE T $RFC3339_TIME Z \z/mxs;
my @PERCENTILES     = qw(p50 p90 p95 p99);
my %PERCENTILE_RANK = (p50 => 50, p90 => 90, p95 => 95, p99 => 99);

sub validate_event {
  my ($class, $event) = @_;

  if (ref($event) ne 'HASH') {
    return (0, 'event must be an object');
  }

  for my $check (\&_identity_rule_violation, \&_timing_rule_violation, \&_outcome_rule_violation) {
    my $violation = $check->($event);
    if (defined $violation) {
      return (0, $violation);
    }
  }

  return (1, undef);
}

sub _identity_rule_violation {
  my ($event) = @_;

  if (!(defined $event->{metric_version} && !ref($event->{metric_version}) && $event->{metric_version} eq '1')) {
    return 'metric_version must be 1';
  }
  for my $field (qw(run_id worker_id host role operation)) {
    if (!(defined $event->{$field} && !ref($event->{$field}) && length $event->{$field})) {
      return "$field is required";
    }
  }

  return;
}

sub _timing_rule_violation {
  my ($event) = @_;

  for my $field (qw(started_at finished_at)) {
    if (!(defined $event->{$field} && !ref($event->{$field}) && $event->{$field} =~ $RFC3339_UTC)) {
      return "$field must be an RFC 3339 UTC timestamp";
    }
  }
  if (!_is_non_negative_number($event->{duration_ms})) {
    return 'duration_ms must be a non-negative number';
  }

  return;
}

sub _outcome_rule_violation {
  my ($event) = @_;

  my $status = $event->{status};
  if (!(defined $status && !ref($status) && ($status eq 'success' || $status eq 'error'))) {
    return 'status must be success or error';
  }
  if (exists $event->{error} && !(defined $event->{error} && !ref($event->{error}) && length $event->{error})) {
    return 'error must be a non-empty string';
  }

  return;
}

sub read_stream {
  my ($class, $path) = @_;

  open my $fh, '<', $path
    or croak "open $path: $OS_ERROR\n";

  my @events;
  my $line_number = 0;
  while (my $line = <$fh>) {
    $line_number++;
    next if $line =~ /\A\s*\z/mxs;

    my $event;
    my $parse_error;
    eval {
      $event = JSON::decode_json($line);
      1;
    } or $parse_error = $EVAL_ERROR;
    if ($parse_error) {
      chomp $parse_error;
      croak "$path line $line_number: malformed JSON: $parse_error\n";
    }

    my ($ok, $rule_error) = $class->validate_event($event);
    if (!$ok) {
      croak "$path line $line_number: invalid metric event: $rule_error\n";
    }

    push @events, $event;
  }
  checked_close($fh, $path);

  return \@events;
}

sub summarize {
  my ($class, $events) = @_;

  if (ref($events) ne 'ARRAY') {
    croak "events must be an array reference\n";
  }

  my %by_operation;
  for my $event (@{$events}) {
    push @{$by_operation{$event->{operation}}}, $event;
  }

  my %operations;
  my $total_count = 0;
  my $total_error = 0;
  for my $operation (sort keys %by_operation) {
    my @group     = @{$by_operation{$operation}};
    my @successes = grep { $_->{status} eq 'success' } @group;
    my $count     = scalar @group;
    my $errors    = $count - scalar @successes;

    $operations{$operation} = {
      count         => $count,
      success_count => scalar @successes,
      error_count   => $errors,
      error_rate    => $count ? $errors / $count : 0,
      latency_ms    => _latency_summary([map { $_->{duration_ms} } @successes]),
    };
    $total_count += $count;
    $total_error += $errors;
  }

  return {
    operations => \%operations,
    overall    => {
      count         => $total_count,
      success_count => $total_count - $total_error,
      error_count   => $total_error,
      error_rate    => $total_count ? $total_error / $total_count : 0,
    },
  };
}

sub summarize_stream_files {
  my ($class, $run_dir, $streams) = @_;

  if (ref($streams) ne 'ARRAY') {
    croak "streams must be an array reference\n";
  }

  my @events;
  for my $stream (@{$streams}) {
    my $path =
      File::Spec->file_name_is_absolute($stream->{path})
      ? $stream->{path}
      : File::Spec->catfile($run_dir, $stream->{path});
    push @events, @{$class->read_stream($path)};
  }

  return $class->summarize(\@events);
}

sub _latency_summary {
  my ($durations) = @_;

  my @sorted = sort { $a <=> $b } @{$durations};
  if (!@sorted) {
    return {
      min => undef,
      (map { $_ => undef } @PERCENTILES),
      max  => undef,
      mean => undef,
    };
  }

  my %summary = (
    min  => $sorted[0],
    max  => $sorted[-1],
    mean => sum(@sorted) / scalar @sorted,
  );
  for my $percentile (@PERCENTILES) {
    my $rank = ceil($PERCENTILE_RANK{$percentile} / 100 * scalar @sorted);
    if ($rank < 1) {
      $rank = 1;
    }
    $summary{$percentile} = $sorted[$rank - 1];
  }

  return \%summary;
}

sub _is_non_negative_number {
  my ($value) = @_;
  return 0 if !defined $value || ref $value;
  return 0 if $value !~ /\A-?(?:[0-9]+(?:[.][0-9]+)?|[.][0-9]+)\z/mxs;
  return $value >= 0 ? 1 : 0;
}

1;

=head1 NAME

Overnet::Burner::Metrics - reference implementation of the metric event contract

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Metrics;

  my $events  = Overnet::Burner::Metrics->read_stream('metrics/publisher-001.jsonl');
  my $summary = Overnet::Burner::Metrics->summarize($events);

=head1 DESCRIPTION

This module is the Perl reference implementation of the language-neutral
metric event contract defined in F<docs/METRICS.md> and
F<schemas/metric-event-v1.schema.json>. Workers in any language emit metric
events as JSONL; this module validates, reads, and summarizes those streams
for report generation. The contract documents are normative; this code
follows them.

=head1 SUBROUTINES/METHODS

=head2 validate_event

Public API entry point.

=head2 read_stream

Public API entry point.

=head2 summarize

Public API entry point.

=head2 summarize_stream_files

Public API entry point.

=head1 DIAGNOSTICS

Errors are raised via C<croak>; stream errors name the file, line number,
and violated rule.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

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
