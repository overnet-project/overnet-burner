use strictures 2;

use Test2::V0;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../relay-perl/lib", "$FindBin::Bin/../../core-perl/lib";

use Overnet::Burner::Adversary::Fuzzer;
use Overnet::Burner::Adversary::Oracle;

my $SCOPE       = 'channel:#ops';
my $ATTACKER_GT = {authorized_capabilities => []};

# A stand-in system under test that is defended in the common case but has one
# latent flaw: it only leaks operator to the attacker once it has processed two
# control events that share a created_at. The base scenario never collides, so
# the flaw is invisible until a mutation forces the collision - exactly the kind
# of neighbour the fuzzer is meant to reach.
{

  package CollisionArena;
  sub new { my ($class) = @_; return bless {seen => [], collided => 0}, $class; }
  sub baseline_ref { return 'stub:collision-arena'; }

  sub reset {    ## no critic (ProhibitBuiltinHomonyms)
    my ($self) = @_;
    $self->{seen}     = [];
    $self->{collided} = 0;
    return;
  }

  sub apply {
    my ($self, $action) = @_;
    my $type    = $action->{type};
    my $payload = $action->{payload} || {};

    if ($type eq 'publish_control') {
      my $created_at = $payload->{created_at};
      if (defined $created_at) {
        if (grep { $_ == $created_at } @{$self->{seen}}) {
          $self->{collided} = 1;
        }
        push @{$self->{seen}}, $created_at;
      }
      return [{type => 'relay_outcome', payload => {accepted => 1}}];
    }
    if ($type eq 'observe_capability') {
      if ($self->{collided}) {
        return [
          {
            type    => 'observed_capability',
            payload => {subject => 'attacker', capability => 'irc.operator', scope => $SCOPE},
          },
        ];
      }
      return [];
    }
    return [];
  }
}

my @COLLISION_BASE = (
  {type => 'publish_control',    payload => {signer => 'op', kind => 9_000, created_at => 1_000}},
  {type => 'publish_control',    payload => {signer => 'op', kind => 9_000, created_at => 2_000}},
  {type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE}},
);

sub _fuzzer {
  my (%args) = @_;
  return Overnet::Burner::Adversary::Fuzzer->new(
    arena_factory => sub { return CollisionArena->new },
    oracle        => Overnet::Burner::Adversary::Oracle->new,
    %args,
  );
}

subtest 'the constructor validates its collaborators' => sub {
  like dies { Overnet::Burner::Adversary::Fuzzer->new }, qr/arena_factory\ must\ be\ a\ code\ reference/mx,
    'arena_factory is required';
  like dies { Overnet::Burner::Adversary::Fuzzer->new(arena_factory => 'x') },
    qr/arena_factory\ must\ be\ a\ code\ reference/mx, 'arena_factory must be a code reference';
  like dies { Overnet::Burner::Adversary::Fuzzer->new(arena_factory => sub { }, operators => 'x') },
    qr/operators\ must\ be\ an\ array\ reference/mx, 'operators must be an array reference';
  like dies { Overnet::Burner::Adversary::Fuzzer->new(arena_factory => sub { }, operators => ['x']) },
    qr/each\ operator\ must\ be\ a\ code\ reference/mx, 'each operator must be a code reference';
  like dies { Overnet::Burner::Adversary::Fuzzer->new(arena_factory => sub { }, max_variants => 0) },
    qr/max_variants\ must\ be\ a\ positive\ integer/mx, 'max_variants must be a positive integer';
};

subtest 'explore validates its inputs' => sub {
  my $fuzzer = _fuzzer();
  like dies { $fuzzer->explore(ground_truth => {}, seed => '1') }, qr/base\ must\ be\ an\ array\ reference/mx,
    'base is required';
  like dies { $fuzzer->explore(base => [{payload => {}}], ground_truth => {}, seed => '1') },
    qr/each\ base\ action\ must\ be\ an\ object\ with\ a\ type/mx, 'base actions need a type';
  like dies { $fuzzer->explore(base => \@COLLISION_BASE, ground_truth => 'x', seed => '1') },
    qr/ground_truth\ must\ be\ an\ object/mx, 'ground_truth must be an object';
};

