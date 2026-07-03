use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use JSON::Schema::Modern;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;

my $repo   = "$FindBin::Bin/..";
my $sample = File::Spec->catfile($repo, 'examples', 'metric-events-v1-sample.jsonl');
my $schema =
  JSON::decode_json(_slurp(File::Spec->catfile($repo, 'schemas', 'metric-event-v1.schema.json')));

my %base_event = (
  metric_version => 1,
  run_id         => 'run-001',
  worker_id      => 'publisher-001',
  host           => 'host-a',
  role           => 'publisher',
  operation      => 'publish',
  started_at     => '2026-07-02T18:00:00Z',
  finished_at    => '2026-07-02T18:00:00.010Z',
  duration_ms    => 10,
  status         => 'success',
);

subtest 'published sample stream validates against the metric event schema' => sub {
  my $validator = JSON::Schema::Modern->new;
  my $events    = Overnet::Burner::Metrics->read_stream($sample);
  is scalar @{$events}, 8, 'sample stream contains the expected number of events';

  for my $index (0 .. $#{$events}) {
    my $result = $validator->evaluate($events->[$index], $schema);
    ok $result->valid, 'sample event ' . ($index + 1) . ' validates against metric-event-v1';
  }
};

subtest 'published abuse sample stream validates and summarizes' => sub {
  my $validator = JSON::Schema::Modern->new;
  my $abuse     = File::Spec->catfile($repo, 'examples', 'abuse-metric-events-v1-sample.jsonl');
  my $events    = Overnet::Burner::Metrics->read_stream($abuse);
  ok @{$events} >= 1, 'abuse sample stream loads';

  for my $index (0 .. $#{$events}) {
    my $result = $validator->evaluate($events->[$index], $schema);
    ok $result->valid, 'abuse sample event ' . ($index + 1) . ' validates against metric-event-v1';
  }

  my $summary = Overnet::Burner::Metrics->summarize($events);
  is $summary->{operations}{flood_publish}{defended_ratio},         0.5, 'the flood sample is half defended';
  is $summary->{operations}{malformed_publish}{defended_ratio},     1,   'the malformed sample is fully defended';
  is $summary->{operations}{replay_submit}{defended_correct_ratio}, 1,   'the replay sample is correctly defended';
};

subtest 'validate_event accepts a minimal valid event' => sub {
  my ($ok, $error) = Overnet::Burner::Metrics->validate_event({%base_event});
  is $ok,    1,     'minimal event is accepted';
  is $error, undef, 'no error is reported';

  my ($ok_extra, $error_extra) = Overnet::Burner::Metrics->validate_event(
    {
      %base_event,
      status => 'error',
      error  => 'publish timed out',
      extra  => 'operation-specific member',
    }
  );
  is $ok_extra,    1,     'error event with operation-specific members is accepted';
  is $error_extra, undef, 'no error is reported for operation-specific members';
};

subtest 'validate_event rejects one rule at a time' => sub {
  my @cases = (
    ['event must be an object',                       'not an object'],
    ['metric_version must be 1',                      {%base_event, metric_version => 2}],
    ['run_id is required',                            {%base_event, run_id         => undef}],
    ['run_id is required',                            {%base_event, run_id         => q{}}],
    ['worker_id is required',                         {%base_event, worker_id      => q{}}],
    ['host is required',                              {%base_event, host           => q{}}],
    ['role is required',                              {%base_event, role           => q{}}],
    ['operation is required',                         {%base_event, operation      => q{}}],
    ['started_at must be an RFC 3339 UTC timestamp',  {%base_event, started_at     => '2026-07-02 18:00:00'}],
    ['finished_at must be an RFC 3339 UTC timestamp', {%base_event, finished_at    => '2026-07-02T18:00:00+01:00'}],
    ['duration_ms must be a non-negative number',     {%base_event, duration_ms    => -1}],
    ['duration_ms must be a non-negative number',     {%base_event, duration_ms    => 'fast'}],
    ['status must be success or error',               {%base_event, status         => 'ok'}],
    ['error must be a non-empty string',              {%base_event, status         => 'error', error => q{}}],
  );

  for my $case (@cases) {
    my ($expected, $event) = @{$case};
    my ($ok,       $error) = Overnet::Burner::Metrics->validate_event($event);
    is $ok, 0, "rejected: $expected";
    like $error, qr/\Q$expected\E/, "error names the rule: $expected";
  }

  my ($missing_ok, $missing_error) =
    Overnet::Burner::Metrics->validate_event({%base_event, metric_version => undef});
  is $missing_ok, 0, 'missing metric_version is rejected';
  like $missing_error, qr/metric_version must be 1/, 'missing metric_version names the rule';
};

