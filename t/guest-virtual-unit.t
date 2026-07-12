use strictures 2;

use File::Spec;
use File::Temp  qw(tempdir);
use FindBin;
use POSIX qw(WNOHANG);
use Test2::V0;
use Time::HiRes qw(sleep time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Guest::Virtual;

my $tmp = tempdir(CLEANUP => 1);

sub _guest {
  my (%override) = @_;
  return Overnet::Burner::Guest::Virtual->new(
    name     => 'worker-guest-001',
    role     => 'workers',
    address  => '127.0.0.1',
    port     => 40_022,
    user     => 'burner',
    key      => '/keys/id',
    pid_file => File::Spec->catfile($tmp, 'default.pid'),
    accel    => 'tcg',
    %override,
  );
}

subtest 'the virtual guest identifies its transport and method' => sub {
  my $guest = _guest();
  is $guest->provision_method, 'virtual', 'the guest reports the virtual method';
  is $guest->transport,        'ssh',     'transport is the inherited SSH transport';
  is $guest->accel,            'tcg',     'the guest records the accelerator it actually ran with';
  my @options = $guest->_transport_options;
  ok scalar(grep { $_ eq 'UserKnownHostsFile=/dev/null' } @options),
    'host key verification is disabled for fresh snapshot boots';
  ok scalar(grep { $_ eq 'StrictHostKeyChecking=no' } @options), 'strict host key checking is off';
};

subtest '_vm_pid reads the pid file and tolerates absence' => sub {
  my $present = File::Spec->catfile($tmp, 'present.pid');
  _spew($present, "54321\n");
  is _guest(pid_file => $present)->_vm_pid, 54_321, 'a pid file yields its pid';

  my $empty = File::Spec->catfile($tmp, 'empty.pid');
  _spew($empty, q{});
  is _guest(pid_file => $empty)->_vm_pid, undef, 'an empty pid file yields no pid';

  is _guest(pid_file => File::Spec->catfile($tmp, 'missing.pid'))->_vm_pid, undef,
    'a missing pid file yields no pid';
};

subtest 'destroy is a no-op when there is no vm to kill' => sub {
  my $guest = _guest(pid_file => File::Spec->catfile($tmp, 'no-vm.pid'));
  is $guest->destroy, 1, 'destroying a guest with no pid file succeeds';
};

subtest 'destroy terminates the vm process and is idempotent' => sub {
  my $pid_file = File::Spec->catfile($tmp, 'live.pid');
  my $child    = _spawn_sleeper(0);
  _spew($pid_file, "$child\n");

  my $guest = _guest(pid_file => $pid_file);
  is $guest->destroy, 1, 'destroy reports success';
  ok _reaped($child), 'the vm process was terminated';

  is $guest->destroy, 1, 'a second destroy is an idempotent no-op';
};

subtest 'destroy skips the kill escalation when the vm is already gone' => sub {
  # A pid that named a process which has already exited and been reaped:
  # kill(0) reports it gone, so the grace loop never runs and the KILL
  # escalation is skipped.
  my $dead     = _dead_pid();
  my $pid_file = File::Spec->catfile($tmp, 'dead.pid');
  _spew($pid_file, "$dead\n");

  my $guest = _guest(pid_file => $pid_file);
  is $guest->destroy, 1, 'destroying a guest whose vm already exited succeeds';
};

subtest 'destroy escalates to KILL when TERM is ignored' => sub {
  my $pid_file = File::Spec->catfile($tmp, 'stubborn.pid');
  my $child    = _spawn_sleeper(1);
  _spew($pid_file, "$child\n");

  my $guest = _guest(pid_file => $pid_file);
  is $guest->destroy, 1, 'destroy still returns success after escalating';
  ok _reaped($child), 'a process that ignores TERM is killed';
};

done_testing;

sub _spawn_sleeper {
  my ($ignore_term) = @_;
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    ## no critic (RequireLocalizedPunctuationVars)
    $SIG{TERM} = 'IGNORE' if $ignore_term;
    sleep 100;
    exit 0;
  }
  return $pid;
}

sub _dead_pid {
  my $pid = fork;
  die "fork: $!" if !defined $pid;
  if (!$pid) { exit 0 }
  waitpid $pid, 0;    # reap it so the pid is fully gone, not a zombie
  return $pid;
}

sub _reaped {
  my ($pid) = @_;
  my $deadline = time + 10;
  while (time < $deadline) {
    return 1 if waitpid($pid, WNOHANG) == $pid;
    sleep 0.05;
  }
  kill 'KILL', $pid;
  waitpid $pid, 0;
  return 0;
}

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print: $!";
  close $fh or die "close: $!";
  return;
}
