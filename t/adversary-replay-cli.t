use strictures 2;

use Test2::V0;

use FindBin;
use IO::Socket::INET;
use Time::HiRes qw(sleep);

my $bin      = "$FindBin::Bin/../bin/overnet-burner-adversary-replay";
my $scenario = "$FindBin::Bin/../share/adversary/wire/forged-grant-escalation.yaml";

ok -f $bin,      'replay CLI exists';
ok -f $scenario, 'example wire scenario exists';

# Load the CLI's subs into this process without triggering its !caller run.
do $bin;
die "failed to load $bin: $@" if $@;

sub _capture {
  my (@args) = @_;
  my ($out, $err) = (q{}, q{});
  my $rc;
  {
    open my $o, '>', \$out or die "cannot capture stdout: $!";
    open my $e, '>', \$err or die "cannot capture stderr: $!";
    local *STDOUT = $o;
    local *STDERR = $e;
    $rc = main::run(@args);
  }
  return {rc => $rc, out => $out, err => $err};
}

subtest 'help' => sub {
  my $r = _capture('--help');
  is $r->{rc}, 0, '--help exits 0';
  like $r->{out}, qr/--relay-url/, 'help documents --relay-url';
  like $r->{out}, qr/--scenario/,  'help documents --scenario';
};

subtest 'usage errors' => sub {
  is _capture('--scenario', $scenario)->{rc}, 2, 'missing --relay-url is a usage error';
  is _capture('--relay-url', 'ws://127.0.0.1:1')->{rc}, 2, 'missing --scenario is a usage error';
};

# --- live replay against a real forked relay --------------------------------

SKIP: {
  eval { require Overnet::Authority::HostedChannel::Relay; 1 }
    or skip 'Overnet::Authority::HostedChannel::Relay not available', 3;

  my $listen = IO::Socket::INET->new(Proto => 'tcp', LocalAddr => '127.0.0.1', Listen => 1)
    or die "cannot allocate a port: $!";
  my $port = $listen->sockport;
  $listen->close;
  my $relay_url = "ws://127.0.0.1:$port";

  my $relay_pid = fork // die "fork failed: $!";
  if ($relay_pid == 0) {
    my $relay = Overnet::Authority::HostedChannel::Relay::build_authoritative_relay(
      relay_url  => $relay_url,
      grant_kind => 14142,
    );
    $relay->run('127.0.0.1', $port);
    exit 0;
  }

  my $up = 0;
  for (1 .. 100) {
    my $s = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port", Timeout => 1);
    if ($s) { $s->close; $up = 1; last; }
    sleep 0.1;
  }

  SKIP: {
    skip 'relay did not come up', 3 unless $up;

    my $r = _capture('--relay-url', $relay_url, '--scenario', $scenario, '--grant-kind', 14142);
    is $r->{rc}, 0, 'the relay defends the forged-grant escalation (exit 0)';
    like $r->{out}, qr/PASS/,     'reports PASS';
    like $r->{out}, qr/DEFENDED/, 'reports the control action as DEFENDED';
  }

  kill 'TERM', $relay_pid;
  waitpid $relay_pid, 0;
}

done_testing;