subtest 'read_stream rejects malformed streams with line context' => sub {
  my $tmp = tempdir(CLEANUP => 1);

  my $malformed_json = File::Spec->catfile($tmp, 'malformed.jsonl');
  _spew($malformed_json, _event_line({%base_event}) . "not json\n");
  like dies { Overnet::Burner::Metrics->read_stream($malformed_json) },
    qr/\Qmalformed.jsonl\E line 2/, 'malformed JSON reports file and line';

  my $invalid_event = File::Spec->catfile($tmp, 'invalid.jsonl');
  _spew($invalid_event, _event_line({%base_event}) . _event_line({%base_event, status => 'ok'}));
  like dies { Overnet::Burner::Metrics->read_stream($invalid_event) },
    qr/\Qinvalid.jsonl\E line 2.*status must be success or error/,
    'invalid event reports file, line, and rule';

  my $empty = File::Spec->catfile($tmp, 'empty.jsonl');
  _spew($empty, q{});
  is(Overnet::Burner::Metrics->read_stream($empty), [], 'empty stream reads as no events');

  like dies { Overnet::Burner::Metrics->read_stream(File::Spec->catfile($tmp, 'absent.jsonl')) },
    qr/absent\.jsonl/, 'missing stream file is an error';
};

subtest 'summarize matches the documented sample numbers' => sub {
  my $events  = Overnet::Burner::Metrics->read_stream($sample);
  my $summary = Overnet::Burner::Metrics->summarize($events);

  is $summary->{operations}{publish},
    {
    count         => 5,
    success_count => 4,
    error_count   => 1,
    error_rate    => 0.2,
    latency_ms    => {
      min  => 10,
      p50  => 20,
      p90  => 40,
      p95  => 40,
      p99  => 40,
      max  => 40,
      mean => 25,
    },
    },
    'publish summary matches hand-computed values';

  is $summary->{operations}{subscription_fanout}{latency_ms},
    {
    min  => 100,
    p50  => 100,
    p90  => 200,
    p95  => 200,
    p99  => 200,
    max  => 200,
    mean => 150,
    },
    'two-sample percentiles use nearest rank';

  is $summary->{operations}{query}{latency_ms},
    {
    min  => 50,
    p50  => 50,
    p90  => 50,
    p95  => 50,
    p99  => 50,
    max  => 50,
    mean => 50,
    },
    'single-sample summary repeats the sample';

  is $summary->{overall},
    {
    count         => 8,
    success_count => 7,
    error_count   => 1,
    error_rate    => 0.125,
    },
    'overall counters aggregate every operation';

  is(Overnet::Burner::Metrics->summarize($events), $summary, 'summarization is deterministic');
};

subtest 'abuse operations summarize defended ratios' => sub {
  my @events = map {
    {
      %base_event,
        worker_id => 'flooder-001',
        role      => 'flooder',
        operation => 'flood_publish',
        %{$_},
    }
  } (
    {
      status           => 'error',
      outcome          => 'rejected',
      error_category   => 'policy rejection',
      defended         => JSON::true,
      defended_correct => JSON::true
    },
    {
      status           => 'error',
      outcome          => 'rejected',
      error_category   => 'policy rejection',
      defended         => JSON::true,
      defended_correct => JSON::true
    },
    {
      status           => 'error',
      outcome          => 'rejected',
      error_category   => 'invalid input',
      defended         => JSON::true,
      defended_correct => JSON::false
    },
    {status => 'success', outcome => 'accepted', defended => JSON::false, defended_correct => JSON::false},
  );

  my $summary = Overnet::Burner::Metrics->summarize(\@events);
  my $op      = $summary->{operations}{flood_publish};

  is $op->{count},                  4,    'every abuse attempt is counted';
  is $op->{defended_count},         3,    'three of four attempts were defended';
  is $op->{defended_ratio},         0.75, 'defended_ratio is defended over total';
  is $op->{defended_correct_count}, 2,    'two were defended with the correct semantics';
  is $op->{defended_correct_ratio}, 0.5,  'defended_correct_ratio is correct defenses over total';
};

