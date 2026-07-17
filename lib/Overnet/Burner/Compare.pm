package Overnet::Burner::Compare;

use strictures 2;

use Carp qw(croak);

our $VERSION = '0.001';

# Per-operation metrics the comparison tracks, all of which are "lower is
# better" (latency and error rate), so a rise is a regression and a fall is an
# improvement. Ordered for a stable, readable comparison document.
my @OPERATION_METRICS = (
  'error_rate',     'latency_ms.p50',  'latency_ms.p90', 'latency_ms.p95',
  'latency_ms.p99', 'latency_ms.mean', 'latency_ms.max',
);

sub compare {
  my ($class, %args) = @_;

  my $baseline  = $args{baseline}  or croak "baseline report is required\n";
  my $candidate = $args{candidate} or croak "candidate report is required\n";
  if (ref $baseline ne 'HASH' || ref $candidate ne 'HASH') {
    croak "reports must be report objects\n";
  }

  my $base_run = $baseline->{run}  || {};
  my $cand_run = $candidate->{run} || {};

  my $thresholds = _compare_thresholds($baseline->{thresholds} || [], $candidate->{thresholds} || []);
  my $operations = _compare_operations(($baseline->{metrics} || {})->{operations} || {},
    ($candidate->{metrics} || {})->{operations} || {});

  my $verdict = _field_change($base_run->{verdict}, $cand_run->{verdict});

  my $summary = _summarize($thresholds, $operations, $base_run->{verdict}, $cand_run->{verdict});

  return {
    compare_version => 1,
    baseline        => _run_identity($base_run),
    candidate       => _run_identity($cand_run),
    verdict         => $verdict,
    result_class    => _field_change($base_run->{result_class}, $cand_run->{result_class}),
    thresholds      => $thresholds,
    operations      => $operations,
    summary         => $summary,
  };
}

sub _run_identity {
  my ($run) = @_;

  return {
    id           => $run->{id},
    verdict      => $run->{verdict},
    result_class => $run->{result_class},
  };
}

sub _field_change {
  my ($baseline, $candidate) = @_;

  return {
    baseline  => $baseline,
    candidate => $candidate,
    changed   => _differs($baseline, $candidate) ? 1 : 0,
  };
}

sub _differs {
  my ($a, $b) = @_;

  if (!defined $a && !defined $b) {
    return 0;
  }
  if (!defined $a || !defined $b) {
    return 1;
  }

  return $a ne $b ? 1 : 0;
}

sub _compare_thresholds {
  my ($baseline, $candidate) = @_;

  my %base = map { ; $_->{id} => $_ } @{$baseline};
  my %cand = map { ; $_->{id} => $_ } @{$candidate};

  my %ids;
  for my $id (keys %base, keys %cand) {
    $ids{$id} = 1;
  }

  my @rows;
  for my $id (sort keys %ids) {
    my $b = $base{$id};
    my $c = $cand{$id};
    push @rows,
      {
      id               => $id,
      metric           => ($c || $b)->{metric},
      baseline_status  => $b ? $b->{status}         : undef,
      candidate_status => $c ? $c->{status}         : undef,
      baseline_value   => $b ? $b->{observed_value} : undef,
      candidate_value  => $c ? $c->{observed_value} : undef,
      delta            => scalar _delta($b ? $b->{observed_value} : undef, $c ? $c->{observed_value} : undef),
      change           => _threshold_change($b, $c),
      };
  }

  return \@rows;
}

sub _threshold_change {
  my ($baseline, $candidate) = @_;

  if (!$baseline) {
    return 'added';
  }
  if (!$candidate) {
    return 'removed';
  }

  my $was_failed = ($baseline->{status}  || q{}) eq 'failed';
  my $is_failed  = ($candidate->{status} || q{}) eq 'failed';
  if ($is_failed && !$was_failed) {
    return 'regressed';
  }
  if ($was_failed && !$is_failed) {
    return 'improved';
  }
  if (($baseline->{status} || q{}) ne ($candidate->{status} || q{})) {
    return 'changed';
  }

  return 'unchanged';
}

