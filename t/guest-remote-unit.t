use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Guest::Remote;

# A concrete remote guest whose transport is a controllable closure, so every
# branch of the shared remote plumbing can be driven in-process.
BEGIN {
  package _FakeRemote;
  use Moo;
  extends 'Overnet::Burner::Guest::Remote';
  has capture => (is => 'rw');
  has pushes  => (is => 'rw', default => sub { [] });
  sub _capture   { my ($self, $cmd) = @_; return $self->{capture}->($cmd) }
  sub _push_file { my ($self, $local, $remote) = @_; push @{$self->{pushes}}, [$local, $remote]; return 1 }
}

sub _guest {
  my ($capture) = @_;
  return _FakeRemote->new(name => 'remote-001', role => 'workers', capture => $capture);
}

subtest 'the base transport primitives are abstract' => sub {
  my $base = Overnet::Burner::Guest::Remote->new(name => 'r', role => 'w');
  like dies { $base->_capture('x') },       qr/must\ define\ _capture/mx,   '_capture is abstract';
  like dies { $base->_push_file('a', 'b') }, qr/must\ define\ _push_file/mx, '_push_file is abstract';
};

subtest 'shell_quote escapes and tolerates undef' => sub {
  is(_FakeRemote->shell_quote(q{a'b}), q{'a'\''b'}, 'single quotes are escaped');
  is(_FakeRemote->shell_quote(undef),  q{''},       'an undefined value becomes an empty quoted string');
};

subtest 'make_path succeeds and reports failure' => sub {
  is _guest(sub { return (q{}, 0) })->make_path('/srv/run'), 1, 'a successful mkdir returns true';
  like dies { _guest(sub { return (q{}, 1) })->make_path('/srv/run') }, qr/could\ not\ create/mx,
    'a failed mkdir croaks';
};

subtest 'write_file stages then pushes the content' => sub {
  my $guest = _guest(sub { return (q{}, 0) });
  is $guest->write_file('/srv/note', "data\n"), 1, 'write_file succeeds';
  is scalar @{$guest->pushes}, 1, 'the staged file was pushed to the transport';
  is $guest->pushes->[0][1], '/srv/note', 'the push targets the requested remote path';
};

subtest 'read_file returns content or undef on a transport failure' => sub {
  is _guest(sub { return ("hello\n", 0) })->read_file('/srv/note'), "hello\n", 'a present file is read';
  is _guest(sub { return (undef, 1) })->read_file('/srv/note'), undef, 'a transport failure reads as undef';
};

subtest 'run_command captures the inline exit code' => sub {
  my $guest = _guest(
    sub {
      my ($cmd) = @_;
      return ("/tmp/work\n", 0) if $cmd =~ /mktemp/mx;
      return ("OVERNET_EXIT:5\n", 0) if $cmd =~ /OVERNET_EXIT/mx;
      return ("captured\n", 0) if $cmd =~ /test\ -e/mx;
      return (q{}, 0);
    }
  );
  my $result = $guest->run_command(command => 'do-thing', env => {A => 'b'});
  is $result->{exit_code}, 5,          'the inline exit marker is parsed back out';
  is $result->{stdout},    "captured\n", 'stdout crosses the transport';

  like dies { _guest(sub { return (undef, 1) })->run_command(command => 'x') }, qr/could\ not\ allocate/mx,
    'a failed work-dir allocation croaks';

  # A transport failure on the command line leaves the exit code undefined.
  my $unknown = _guest(
    sub {
      my ($cmd) = @_;
      return ("/tmp/work\n", 0) if $cmd =~ /mktemp/mx;
      return (undef, 1) if $cmd =~ /OVERNET_EXIT/mx;
      return (q{}, 0);
    }
  );
  is $unknown->run_command(command => 'x')->{exit_code}, undef, 'an unparseable result yields no exit code';
};

subtest 'launch stages a supervisor and validates the pid' => sub {
  my $guest = _guest(
    sub {
      my ($cmd) = @_;
      return ("4242\n", 0) if $cmd =~ /nohup/mx;
      return (q{}, 0);
    }
  );
  my $handle = $guest->launch(command => 'run-worker', stdout => '/srv/out', stderr => '/srv/err', env => {K => 'v'});
  is $handle->{supervisor_pid}, '4242',            'launch returns the supervisor pid';
  is $handle->{pid_file},       '/srv/out.pid',    'launch records the pid file';

  like dies {
    _guest(sub { return ('not-a-pid', 0) })->launch(command => 'x', stdout => '/o', stderr => '/e')
  }, qr/could\ not\ launch/mx, 'a non-numeric pid is a launch failure';
};

subtest 'try_reap reads status, probes liveness, and infers a kill' => sub {
  my $handle = {supervisor_pid => 7, pid_file => '/o.pid', status_file => '/o.status'};

  # Status file already written: reap it.
  is _guest(sub { return ("3\n", 0) })->try_reap($handle), (3 << 8), 'a written status is reaped';

  # No status, supervisor alive: nothing to reap.
  is _guest(
    sub {
      my ($cmd) = @_;
      return (undef, 1) if $cmd =~ /status/mx;    # cat status fails
      return ("alive\n", 0);
    }
  )->try_reap($handle), undef, 'a live supervisor is not reaped';

  # No status, probe fails at the transport: report nothing.
  is _guest(
    sub {
      my ($cmd) = @_;
      return (undef, 1) if $cmd =~ /status/mx;
      return (undef, 1);
    }
  )->try_reap($handle), undef, 'a failed probe reports nothing';

  # No status, supervisor dead, still no status: inferred kill.
  is _guest(
    sub {
      my ($cmd) = @_;
      return (undef, 1) if $cmd =~ /status/mx;
      return ("dead\n", 0);
    }
  )->try_reap($handle), 9, 'a dead supervisor with no status is an inferred kill';
};

subtest 'signal and reachable use the transport' => sub {
  my @seen;
  my $guest = _guest(sub { push @seen, shift; return (q{}, 0) });
  is $guest->signal({pid_file => '/o.pid'}, 'TERM'), 1, 'signal returns true';
  ok((grep { /kill\ -TERM/mx } @seen), 'signal sends a kill over the transport');

  is _guest(sub { return (q{}, 0) })->reachable, 1, 'a responsive guest is reachable';
  is _guest(sub { return (q{}, 1) })->reachable, 0, 'an unresponsive guest is not reachable';
};

subtest 'unsafe environment names and signals are rejected before reaching the shell' => sub {
  # Values are shell-quoted, but variable names are interpolated into export
  # statements unquoted and the signal into a kill command, so both must be
  # constrained. The transport closure dies if reached, proving the guards
  # short-circuit before any command is issued.
  my $tripwire = _guest(sub { die "transport must not be reached\n" });

  like dies { $tripwire->run_command(command => 'x', env => {'BAD; rm -rf /' => 'v'}) },
    qr/unsafe\ environment\ variable\ name/mx, 'run_command rejects an unsafe env name';
  like dies { $tripwire->launch(command => 'x', stdout => '/o', stderr => '/e', env => {'A B' => 'v'}) },
    qr/unsafe\ environment\ variable\ name/mx, 'launch rejects an unsafe env name';
  like dies { $tripwire->signal({pid_file => '/o.pid'}, 'TERM; reboot') },
    qr/unsafe\ signal/mx, 'signal rejects a signal carrying shell metacharacters';

  my $legit = _guest(sub { return (q{}, 0) });
  is $legit->signal({pid_file => '/o.pid'}, '9'), 1, 'a numeric signal is still accepted';
};

subtest 'ready_actors parses the probe or reports nothing on failure' => sub {
  is _guest(sub { return ("publisher-001\nsubscriber-001\n*\n", 0) })->ready_actors('/workers'),
    ['publisher-001', 'subscriber-001'], 'ready actors are parsed and the glob sentinel dropped';
  is _guest(sub { return (undef, 1) })->ready_actors('/workers'), [], 'a failed probe reports nothing ready';
};

done_testing;