subtest 'honest operations carry no defended fields' => sub {
  my $summary = Overnet::Burner::Metrics->summarize([{%base_event}]);
  my $op      = $summary->{operations}{publish};

  ok !exists $op->{defended_ratio},         'a publish summary has no defended_ratio';
  ok !exists $op->{defended_correct_ratio}, 'a publish summary has no defended_correct_ratio';
};

subtest 'latency is null when an operation never succeeds' => sub {
  my $summary = Overnet::Burner::Metrics->summarize(
    [
      {%base_event, status => 'error', error => 'boom', duration_ms => 700},
      {%base_event, status => 'error', error => 'boom', duration_ms => 900},
    ]
  );

  is $summary->{operations}{publish},
    {
    count         => 2,
    success_count => 0,
    error_count   => 2,
    error_rate    => 1,
    latency_ms    => {
      min  => undef,
      p50  => undef,
      p90  => undef,
      p95  => undef,
      p99  => undef,
      max  => undef,
      mean => undef,
    },
    },
    'error-only operation reports null latency and full error accounting';
};

subtest 'summarize_stream_files combines per-actor streams' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  mkdir File::Spec->catdir($tmp, 'metrics') or die "mkdir: $!";

  _spew(
    File::Spec->catfile($tmp, 'metrics', 'publisher-001.jsonl'),
    _event_line({%base_event, duration_ms => 10}) . _event_line({%base_event, duration_ms => 30}),
  );
  _spew(
    File::Spec->catfile($tmp, 'metrics', 'subscriber-001.jsonl'),
    _event_line(
      {
        %base_event,
        worker_id => 'subscriber-001',
        role      => 'subscriber',
        operation => 'subscription_fanout',
      }
    ),
  );

  my $summary =
    Overnet::Burner::Metrics->summarize_stream_files($tmp,
    [{path => 'metrics/publisher-001.jsonl'}, {path => 'metrics/subscriber-001.jsonl'},],
    );

  is $summary->{operations}{publish}{count},             2, 'publisher stream is summarized';
  is $summary->{operations}{subscription_fanout}{count}, 1, 'subscriber stream is summarized';
  is $summary->{overall}{count},                         3, 'streams combine into overall counters';
};

subtest 'a phase filter summarizes only the named phase' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  mkdir File::Spec->catdir($tmp, 'metrics') or die "mkdir: $!";

  _spew(
    File::Spec->catfile($tmp, 'metrics', 'publisher-001.jsonl'),
    _event_line({%base_event, phase => 'warmup', status => 'error', error => 'cold start'})
      . _event_line({%base_event, phase => 'main',     duration_ms => 10})
      . _event_line({%base_event, phase => 'main',     duration_ms => 20})
      . _event_line({%base_event, phase => 'cooldown', duration_ms => 99}),
  );

  my $summary =
    Overnet::Burner::Metrics->summarize_stream_files($tmp, [{path => 'metrics/publisher-001.jsonl'}], phase => 'main',);

  is $summary->{operations}{publish}{count},           2,  'only main phase events are summarized';
  is $summary->{operations}{publish}{error_count},     0,  'warmup errors do not pollute the main summary';
  is $summary->{operations}{publish}{latency_ms}{max}, 20, 'cooldown latencies do not pollute the main summary';
  is $summary->{overall}{error_rate},                  0,  'overall counters cover the main phase only';
};

subtest 'a phase filter rejects untagged events' => sub {
  my $tmp = tempdir(CLEANUP => 1);
  mkdir File::Spec->catdir($tmp, 'metrics') or die "mkdir: $!";

  _spew(
    File::Spec->catfile($tmp, 'metrics', 'publisher-001.jsonl'),
    _event_line({%base_event, phase => 'main', duration_ms => 10}) . _event_line({%base_event, duration_ms => 20}),
  );

  my $error;
  eval {
    Overnet::Burner::Metrics->summarize_stream_files($tmp, [{path => 'metrics/publisher-001.jsonl'}], phase => 'main',);
    1;
  } or $error = $@;
  like $error, qr/without\ a\ phase/mx, 'an event without a phase cannot be judged in a multi-phase run';
};

done_testing;

sub _event_line {
  my ($event) = @_;
  return JSON->new->canonical(1)->encode($event) . "\n";
}

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return $content;
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh            or die "close $path: $!";
  return;
}