sub _compare_operations {
  my ($baseline, $candidate) = @_;

  my %names;
  for my $name (keys %{$baseline}, keys %{$candidate}) {
    $names{$name} = 1;
  }

  my @rows;
  for my $operation (sort keys %names) {
    for my $metric (@OPERATION_METRICS) {
      my $b = _metric_value($baseline->{$operation},  $metric);
      my $c = _metric_value($candidate->{$operation}, $metric);
      push @rows,
        {
        operation   => $operation,
        metric      => $metric,
        baseline    => $b,
        candidate   => $c,
        delta       => scalar _delta($b, $c),
        delta_ratio => scalar _ratio($b, $c),
        direction   => _direction($b, $c),
        };
    }
  }

  return \@rows;
}

sub _metric_value {
  my ($operation, $metric) = @_;

  if (ref $operation ne 'HASH') {
    return;
  }

  my @path = split /[.]/mxs, $metric;
  my $node = $operation;
  for my $segment (@path) {
    if (ref $node ne 'HASH') {
      return;
    }
    $node = $node->{$segment};
  }

  return (defined $node && !ref $node) ? $node : undef;
}

# Direction for a lower-is-better metric: a rise regresses, a fall improves, and
# a value missing from either side cannot be judged.
sub _direction {
  my ($baseline, $candidate) = @_;

  if (!defined $baseline || !defined $candidate) {
    return 'incomparable';
  }
  if ($candidate > $baseline) {
    return 'regressed';
  }
  if ($candidate < $baseline) {
    return 'improved';
  }

  return 'unchanged';
}

sub _delta {
  my ($baseline, $candidate) = @_;

  if (!defined $baseline || !defined $candidate) {
    return;
  }

  return $candidate - $baseline;
}

sub _ratio {
  my ($baseline, $candidate) = @_;

  if (!defined $baseline || !defined $candidate || $baseline == 0) {
    return;
  }

  return ($candidate - $baseline) / $baseline;
}

sub _summarize {
  my ($thresholds, $operations, $base_verdict, $cand_verdict) = @_;

  my $thresholds_regressed = grep { $_->{change} eq 'regressed' } @{$thresholds};
  my $thresholds_improved  = grep { $_->{change} eq 'improved' } @{$thresholds};
  my $metrics_regressed    = grep { $_->{direction} eq 'regressed' } @{$operations};
  my $metrics_improved     = grep { $_->{direction} eq 'improved' } @{$operations};

  my $verdict_regressed = _is_failure_verdict($cand_verdict) && !_is_failure_verdict($base_verdict);

  return {
    thresholds_regressed => 0 + $thresholds_regressed,
    thresholds_improved  => 0 + $thresholds_improved,
    metrics_regressed    => 0 + $metrics_regressed,
    metrics_improved     => 0 + $metrics_improved,
    regressed            => ($thresholds_regressed || $verdict_regressed) ? 1 : 0,
  };
}

sub _is_failure_verdict {
  my ($verdict) = @_;

  if (!defined $verdict) {
    return 0;
  }

  return ($verdict =~ /_failed\z/mxs || $verdict eq 'aborted') ? 1 : 0;
}

1;

=head1 NAME

Overnet::Burner::Compare - compare two run reports for regressions

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $diff = Overnet::Burner::Compare->compare(
    baseline  => $baseline_report,
    candidate => $candidate_report,
  );
  # $diff->{summary}{regressed}, $diff->{thresholds}, $diff->{operations}

=head1 DESCRIPTION

Compares a candidate run report against a baseline and reports what changed:
the run verdict and result class, each threshold's pass/fail transition, and
the per-operation latency and error-rate deltas. Regression is defined by the
authoritative pass/fail signals - a threshold crossing from C<passed> to
C<failed>, or the verdict falling to a failure - so a run does not regress on an
informational metric drift alone.

=head1 SUBROUTINES/METHODS

=head2 compare

Takes C<baseline> and C<candidate> report objects and returns a comparison
object with C<verdict>, C<result_class>, C<thresholds>, C<operations>, and a
C<summary>.

=head1 DIAGNOSTICS

Missing reports are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

No environment configuration is required.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Only lower-is-better operation metrics (latency and error rate) carry a
direction; throughput comparison is not yet modeled.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
