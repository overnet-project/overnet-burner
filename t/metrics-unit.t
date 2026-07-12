use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Util qw(write_file);

my $M   = 'Overnet::Burner::Metrics';
my $tmp = tempdir(CLEANUP => 1);

subtest 'validate_event enforces the event contract' => sub {
  my ($ok) = $M->validate_event(_event());
  ok $ok, 'a well formed event validates';

  is [$M->validate_event('nope')], [0, 'event must be an object'], 'a non-object is rejected';
  is [$M->validate_event(_event(metric_version => 2))]->[1], 'metric_version must be 1',
    'the metric version must be 1';
  is [$M->validate_event(_event(run_id => q{}))]->[1], 'run_id is required', 'identity fields are required';
  is [$M->validate_event(_event(started_at => 'not-a-time'))]->[1],
    'started_at must be an RFC 3339 UTC timestamp', 'timestamps must be RFC 3339 UTC';
  is [$M->validate_event(_event(duration_ms => undef))]->[1], 'duration_ms must be a non-negative number',
    'a missing duration is rejected';
  is [$M->validate_event(_event(duration_ms => -1))]->[1], 'duration_ms must be a non-negative number',
    'a negative duration is rejected';
  is [$M->validate_event(_event(duration_ms => []))]->[1], 'duration_ms must be a non-negative number',
    'a non-scalar duration is rejected';
  is [$M->validate_event(_event(status => 'maybe'))]->[1], 'status must be success or error',
    'status must be success or error';
  is [$M->validate_event(_event(status => 'error', error => q{}))]->[1], 'error must be a non-empty string',
    'a present error must be non-empty';
};

subtest 'read_stream skips blanks and rejects malformed input' => sub {
  my $good = File::Spec->catfile($tmp, 'good.jsonl');
  write_file($good, "\n  \n" . _json(_event()) . "\n");
  is scalar @{$M->read_stream($good)}, 1, 'blank lines are skipped';

  my $malformed = File::Spec->catfile($tmp, 'malformed.jsonl');
  write_file($malformed, "not json at all\n");
  like dies { $M->read_stream($malformed) }, qr/malformed\ JSON/mx, 'malformed JSON is fatal';

  my $invalid = File::Spec->catfile($tmp, 'invalid.jsonl');
  write_file($invalid, _json(_event(status => 'maybe')) . "\n");
  like dies { $M->read_stream($invalid) }, qr/invalid\ metric\ event/mx, 'an invalid event is fatal';
};

subtest 'summarize aggregates operations and defenses' => sub {
  like dies { $M->summarize('nope') }, qr/array\ reference/mx, 'summarize needs an array';

  my $empty = $M->summarize([]);
  is $empty->{overall}{count}, 0, 'an empty run has no operations';
  is $empty->{overall}{error_rate}, 0, 'an empty run has a zero error rate';

  my $summary = $M->summarize(
    [
      _event(operation => 'publish', status => 'success', duration_ms => 10),
      _event(operation => 'publish', status => 'error',   duration_ms => 20, error => 'rejected'),
      _event(operation => 'flood', status => 'error', duration_ms => 5, error => 'blocked', defended => 1, defended_correct => 1),
      _event(operation => 'flood', status => 'success', duration_ms => 5, defended => 0, defended_correct => 0),
    ]
  );
  is $summary->{operations}{publish}{error_rate}, 0.5, 'the publish error rate is measured';
  is $summary->{operations}{flood}{defended_count}, 1, 'defended abuse operations are counted';
  ok defined $summary->{operations}{publish}{latency_ms}{p50}, 'latency percentiles are computed';
};

subtest 'summarize_stream_files reads and phase-filters streams' => sub {
  like dies { $M->summarize_stream_files($tmp, 'nope') }, qr/array\ reference/mx,
    'the streams argument must be an array';

  my $rel = 'metrics/rel.jsonl';
  write_file(File::Spec->catfile(_mkpath($tmp, 'metrics'), 'rel.jsonl'),
    _json(_event(operation => 'publish', phase => 'main')) . "\n");
  my $abs = File::Spec->catfile($tmp, 'abs.jsonl');
  write_file($abs, _json(_event(operation => 'query', phase => 'warmup')) . "\n");

  my $all = $M->summarize_stream_files($tmp, [{path => $rel}, {path => $abs}]);
  is $all->{overall}{count}, 2, 'relative and absolute stream paths are both read';

  my $filtered = $M->summarize_stream_files($tmp, [{path => $rel}, {path => $abs}], phase => 'main');
  is $filtered->{overall}{count}, 1, 'a phase filter keeps only that phase';

  my $unphased = File::Spec->catfile($tmp, 'unphased.jsonl');
  write_file($unphased, _json(_event(operation => 'publish')) . "\n");
  like dies { $M->summarize_stream_files($tmp, [{path => $unphased}], phase => 'main') },
    qr/without\ a\ phase/mx, 'a phased run rejects events with no phase';
};

done_testing;

sub _event {
  my (%override) = @_;
  my %event = (
    metric_version => 1,
    run_id         => 'run',
    worker_id      => 'w1',
    host           => 'h1',
    role           => 'publisher',
    operation      => 'publish',
    started_at     => '2026-01-01T00:00:00Z',
    finished_at    => '2026-01-01T00:00:01Z',
    duration_ms    => 1000,
    status         => 'success',
    %override,
  );
  for my $key (keys %override) {
    delete $event{$key} if !defined $override{$key} && $key ne 'duration_ms';
  }
  return \%event;
}

sub _json {
  my ($event) = @_;
  return JSON::PP->new->canonical(1)->encode($event);
}

sub _mkpath {
  my ($root, @parts) = @_;
  my $dir = File::Spec->catdir($root, @parts);
  require File::Path;
  File::Path::make_path($dir);
  return $dir;
}