subtest 'a mutation reaches a violation the base scenario hides' => sub {
  my $fuzzer = _fuzzer();
  my $result = $fuzzer->explore(base => \@COLLISION_BASE, ground_truth => $ATTACKER_GT, seed => '1');

  ok $result->{explored} > 1, 'the fuzzer explored the mutation neighbourhood';
  ok scalar(@{$result->{findings}}), 'the fuzzer surfaced at least one violation';

  my %labels = map { $_->{label} => 1 } @{$result->{findings}};
  ok !$labels{identity}, 'the base scenario itself is defended (no identity finding)';
  ok $labels{'collide@0:1'}, 'colliding the two control timestamps is reported as a finding';

  my ($finding) = grep { $_->{label} eq 'collide@0:1' } @{$result->{findings}};
  ok $finding->{verdict}{violated}, 'the finding carries the violated verdict';
  is $finding->{verdict}{invariants}{authorization}{status}, 'violated', 'the authorization invariant fired';
};

subtest 'exploration is deterministic for a fixed seed and base' => sub {
  my $first  = _fuzzer()->explore(base => \@COLLISION_BASE, ground_truth => $ATTACKER_GT, seed => '1');
  my $second = _fuzzer()->explore(base => \@COLLISION_BASE, ground_truth => $ATTACKER_GT, seed => '1');

  my @first_labels  = sort map { $_->{label} } @{$first->{findings}};
  my @second_labels = sort map { $_->{label} } @{$second->{findings}};
  is \@second_labels, \@first_labels, 'the same run yields the same findings';
  is $second->{explored}, $first->{explored}, 'the same run explores the same number of variants';
};

subtest 'the operator set is pluggable' => sub {
  my $fuzzer = _fuzzer(operators => [sub { return [] }]);
  my $result = $fuzzer->explore(base => \@COLLISION_BASE, ground_truth => $ATTACKER_GT, seed => '1');

  is $result->{explored},          1, 'with no operators only the base scenario runs';
  is scalar(@{$result->{findings}}), 0, 'the defended base produces no finding';
};

subtest 'a variant budget caps and reports truncation' => sub {
  my $fuzzer = _fuzzer(max_variants => 2);
  my $result = $fuzzer->explore(base => \@COLLISION_BASE, ground_truth => $ATTACKER_GT, seed => '1');

  is $result->{explored}, 2, 'exploration stops at the budget';
  ok $result->{total_variants} > 2, 'more variants were generated than the budget allows';
  ok $result->{truncated} > 0,      'the shortfall is reported, not silently dropped';
};

subtest 'the hardened live relay withstands the whole mutation neighbourhood' => sub {
  my $relay_available = eval {
    require Overnet::Authority::HostedChannel::Relay;
    1;
  };
  if (!$relay_available) {
    plan skip_all => 'relay-perl not available (Overnet::Authority::HostedChannel::Relay)';
  }

  require Overnet::Burner::Adversary::Arena::Live;

  my @live_base = (
    {type => 'new_identity',  payload => {name  => 'operator'}},
    {type => 'publish_grant', payload => {actor => 'operator', delegate => 'operator-session', id => 'operator-grant'}},
    {
      type    => 'publish_control',
      payload => {
        signer    => 'operator-session',
        actor     => 'operator',
        authority => 'operator-grant',
        kind      => 9_000,
        roles     => [{subject => 'operator', role => 'irc.operator'}],
      },
    },
    {type => 'new_identity',  payload => {name  => 'attacker'}},
    {type => 'publish_grant', payload => {actor => 'attacker', delegate => 'attacker-session', id => 'forged-grant'}},
    {
      type    => 'publish_control',
      payload => {
        signer    => 'attacker-session',
        actor     => 'operator',
        authority => 'forged-grant',
        kind      => 9_001,
        roles     => [{subject => 'attacker', role => 'irc.operator'}],
      },
    },
    {type => 'observe_capability', payload => {subject => 'attacker', scope => $SCOPE}},
    {type => 'observe_capability', payload => {subject => 'operator', scope => $SCOPE}},
  );

  my $fuzzer = Overnet::Burner::Adversary::Fuzzer->new(
    arena_factory => sub {
      return Overnet::Burner::Adversary::Arena::Live->new(snapshot_signers => ['snapshot-authority'], seed => '1');
    },
  );
  my $result = $fuzzer->explore(
    base         => \@live_base,
    ground_truth => {authorized_capabilities => [{subject => 'operator', capability => 'irc.operator', scope => $SCOPE}]},
    seed         => '1',
  );

  ok $result->{explored} > 1, 'the fuzzer drove many mutations against the live relay';
  is scalar(@{$result->{findings}}), 0,
    'no mutation of the forged-grant attack escalates against the hardened relay';
};

done_testing;
