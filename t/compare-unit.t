use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Compare;

my $CMP = 'Overnet::Burner::Compare';

# A minimal report carrying only the fields the comparator reads: run verdict and
# result class, the threshold list, and the per-operation metrics.
sub _report {
  my (%args) = @_;
  return {
    run => {
      id           => $args{id}           || 'run-x',
      verdict      => $args{verdict}      || 'performance_passed',
      result_class => $args{result_class} || 'performance',
    },
    thresholds => $args{thresholds} || [],
    metrics    => {operations => $args{operations} || {}},
  };
}

sub _threshold {
  my (%a) = @_;
  return {
    id             => $a{id},
    metric         => $a{metric} || $a{id},
    status         => $a{status},
    comparator     => $a{comparator} || '<=',
    observed_value => $a{observed_value},
  };
}

sub _op {
  my (%a) = @_;
  return {
    error_rate => $a{error_rate},
    latency_ms => {p50 => $a{p50}, p90 => $a{p90}, p95 => $a{p95}, p99 => $a{p99}, mean => $a{mean}, max => $a{max}},
  };
}

subtest 'compare validates its arguments' => sub {
  like dies { $CMP->compare(candidate => _report()) }, qr/baseline\ report\ is\ required/mx, 'baseline required';
  like dies { $CMP->compare(baseline  => _report()) }, qr/candidate\ report\ is\ required/mx, 'candidate required';
};

subtest 'identical reports show no change or regression' => sub {
  my $report = _report(
    thresholds => [_threshold(id => 'publish_p99_ms', status => 'passed', observed_value => 10)],
    operations => {publish => _op(error_rate => 0, p99 => 10)},
  );
  my $diff = $CMP->compare(baseline => $report, candidate => $report);

  is $diff->{compare_version}, 1, 'the comparison is versioned';
  ok !$diff->{verdict}{changed}, 'an unchanged verdict is not flagged';
  is $diff->{thresholds}[0]{change}, 'unchanged', 'an unchanged threshold is reported as such';
  ok !$diff->{summary}{regressed}, 'identical reports do not regress';
  is $diff->{summary}{thresholds_regressed}, 0, 'no threshold regressions';
};

subtest 'a threshold crossing from passed to failed is a regression' => sub {
  my $base = _report(thresholds => [_threshold(id => 'publish_p99_ms', status => 'passed', observed_value => 10)]);
  my $cand = _report(thresholds => [_threshold(id => 'publish_p99_ms', status => 'failed', observed_value => 42)]);
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  my ($t) = @{$diff->{thresholds}};
  is $t->{change},          'regressed', 'passed to failed is a regression';
  is $t->{baseline_status}, 'passed',    'the baseline status is recorded';
  is $t->{candidate_status}, 'failed',   'the candidate status is recorded';
  is $t->{delta},           32,          'the observed-value delta is computed';
  is $diff->{summary}{thresholds_regressed}, 1, 'the regression is counted';
  ok $diff->{summary}{regressed}, 'a threshold regression regresses the run';
};

subtest 'a threshold recovering from failed to passed is an improvement' => sub {
  my $base = _report(thresholds => [_threshold(id => 'publish_p99_ms', status => 'failed', observed_value => 42)]);
  my $cand = _report(thresholds => [_threshold(id => 'publish_p99_ms', status => 'passed', observed_value => 9)]);
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  is $diff->{thresholds}[0]{change}, 'improved', 'failed to passed is an improvement';
  is $diff->{summary}{thresholds_improved}, 1, 'the improvement is counted';
  ok !$diff->{summary}{regressed}, 'an improvement alone is not a regression';
};

subtest 'thresholds present in only one report are added or removed' => sub {
  my $base = _report(thresholds => [_threshold(id => 'only_base', status => 'passed', observed_value => 1)]);
  my $cand = _report(thresholds => [_threshold(id => 'only_cand', status => 'passed', observed_value => 1)]);
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  my %change = map { $_->{id} => $_->{change} } @{$diff->{thresholds}};
  is $change{only_base}, 'removed', 'a threshold missing from the candidate is removed';
  is $change{only_cand}, 'added',   'a threshold new in the candidate is added';
};

