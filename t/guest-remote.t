use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

package Overnet::Burner::Guest::Scripted {
  use Moo;

  extends 'Overnet::Burner::Guest::Remote';

  has replies => (is => 'ro', required => 1);
  has seen    => (is => 'ro', default  => sub { [] });

  no Moo;

  sub transport {'scripted'}

  sub _capture {
    my ($self, $command) = @_;

    push @{$self->seen}, $command;
    my $reply = shift @{$self->replies} or die "no scripted reply for: $command\n";

    return @{$reply};
  }
}

my %handle = (
  supervisor_pid => 4242,
  pid_file       => '/guest/logs/workers/actor.stdout.pid',
  status_file    => '/guest/logs/workers/actor.stdout.status',
);

subtest 'a written status file reaps as the worker exit status' => sub {
  my $guest = _guest([["2\n", 0]]);

  is $guest->try_reap(\%handle), 2 << 8, 'the recorded exit code becomes the wait status';
};

subtest 'a live supervisor without a status file is not reapable yet' => sub {
  my $guest = _guest([[q{}, 256], ["alive\n", 0]]);

  is $guest->try_reap(\%handle), undef, 'try_reap returns undef while the supervisor still runs';
};

subtest 'a status file written between the read and the liveness probe is a clean exit' => sub {
  my $guest = _guest(
    [
      [q{},      256],    # first status read: the supervisor has not written yet
      ["dead\n", 0],      # liveness probe: the supervisor already exited
      ["0\n",    0],      # the status file landed between the two checks
    ]
  );

  is $guest->try_reap(\%handle), 0, 'the race resolves to the real exit status, never a synthetic kill';
  like $guest->seen->[2], qr/cat/mx, 'the status file is re-read after the supervisor is seen dead';
};

subtest 'a supervisor that vanished without a status file reaps as killed' => sub {
  my $guest = _guest([[q{}, 256], ["dead\n", 0], [q{}, 256]]);

  is $guest->try_reap(\%handle), 9, 'no status file after a dead supervisor means the worker was killed';
};

subtest 'a transport failure during the liveness probe is not a kill' => sub {
  my $guest = _guest([[q{}, 256], [q{}, 255 << 8]]);

  is $guest->try_reap(\%handle), undef, 'an unreachable transport reports nothing rather than a synthetic kill';
};

subtest 'garbled probe output is treated as unknown, not dead' => sub {
  my $guest = _guest([[q{}, 256], ["connection reset\n", 0]]);

  is $guest->try_reap(\%handle), undef, 'unparseable probe output reports nothing rather than a synthetic kill';
};

done_testing;

sub _guest {
  my ($replies) = @_;

  return Overnet::Burner::Guest::Scripted->new(
    name    => 'scripted-guest',
    role    => 'workers',
    replies => $replies,
  );
}
