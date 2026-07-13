use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Runner;
use Overnet::Burner::RunLedger;
use POSIX ();

package Overnet::Burner::Runner::Scripted {
  use Moo;

  extends 'Overnet::Burner::Runner';

  no Moo;

  sub prepare {
    my ($self) = @_;
    return $self->{on_prepare} ? $self->{on_prepare}->($self) : 1;
  }
  sub start   {1}
  sub observe {1}
  sub stop    {1}
  sub collect {1}

  sub teardown_on_signal {
    my ($self, $signal) = @_;
    return $self->{on_teardown}
      ? $self->{on_teardown}->($self, $signal)
      : $self->SUPER::teardown_on_signal($signal);
  }

  sub cleanup_after_lifecycle_failure {
    my ($self, %args) = @_;
    return $self->{on_cleanup}
      ? $self->{on_cleanup}->($self, %args)
      : $self->SUPER::cleanup_after_lifecycle_failure(%args);
  }
}

my $repo          = "$FindBin::Bin/..";
my $scenario_path = "$repo/scenarios/single-relay-baseline.yml";
my $scenario      = Overnet::Burner::Config->load_file($scenario_path);
my $tmp           = tempdir(CLEANUP => 1);
my @times         = (
  '2026-06-27T14:00:00Z', '2026-06-27T14:00:01Z', '2026-06-27T14:00:02Z', '2026-06-27T14:00:03Z',
  '2026-06-27T14:00:04Z', '2026-06-27T14:00:05Z', '2026-06-27T14:00:06Z', '2026-06-27T14:00:07Z',
  '2026-06-27T14:00:08Z', '2026-06-27T14:00:09Z', '2026-06-27T14:00:10Z',
);

my $ledger = Overnet::Burner::RunLedger->create(
  scenario      => $scenario,
  scenario_path => $scenario_path,
  runs_dir      => "$tmp/runs",
  run_id        => 'noop-runner-001',
  now           => sub { shift @times },
  host_facts    => {
    hostname => 'builder-host',
    os       => 'linux',
    arch     => 'x86_64',
  },
  repo_sha    => 'abc123',
  rex_version => undef,
);
my $plan = Overnet::Burner::RunLedger->load_plan($ledger->{run_dir});

my $load_failed_error;
my $load_failed = do {
  local @INC = (sub { die "synthetic runner module load failure\n" }, @INC);
  my $loaded = eval {
    Overnet::Burner::Runner->load(
      name    => 'noop',
      ledger  => $ledger,
      plan    => $plan,
      run_dir => $ledger->{run_dir},
    );
    1;
  };
  $load_failed_error = $@;
  !$loaded;
};
ok $load_failed, 'load fails when the runner module cannot be required';
like $load_failed_error, qr/synthetic\ runner\ module\ load\ failure/mx, 'load reports the module load error';

my $runner = Overnet::Burner::Runner->load(
  name    => 'noop',
  ledger  => $ledger,
  plan    => $plan,
  run_dir => $ledger->{run_dir},
);

is $runner->name, 'noop', 'loads noop runner by name';

my $base_runner = Overnet::Burner::Runner->new(
  {
    name    => 'noop',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  }
);
isa_ok $base_runner, ['Overnet::Burner::Runner'], 'base runner hashref constructor';

my @progress_events;
my $progress_runner = Overnet::Burner::Runner->new(
  {
    name              => 'noop',
    ledger            => $ledger,
    plan              => $plan,
    run_dir           => $ledger->{run_dir},
    progress_observer => sub { push @progress_events, shift },
  }
);
$progress_runner->_progress_event(action => 'ensure_image', target => 'containers', status => 'started');
is \@progress_events,
  [
  {
    runner     => 'noop',
    phase      => 'prepare',
    event_kind => 'progress',
    action     => 'ensure_image',
    target     => 'containers',
    status     => 'started',
  }
  ],
  'base runner emits direct progress events through the observer';

my $summary = $runner->run_lifecycle;

is $summary->{runner}, 'noop', 'summary records runner name';
is $summary->{phases},
  {
  prepare => 'completed',
  start   => 'completed',
  observe => 'completed',
  stop    => 'completed',
  collect => 'completed',
  },
  'summary records completed lifecycle phases';
is $summary->{actor_counts},
  {
  relays         => 1,
  publishers     => 1,
  subscribers    => 1,
  query_readers  => 1,
  object_readers => 1,
  total          => 5,
  },
  'summary records deterministic actor counts';

my $runner_log_path = File::Spec->catfile($ledger->{run_dir}, 'logs', 'runner.jsonl');
open my $log_fh, '<', $runner_log_path or die "open $runner_log_path: $!";
my @events = map { JSON::decode_json($_) } <$log_fh>;

