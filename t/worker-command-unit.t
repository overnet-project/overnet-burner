use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::WorkerCommand;

# In-process coverage for the worker command dispatcher: the environment and
# input validation exit codes, a role that fails at runtime, and a role that
# runs to completion.

subtest 'a missing environment variable is a usage error' => sub {
  my ($rc, $err) = _run_with(undef);
  is $rc, 2, 'a missing input path exits 2';
  like $err, qr/OVERNET_BURNER_WORKER_INPUT/mx, 'the error names the environment variable';
};

subtest 'a non-existent input document is an error' => sub {
  my ($rc, $err) = _run_with(File::Spec->catfile(tempdir(CLEANUP => 1), 'absent.json'));
  is $rc, 2, 'a missing file exits 2';
  like $err, qr/does\ not\ exist/mx, 'the error names the missing document';
};

subtest 'an input document without a role is an error' => sub {
  my $path = _write_json(['not', 'a', 'mapping']);
  my ($rc, $err) = _run_with($path);
  is $rc, 2, 'an input without a role exits 2';
  like $err, qr/does\ not\ declare\ a\ role/mx, 'the error names the missing role';
};

subtest 'an unsupported role is an error' => sub {
  my $path = _write_json({role => 'time_traveler'});
  my ($rc, $err) = _run_with($path);
  is $rc, 2, 'an unknown role exits 2';
  like $err, qr/unsupported\ worker\ role:\ time_traveler/mx, 'the error names the unsupported role';
};

subtest 'a worker that fails at runtime exits 1' => sub {
  my $run_dir = _layout('object-reader-x');
  my $path    = _write_json(
    {
      input_version    => 1,
      run_id           => 'run',
      run_dir          => $run_dir,
      worker_id        => 'object-reader-x',
      role             => 'object_reader',
      seed             => 12345,
      duration_seconds => 1,
      metric_stream    => 'metrics/object-reader-x.jsonl',
      ready_file       => 'workers/object-reader-x/ready',
      endpoints        => {relays       => ['ws://127.0.0.1:1']},
      workload         => {object_reads => {rate_per_second => 1, objects => []}},
    }
  );
  my ($rc, $err) = _run_with($path);
  is $rc, 1, 'a worker whose run croaks exits 1';
  like $err, qr/object_reads\.objects/mx, 'the worker error is reported';
};

subtest 'a worker that completes exits 0' => sub {
  my $run_dir = _layout('observer-x');
  my $path    = _write_json(
    {
      input_version    => 1,
      run_id           => 'run',
      run_dir          => $run_dir,
      worker_id        => 'observer-x',
      role             => 'observer',
      seed             => 12345,
      duration_seconds => 0.3,
      metric_stream    => 'metrics/observer-x.jsonl',
      ready_file       => 'workers/observer-x/ready',
      endpoints        => {relays => ['ws://127.0.0.1:1']},
      workload         => {observer => {probe_interval_seconds => 0.2}},
    }
  );
  my ($rc) = _run_with($path);
  is $rc, 0, 'a worker that runs to its duration exits 0';
  ok -e File::Spec->catfile($run_dir, 'workers', 'observer-x', 'ready'), 'the worker declared readiness';
};

done_testing;

sub _run_with {
  my ($path) = @_;
  my $buffer = q{};
  open my $capture, '>', \$buffer or die "open buffer: $!";
  my $rc;
  {
    local *STDERR = $capture;
    local $ENV{OVERNET_BURNER_WORKER_INPUT} = $path;
    delete local $ENV{OVERNET_BURNER_WORKER_INPUT} if !defined $path;
    $rc = Overnet::Burner::WorkerCommand->run_from_environment;
  }
  close $capture or die "close buffer: $!";
  return ($rc, $buffer);
}

sub _write_json {
  my ($data) = @_;
  my $path = File::Spec->catfile(tempdir(CLEANUP => 1), 'input.json');
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} JSON->new->canonical(1)->encode($data) or die "print: $!";
  close $fh or die "close: $!";
  return $path;
}

sub _layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}
