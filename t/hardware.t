use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Hardware qw(host_architecture requirement_minimums validate_requirements);

subtest 'minimums are computed from validated requirements' => sub {
  is { requirement_minimums({}) }, {}, 'no requirements means no minimums';

  is { requirement_minimums({memory => '>= 2 GiB'}) }, {memory_mb => 2048}, 'binary units convert exactly';
  is { requirement_minimums({memory => '>= 1 GB'}) }, {memory_mb => 954},
    'decimal units round up so the guest never has less than asked';
  is { requirement_minimums({memory => '512 MiB'}) }, {memory_mb => 512},  'a plain value is an exact minimum';
  is { requirement_minimums({memory => '1.5 GiB'}) }, {memory_mb => 1536}, 'fractional values are supported';

  is { requirement_minimums({cpu => {cores => 2}}) },      {cpus => 2}, 'plain core counts pass through';
  is { requirement_minimums({cpu => {cores => '>= 4'}}) }, {cpus => 4}, 'core comparisons yield the minimum';

  is { requirement_minimums({memory => '>= 2 GiB', cpu => {cores => '>= 2'}}) },
    {memory_mb => 2048, cpus => 2}, 'memory and cores combine';
};

subtest 'validation accepts the implemented grammar' => sub {
  ok validate_requirements({arch => host_architecture(), memory => '>= 8 GB', cpu => {cores => '>= 4'}}, 'hardware'),
    'the decided v1 keys validate';
  ok validate_requirements({}, 'hardware'), 'an empty requirement validates';
};

subtest 'validation rejects what is reserved or wrong' => sub {
  my @rejections = (
    [{gpu => 1}, qr/hardware\.gpu\ is\ not\ an\ implemented\ hardware\ requirement/mx, 'unknown key'],
    [
      {and => [{memory => '>= 1 GB'}]},
      qr/hardware\ and\/or\ groups\ are\ not\ implemented\ yet/mx,
      'and group is reserved'
    ],
    [{or     => []},        qr/hardware\ and\/or\ groups\ are\ not\ implemented\ yet/mx,    'or group is reserved'],
    [{memory => '> 1 GB'},  qr/hardware\.memory\ operator\ >\ is\ not\ implemented\ yet/mx, 'reserved operator'],
    [{memory => '>= 1'},    qr/hardware\.memory\ must\ include\ a\ unit/mx,                 'memory needs a unit'],
    [{memory => '>= 1 TB'}, qr/hardware\.memory\ must\ include\ a\ unit\ \(MB,\ MiB,\ GB,\ GiB\)/mx, 'unknown unit'],
    [{cpu    => {cores => '>= 2.5'}}, qr/hardware\.cpu\.cores\ must\ be\ a\ positive\ integer/mx, 'fractional cores'],
    [{cpu    => {cores => 0}},        qr/hardware\.cpu\.cores\ must\ be\ a\ positive\ integer/mx, 'zero cores'],
    [{memory => '0 GiB'},             qr/hardware\.memory\ must\ be\ positive/mx,                 'zero memory'],
    [
      {cpu => {threads => 4}},
      qr/hardware\.cpu\.threads\ is\ not\ an\ implemented\ hardware\ requirement/mx,
      'unknown cpu key'
    ],
    [{arch   => q{}},    qr/hardware\.arch\ must\ be\ a\ non-empty\ string/mx,           'empty arch'],
    [{memory => 'lots'}, qr/hardware\.memory\ must\ be\ a\ number\ or\ a\ comparison/mx, 'unparseable value'],
  );

  for my $case (@rejections) {
    my ($hardware, $pattern, $name) = @{$case};
    eval { validate_requirements($hardware, 'hardware') };
    like $@, $pattern, "$name is rejected";
  }
};

done_testing;