is [map {"$_->{phase}:$_->{status}"} @events],
  [
  'prepare:started', 'prepare:completed', 'start:started', 'start:completed',
  'observe:started', 'observe:completed', 'stop:started',  'stop:completed',
  'collect:started', 'collect:completed',
  ],
  'runner log records lifecycle event order';

is $events[0]{runner},       'noop',                   'event records runner name';
is $events[0]{timestamp},    '2026-06-27T14:00:01Z',   'event timestamp comes from injected clock';
is $events[0]{actor_counts}, $summary->{actor_counts}, 'event records actor counts';

my $artifact_path = File::Spec->catfile($ledger->{run_dir}, 'artifacts', 'noop-runner.json',);
my $artifact      = do {
  open my $artifact_fh, '<', $artifact_path or die "open $artifact_path: $!";
  local $/ = undef;
  JSON::decode_json(<$artifact_fh>);
};

is $artifact, $summary, 'noop runner writes deterministic summary artifact';

my $unknown = eval {
  Overnet::Burner::Runner->load(
    name    => 'missing',
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $ledger->{run_dir},
  );
  1;
};
ok !$unknown, 'rejects unknown runner';
like $@, qr/unknown\ runner:\ missing/mx, 'reports unknown runner name';

my $odd_args = eval { Overnet::Burner::Runner->new('solo-argument'); 1 };
ok !$odd_args, 'rejects an odd argument list';
like $@, qr/constructor\ arguments\ must\ be\ a\ hash\ or\ hash\ reference/mx, 'reports the invalid argument list';

my $workers_runner = Overnet::Burner::Runner->load(
  name                   => 'rex-local-workers',
  ledger                 => $ledger,
  plan                   => $plan,
  run_dir                => $ledger->{run_dir},
  worker_command_default => ['/bin/true'],
);
is $workers_runner->worker_command_default, ['/bin/true'],
  'load passes worker_command_default to a runner that accepts it';

my $sparse_runner = Overnet::Burner::Runner->new(
  name    => 'noop',
  ledger  => $ledger,
  plan    => {relays => [{actor_id => 'relay-001'}]},
  run_dir => $ledger->{run_dir},
);
is $sparse_runner->actor_counts,
  {
  relays         => 1,
  publishers     => 0,
  subscribers    => 0,
  query_readers  => 0,
  object_readers => 0,
  total          => 1,
  },
  'actor_counts treats missing plan roles as empty';
ok $sparse_runner->_progress_event(action => 'noticed'), 'progress events without an observer are dropped';

subtest 'a failed phase records the failure and still runs cleanup' => sub {
  my $failing_tmp    = tempdir(CLEANUP => 1);
  my $failing_ledger = _scripted_ledger($failing_tmp, 'failing-phase');
  my $failing_runner = Overnet::Burner::Runner::Scripted->new(
    name    => 'noop',
    ledger  => $failing_ledger,
    plan    => $plan,
    run_dir => $failing_ledger->{run_dir},
  );
  my @cleanups;
  $failing_runner->{on_prepare} = sub { die "relay refused to prepare\n" };
  $failing_runner->{on_cleanup} = sub { my (undef, %args) = @_; push @cleanups, \%args; 1 };

  my $completed = eval { $failing_runner->run_lifecycle; 1 };
  my $error     = $@;
  ok !$completed, 'the lifecycle fails when a phase fails';
  like $error, qr/relay\ refused\ to\ prepare/mx, 'the phase error is reported';
  is scalar @cleanups, 1, 'cleanup runs once after the failure';
  is $cleanups[0]{failed_phase}, 'prepare', 'cleanup learns which phase failed';
  is $cleanups[0]{phases}, {prepare => 'failed'}, 'cleanup sees the failed phase map';

  my @events = _runner_events($failing_ledger);
  is $events[-1]{status}, 'failed', 'the runner log records the failed phase';
  like $events[-1]{error}, qr/relay\ refused\ to\ prepare/mx, 'the runner log records the phase error';
};

subtest 'a cleanup failure is appended to the phase error' => sub {
  my $cleanup_tmp    = tempdir(CLEANUP => 1);
  my $cleanup_ledger = _scripted_ledger($cleanup_tmp, 'failing-cleanup');
  my $cleanup_runner = Overnet::Burner::Runner::Scripted->new(
    name    => 'noop',
    ledger  => $cleanup_ledger,
    plan    => $plan,
    run_dir => $cleanup_ledger->{run_dir},
  );
  $cleanup_runner->{on_prepare} = sub { die "relay refused to prepare\n" };
  $cleanup_runner->{on_cleanup} = sub { die "teardown jammed\n" };

  my $completed = eval { $cleanup_runner->run_lifecycle; 1 };
  my $error     = $@;
  ok !$completed, 'the lifecycle fails when phase and cleanup both fail';
  like $error, qr/relay\ refused\ to\ prepare;\ cleanup\ failed:\ teardown\ jammed/mx,
    'the cleanup failure is appended to the phase error';
};

