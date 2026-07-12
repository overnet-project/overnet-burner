use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Guest;

my $guest = Overnet::Burner::Guest->new(name => 'base', role => 'workers');

subtest 'the base guest records its identity' => sub {
  is $guest->name, 'base',    'the base guest records its name';
  is $guest->role, 'workers', 'the base guest records its role';
};

subtest 'every interface method croaks on the base class' => sub {
  my %expected = (
    transport    => qr/must\ define\ transport/mx,
    make_path    => qr/must\ define\ make_path/mx,
    write_file   => qr/must\ define\ write_file/mx,
    read_file    => qr/must\ define\ read_file/mx,
    run_command  => qr/must\ define\ run_command/mx,
    launch       => qr/must\ define\ launch/mx,
    try_reap     => qr/must\ define\ try_reap/mx,
    signal       => qr/must\ define\ signal/mx,
    ready_actors => qr/must\ define\ ready_actors/mx,
  );

  for my $method (sort keys %expected) {
    like dies { $guest->$method }, $expected{$method}, "$method croaks on the abstract base";
  }
};

subtest 'destroy is a no-op that succeeds' => sub {
  is $guest->destroy, 1, 'the default destroy releases nothing and returns true';
};

done_testing;
