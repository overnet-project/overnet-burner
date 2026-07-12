use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use Test2::V0;
use Time::HiRes qw(time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker;

# A minimal concrete worker so the abstract base can be constructed and
# driven directly; run is deliberately left to the base croak.
BEGIN {
  package _TestWorker;
  use Moo;
  extends 'Overnet::Burner::Worker';
  sub expected_role { return 'tester' }
}

subtest 'the abstract base refuses to declare a role or run' => sub {
  like dies { Overnet::Burner::Worker->new(input => _valid()) },
    qr/must\ define\ expected_role/mx, 'the base class has no role';
  like dies { _TestWorker->new(input => _valid())->run },
    qr/must\ define\ run/mx, 'the base run is abstract';
};

subtest 'BUILDARGS validates the worker input document' => sub {
  like dies { _TestWorker->new(input => 'nope') }, qr/input\ must\ be\ a\ hash/mx, 'input must be a hash';
  like dies { _TestWorker->new(input => _valid(run_id => undef)) },
    qr/input\.run_id\ is\ required/mx, 'missing fields are rejected';
  like dies { _TestWorker->new(input => _valid(input_version => '2')) },
    qr/input_version\ must\ be\ 1/mx, 'only version 1 is accepted';
  like dies { _TestWorker->new(input => _valid(role => 'other')) },
    qr/role\ must\ be\ tester/mx, 'the role must match the class';
  like dies { _TestWorker->new(input => _valid(endpoints => {relays => []})) },
    qr/must\ name\ at\ least\ one\ relay/mx, 'at least one relay is required';
  like dies { _TestWorker->new(input => _valid(endpoints => undef)) },
    qr/must\ name\ at\ least\ one\ relay/mx, 'endpoints that are not a mapping name no relay';
  like dies { _TestWorker->new(input => _valid(endpoints => {relays => ['']})) },
    qr/must\ name\ at\ least\ one\ relay/mx, 'an empty relay url names no relay';
  like dies { _TestWorker->new(input => _valid(endpoints => {relays => [{}]})) },
    qr/must\ name\ at\ least\ one\ relay/mx, 'a structured relay entry names no relay';
};

subtest 'the constructor accepts a single hash reference and rejects odd args' => sub {
  my $worker = _TestWorker->new({input => _valid()});
  is $worker->input->{role}, 'tester', 'a single hash reference constructs the worker';
  like dies { _TestWorker->new('lonely') }, qr/hash\ or\ hash\ reference/mx, 'an odd argument list is fatal';
};

subtest 'derive_key requires a seed and worker id' => sub {
  like dies { _TestWorker->derive_key(undef, 'w') }, qr/seed\ is\ required/mx,      'a seed is required';
  like dies { _TestWorker->derive_key('s', undef) }, qr/worker_id\ is\ required/mx, 'a worker id is required';
  is(_TestWorker->derive_key(12345, 'tester')->pubkey_hex,
    _TestWorker->derive_key(12345, 'tester')->pubkey_hex, 'the same seed derives the same key');
};

subtest 'phases default to a single main phase and can be named at elapsed times' => sub {
  my $default = _TestWorker->new(input => _valid());
  is $default->phases, [{name => 'main', start_seconds => 0, duration_seconds => 5}],
    'a run without phases gets one main phase from its duration';
  is $default->phase_name_at(0), 'main', 'the sole phase covers the run';
  is $default->phase_name_at(99), 'main', 'past the end, the last phase name is used';

  my $multi = _TestWorker->new(
    input => _valid(
      phases => [
        {name => 'warmup', start_seconds => 0, duration_seconds => 1},
        {name => 'main',   start_seconds => 1, duration_seconds => 2},
      ],
    ),
  );
  is $multi->phases->[0]{name}, 'warmup', 'explicit phases are returned as given';
  is $multi->phase_name_at(0.5), 'warmup', 'an early time is in the warmup phase';
  is $multi->phase_name_at(1.5), 'main',   'a later time is in the main phase';

  my $with_workload = _TestWorker->new(input => _valid(workload => {object_reads => {rate_per_second => 3}}));
  is $with_workload->phases->[0]{object_reads}, {rate_per_second => 3},
    'the default phase inherits the workload parameters';
};

subtest 'phase_rate reads a rate or defaults to one' => sub {
  is(_TestWorker->phase_rate({rate => 4}, 'rate'), 4, 'a defined rate is used');
  is(_TestWorker->phase_rate({}, 'rate'),          1, 'a missing rate defaults to one');
};

subtest 'idle_until waits until its deadline' => sub {
  my $worker  = _TestWorker->new(input => _valid());
  my $stop    = 0;
  my $started = time;
  is $worker->idle_until($started + 0.15, \$stop), 1, 'idle_until returns true at the deadline';
  ok time - $started >= 0.1, 'it actually waited for the deadline';
};

subtest 'emit_metric rejects an invalid metric event' => sub {
  my $worker = _TestWorker->new(input => _valid());
  $worker->{host} = 'test-host';
  $worker->open_metric_stream;
  like dies { $worker->emit_metric(status => 'success') },
    qr/invalid\ metric\ event/mx, 'a metric missing required fields is fatal';
  $worker->close_metric_stream;
};

subtest 'metric stream errors and idempotent close' => sub {
  my $worker = _TestWorker->new(input => _valid());
  is $worker->close_metric_stream, 1, 'closing before opening is a no-op';

  my $bad = _TestWorker->new(input => _valid(metric_stream => 'no-such-dir/metrics.jsonl'));
  like dies { $bad->open_metric_stream }, qr/open\ /mx, 'opening a stream under a missing directory is fatal';
};

subtest 'the metric stream and readiness marker are written under the run dir' => sub {
  my $run_dir = _run_layout('tester');
  my $worker  = _TestWorker->new(input => _valid(run_dir => $run_dir, workload => {rate => 1}));
  $worker->{host} = 'test-host';
  $worker->open_metric_stream;
  $worker->emit_metric(
    operation   => 'probe',
    started_at  => $worker->iso_timestamp(1_700_000_000),
    finished_at => $worker->iso_timestamp(1_700_000_000.5),
    duration_ms => 500,
    status      => 'success',
  );
  $worker->write_ready_file;
  $worker->close_metric_stream;

  ok -e File::Spec->catfile($run_dir, 'workers', 'tester', 'ready'), 'the ready file was written';
  my $stream = Overnet::Burner::Metrics->read_stream(
    File::Spec->catfile($run_dir, 'metrics', 'tester.jsonl'));
  is scalar @{$stream}, 1, 'the emitted metric was recorded';
  like $stream->[0]{started_at}, qr/\AZ?|[0-9]/mx, 'the timestamp is rendered';
};

done_testing;

sub _valid {
  my (%override) = @_;
  my %input = (
    input_version    => 1,
    run_id           => 'run',
    run_dir          => _run_layout('tester'),
    worker_id        => 'tester',
    role             => 'tester',
    seed             => 12345,
    duration_seconds => 5,
    metric_stream    => 'metrics/tester.jsonl',
    ready_file       => 'workers/tester/ready',
    endpoints        => {relays => ['ws://127.0.0.1:1']},
    %override,
  );
  return \%input;
}

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}
