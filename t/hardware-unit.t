use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Hardware qw(host_architecture requirement_minimums validate_requirements);

subtest 'validate_requirements rejects malformed requirement documents' => sub {
  like dies { validate_requirements('nope', 'hw') }, qr/hw\ must\ be\ a\ mapping/mx, 'a non-mapping is rejected';
  like dies { validate_requirements({and => []}, 'hw') }, qr/and\/or\ groups\ are\ not\ implemented/mx,
    'and/or groups are rejected';
  like dies { validate_requirements({gpu => 1}, 'hw') }, qr/not\ an\ implemented\ hardware\ requirement/mx,
    'an unknown key is rejected';
  like dies { validate_requirements({cpu => 'two'}, 'hw') }, qr/cpu\ must\ be\ a\ mapping/mx,
    'a non-mapping cpu is rejected';
  like dies { validate_requirements({cpu => {threads => 2}}, 'hw') },
    qr/cpu\.threads\ is\ not\ an\ implemented/mx, 'an unknown cpu key is rejected';
  like dies { validate_requirements({memory => []}, 'hw') },
    qr/must\ be\ a\ number\ or\ a\ comparison/mx, 'a non-scalar memory value is rejected';
};

subtest 'validate_requirements accepts the implemented subset' => sub {
  is validate_requirements({memory => '512 MiB'}, 'hw'), 1, 'a memory requirement validates';
  is validate_requirements({cpu => {}}, 'hw'), 1, 'a cpu mapping without cores validates';
  is validate_requirements({cpu => {cores => 4}}, 'hw'), 1, 'a cpu cores requirement validates';
  is validate_requirements({arch => 'not-the-host'}, 'hw'), 1,
    'an attached group may declare any architecture';
  is validate_requirements({arch => host_architecture()}, 'hw', construct => 1), 1,
    'a constructed group may declare the host architecture';
  like dies { validate_requirements({arch => 'made-up-arch'}, 'hw', construct => 1) },
    qr/does\ not\ match\ the\ host\ architecture/mx, 'a constructed group must match the host architecture';
};

subtest 'requirement_minimums extracts present minimums only' => sub {
  is {requirement_minimums('nope')}, {}, 'a non-mapping has no minimums';
  is {requirement_minimums({memory => '1 GiB'})}, {memory_mb => 1024},
    'a memory-only requirement yields a memory minimum and no cpu minimum';
  is {requirement_minimums({cpu => {cores => 2}})}, {cpus => 2}, 'a cpu cores requirement yields a cpu minimum';
  is {requirement_minimums({cpu => {}})}, {}, 'a cpu mapping without cores yields nothing';
};

done_testing;