subtest 'a missing phase method fails the lifecycle through the base cleanup' => sub {
  my $base_tmp    = tempdir(CLEANUP => 1);
  my $base_ledger = _scripted_ledger($base_tmp, 'missing-phase');
  my $bare_runner = Overnet::Burner::Runner->new(
    name    => 'noop',
    ledger  => $base_ledger,
    plan    => $plan,
    run_dir => $base_ledger->{run_dir},
  );

  my $completed = eval { $bare_runner->run_lifecycle; 1 };
  my $error     = $@;
  ok !$completed, 'the base runner cannot run undefined phases';
  like $error, qr/Can't\ locate\ object\ method/mx, 'the missing phase method is reported';
};

subtest 'termination signals tear down guests and re-raise' => sub {
  my $signal_tmp    = tempdir(CLEANUP => 1);
  my $signal_ledger = _scripted_ledger($signal_tmp, 'signal-run');
  my $signal_runner = Overnet::Burner::Runner::Scripted->new(
    name    => 'noop',
    ledger  => $signal_ledger,
    plan    => $plan,
    run_dir => $signal_ledger->{run_dir},
  );

  my @teardowns;
  $signal_runner->{on_prepare} = sub {
    $SIG{INT}->('INT');
    return 1;
  };
  $signal_runner->{on_teardown} = sub { push @teardowns, $_[1]; 1 };

  my $summary = _with_blocked_signal(INT => sub { $signal_runner->run_lifecycle });
  is \@teardowns, ['INT'], 'an INT during a phase tears down constructed guests';
  is $summary->{phases}{collect}, 'completed', 'the interrupted lifecycle still finished its phases';

  my $noisy_tmp    = tempdir(CLEANUP => 1);
  my $noisy_ledger = _scripted_ledger($noisy_tmp, 'noisy-signal-run');
  my $noisy_runner = Overnet::Burner::Runner::Scripted->new(
    name    => 'noop',
    ledger  => $noisy_ledger,
    plan    => $plan,
    run_dir => $noisy_ledger->{run_dir},
  );
  $noisy_runner->{on_prepare} = sub {
    $SIG{TERM}->('TERM');
    return 1;
  };
  $noisy_runner->{on_teardown} = sub { die "teardown jammed\n" };

  my $teardown_warning = warning {
    _with_blocked_signal(TERM => sub { $noisy_runner->run_lifecycle });
  };
  like $teardown_warning, qr/guest\ teardown\ on\ SIGTERM\ did\ not\ complete\ cleanly/mx,
    'a failed teardown on a signal is reported as a warning';

  my $bare_tmp    = tempdir(CLEANUP => 1);
  my $bare_ledger = _scripted_ledger($bare_tmp, 'bare-signal-run');
  my $bare_runner = Overnet::Burner::Runner::Scripted->new(
    name    => 'noop',
    ledger  => $bare_ledger,
    plan    => $plan,
    run_dir => $bare_ledger->{run_dir},
  );
  $bare_runner->{on_prepare} = sub {
    $SIG{INT}->('INT');
    return 1;
  };

  my $bare_summary = _with_blocked_signal(INT => sub { $bare_runner->run_lifecycle });
  is $bare_summary->{phases}{collect}, 'completed',
    'a runner without constructed guests has nothing to tear down on a signal';
};

sub _scripted_ledger {
  my ($dir, $run_id) = @_;

  return Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => "$dir/runs",
    run_id        => $run_id,
    now           => sub {'2026-06-27T15:00:00Z'},
    host_facts    => {hostname => 'builder-host', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
}

sub _runner_events {
  my ($run_ledger) = @_;

  my $path = File::Spec->catfile($run_ledger->{run_dir}, 'logs', 'runner.jsonl');
  open my $fh, '<', $path or die "open $path: $!";
  my @events = map { JSON::decode_json($_) } <$fh>;
  close $fh or die "close $path: $!";
  return @events;
}

# Run code with a signal blocked at the OS level, so a handler that re-raises
# the signal on its way out does not terminate the test process; the pending
# signal is discarded before it is unblocked.
sub _with_blocked_signal {
  my ($signal, $code) = @_;

  my $signo  = $signal eq 'INT' ? POSIX::SIGINT() : POSIX::SIGTERM();
  my $sigset = POSIX::SigSet->new($signo);
  POSIX::sigprocmask(POSIX::SIG_BLOCK(), $sigset, POSIX::SigSet->new())
    or die "sigprocmask block: $!";
  my $result = $code->();
  $SIG{$signal} = 'IGNORE';
  POSIX::sigprocmask(POSIX::SIG_UNBLOCK(), $sigset, POSIX::SigSet->new())
    or die "sigprocmask unblock: $!";
  $SIG{$signal} = 'DEFAULT';
  return $result;
}

done_testing;