subtest 'per-operation latency and error rate carry a direction' => sub {
  my $base = _report(operations => {publish => _op(error_rate => 0.01, p99 => 10, p50 => 5)});
  my $cand = _report(operations => {publish => _op(error_rate => 0.05, p99 => 25, p50 => 5)});
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  my %by = map {; "$_->{operation}.$_->{metric}" => $_ } @{$diff->{operations}};
  is $by{'publish.latency_ms.p99'}{direction}, 'regressed', 'a slower p99 is a regression';
  is $by{'publish.latency_ms.p99'}{delta},     15,          'the latency delta is computed';
  is $by{'publish.latency_ms.p50'}{direction}, 'unchanged', 'an equal percentile is unchanged';
  is $by{'publish.error_rate'}{direction},     'regressed', 'a higher error rate is a regression';
  ok $diff->{summary}{metrics_regressed} >= 2, 'regressed metrics are counted';
  ok !$diff->{summary}{regressed}, 'metric-only deltas do not flip the run verdict without a threshold';
};

subtest 'an improved metric is directioned and an undef value is incomparable' => sub {
  my $base = _report(operations => {query => _op(error_rate => 0.2, p99 => 100)});
  my $cand = _report(operations => {query => _op(error_rate => 0.1, p99 => undef)});
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  my %by = map {; "$_->{operation}.$_->{metric}" => $_ } @{$diff->{operations}};
  is $by{'query.error_rate'}{direction},     'improved',     'a lower error rate improves';
  is $by{'query.latency_ms.p99'}{direction}, 'incomparable', 'an undefined percentile cannot be compared';
  is $diff->{summary}{metrics_improved}, 1, 'the improvement is counted';
};

subtest 'a verdict falling to a failure regresses the run' => sub {
  my $base = _report(verdict => 'performance_passed');
  my $cand = _report(verdict => 'performance_failed');
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  ok $diff->{verdict}{changed}, 'the verdict change is flagged';
  is $diff->{verdict}{baseline},  'performance_passed', 'the baseline verdict is recorded';
  is $diff->{verdict}{candidate}, 'performance_failed', 'the candidate verdict is recorded';
  ok $diff->{summary}{regressed}, 'a verdict falling to failure regresses the run';
};

subtest 'operations present in only one report are reported without a spurious direction' => sub {
  my $base = _report(operations => {publish => _op(error_rate => 0, p99 => 10)});
  my $cand = _report(operations => {publish => _op(error_rate => 0, p99 => 10), subscribe => _op(error_rate => 0, p99 => 5)});
  my $diff = $CMP->compare(baseline => $base, candidate => $cand);

  my %ops = map { $_->{operation} => 1 } @{$diff->{operations}};
  ok $ops{subscribe}, 'a candidate-only operation appears in the comparison';
  my ($sub) = grep { $_->{operation} eq 'subscribe' && $_->{metric} eq 'error_rate' } @{$diff->{operations}};
  is $sub->{direction}, 'incomparable', 'an operation absent from the baseline has no direction';
};

subtest 'edge cases and degenerate inputs are handled' => sub {
  like dies { $CMP->compare(baseline => 'x', candidate => _report()) }, qr/reports\ must\ be\ report\ objects/mx,
    'a non-object report is rejected';

  my $none      = {run => {}, thresholds => [], metrics => {operations => {}}};
  my $diff_none = $CMP->compare(baseline => $none, candidate => $none);
  ok !$diff_none->{verdict}{changed}, 'two absent verdicts compare as unchanged';
  ok !$diff_none->{summary}{regressed}, 'absent verdicts do not regress the run';

  my $one = $CMP->compare(baseline => $none, candidate => _report(verdict => 'smoke_passed'));
  ok $one->{verdict}{changed}, 'a verdict appearing on only one side is a change';

  my $b = _report(thresholds => [_threshold(id => 't', status => 'not_evaluated')]);
  my $c = _report(thresholds => [_threshold(id => 't', status => 'passed')]);
  is $CMP->compare(baseline => $b, candidate => $c)->{thresholds}[0]{change}, 'changed',
    'a status transition that is neither to nor from failed is a neutral change';

  my $missing = {run => {}, thresholds => [], metrics => {operations => {publish => {error_rate => 0.1}}}};
  my $present = _report(operations => {publish => _op(error_rate => 0.1, p99 => 10)});
  my ($p99) = grep { $_->{operation} eq 'publish' && $_->{metric} eq 'latency_ms.p99' }
    @{$CMP->compare(baseline => $missing, candidate => $present)->{operations}};
  is $p99->{direction}, 'incomparable', 'an operation missing its latency block is incomparable';
};

subtest 'an aborted candidate run regresses against a passing baseline' => sub {
  my $diff = $CMP->compare(baseline => _report(verdict => 'performance_passed'), candidate => _report(verdict => 'aborted'));
  ok $diff->{summary}{regressed}, 'an aborted run regresses against a passing baseline';
};

done_testing;
