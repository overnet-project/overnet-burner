use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Guest::Exec;

my $tmp   = tempdir(CLEANUP => 1);
my $guest = Overnet::Burner::Guest::Exec->new(name => 'local', role => 'workers');

subtest 'guest identity' => sub {
  is $guest->name,      'local',   'guest records its name';
  is $guest->role,      'workers', 'guest records its role';
  is $guest->transport, 'exec',    'the local guest uses the exec transport';
};

subtest 'file operations' => sub {
  my $dir = File::Spec->catdir($tmp, 'nested', 'deep');
  $guest->make_path($dir);
  ok -d $dir, 'make_path creates directories';

  my $path = File::Spec->catfile($dir, 'note.txt');
  $guest->write_file($path, "hello guest\n");
  is $guest->read_file($path), "hello guest\n", 'write_file and read_file round trip';

  is $guest->read_file(File::Spec->catfile($dir, 'absent.txt')), undef,
    'reading a missing file returns undef instead of dying';
};

subtest 'run_command runs a one-shot command to completion' => sub {
  my $ok = $guest->run_command(command => 'printf out; printf err >&2; exit 0');
  is $ok->{exit_code}, 0,     'a successful command reports exit code 0';
  is $ok->{stdout},    'out', 'stdout is captured';
  is $ok->{stderr},    'err', 'stderr is captured separately from stdout';

  my $fail = $guest->run_command(command => 'exit 7');
  is $fail->{exit_code}, 7, 'a nonzero exit code is reported';

  my $env = $guest->run_command(command => 'printf "%s" "$GUEST_TEST_VALUE"', env => {GUEST_TEST_VALUE => 'from-env'});
  is $env->{stdout}, 'from-env', 'the command environment is applied';

  my $work = File::Spec->catdir($tmp, 'run-command-cwd');
  $guest->make_path($work);
  my $cwd = $guest->run_command(command => 'pwd', cwd => $work);
  chomp(my $observed = $cwd->{stdout});
  is $observed, $work, 'the command runs in the requested working directory';

  my $signaled = $guest->run_command(command => 'kill -TERM $$');
  is $signaled->{exit_code}, undef, 'a signal-killed command reports an undefined exit code';
};

subtest 'process lifecycle' => sub {
  my $stdout = File::Spec->catfile($tmp, 'proc.stdout');
  my $stderr = File::Spec->catfile($tmp, 'proc.stderr');

  my $handle = $guest->launch(
    command => 'printf "%s" "$GUEST_TEST_VALUE"; exit 7',
    env     => {GUEST_TEST_VALUE => 'from-the-guest'},
    stdout  => $stdout,
    stderr  => $stderr,
  );
  ok $handle, 'launch returns a process handle';

  my $deadline = time + 10;
  my $status;
  while (time < $deadline) {
    $status = $guest->try_reap($handle);
    last if defined $status;
    sleep 0.05;
  }
  ok defined $status, 'the process was reaped';
  is $status >> 8,               7,                'the exit status is preserved';
  is $guest->read_file($stdout), 'from-the-guest', 'launch passes environment and captures stdout';
};

subtest 'signals terminate a stubborn process' => sub {
  my $handle = $guest->launch(
    command => 'sleep 60',
    stdout  => File::Spec->catfile($tmp, 'sleeper.stdout'),
    stderr  => File::Spec->catfile($tmp, 'sleeper.stderr'),
  );
  is $guest->try_reap($handle), undef, 'a running process is not reaped';

  $guest->signal($handle, 'TERM');
  my $deadline = time + 10;
  my $status;
  while (time < $deadline) {
    $status = $guest->try_reap($handle);
    last if defined $status;
    sleep 0.05;
  }
  ok defined $status, 'a signaled process is reaped';
  isnt $status, 0, 'the signal is visible in the status';
};

subtest 'readiness is aggregated per guest' => sub {
  my $workers_root = File::Spec->catdir($tmp, 'workers');
  $guest->make_path(File::Spec->catdir($workers_root, 'publisher-001'));
  $guest->make_path(File::Spec->catdir($workers_root, 'subscriber-001'));

  is $guest->ready_actors($workers_root), [], 'no actors are ready before ready files exist';

  $guest->write_file(File::Spec->catfile($workers_root, 'subscriber-001', 'ready'), q{});
  is $guest->ready_actors($workers_root), ['subscriber-001'], 'a ready file marks its actor ready';

  $guest->write_file(File::Spec->catfile($workers_root, 'publisher-001', 'ready'), q{});
  is [sort @{$guest->ready_actors($workers_root)}], ['publisher-001', 'subscriber-001'],
    'the aggregate probe reports every ready actor in one call';

  is $guest->ready_actors(File::Spec->catdir($tmp, 'no-such-root')), [], 'a missing workers root reports nothing ready';
};

done_testing;
