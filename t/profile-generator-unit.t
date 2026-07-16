use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::ProfileGenerator;

my $PG = 'Overnet::Burner::ProfileGenerator';

sub _template { return {template_version => '1', profile => $_[0]} }
sub _expand   { return Overnet::Burner::ProfileGenerator::_expand_value('42', 'profile', $_[0]) }

subtest 'template validation rejects malformed templates' => sub {
  like dies { $PG->load_template_data('nope') }, qr/template\ must\ be\ a\ mapping/mx, 'a non-mapping template';
  like dies { $PG->load_template_data({profile => {}}) }, qr/template_version\ must\ be\ 1/mx,
    'the version must be 1';
  like dies { $PG->load_template_data({template_version => '1', profile => 'x'}) }, qr/profile\ must\ be\ a\ mapping/mx,
    'the profile must be a mapping';
  like dies { $PG->load_template_data({template_version => '1', profile => {}, extra => 1}) },
    qr/unknown\ profile\ template\ field/mx, 'unknown template fields are rejected';
  like dies { $PG->load_template_data(_template({x => {random_int => {min => 1, max => 2}, y => 3}})) },
    qr/must\ not\ be\ mixed/mx, 'an operator mixed with ordinary fields is rejected';
};

subtest 'operator validation rejects malformed operator specs' => sub {
  like dies { $PG->load_template_data(_template({x => {one_of => 'nope'}})) }, qr/one_of.*must\ be\ a\ list/mx,
    'one_of must be a list';
  like dies { $PG->load_template_data(_template({x => {one_of => []}})) }, qr/one_of.*must\ not\ be\ empty/mx,
    'one_of must not be empty';
  like dies { $PG->load_template_data(_template({x => {random_int => 'nope'}})) }, qr/random_int.*must\ be\ a\ mapping/mx,
    'an operator spec must be a mapping';
  like dies { $PG->load_template_data(_template({x => {random_int => {min => 1, max => 2, precision => 1}}})) },
    qr/unknown\ random_int\ field.*precision/mx, 'unknown operator fields are rejected';
  like dies { $PG->load_template_data(_template({x => {random_number => {min => 5, max => 1}}})) },
    qr/random_number.*must\ not\ exceed\ max/mx, 'random_number min must not exceed max';
  like dies { $PG->load_template_data(_template({x => {random_int => {min => 5, max => 1}}})) },
    qr/random_int.*must\ not\ exceed\ max/mx, 'random_int min must not exceed max';
  like dies { $PG->load_template_data(_template({x => {random_range => {min => 1, max => 5, min_width => -1}}})) },
    qr/min_width\ must\ be\ non-negative/mx, 'a negative min_width is rejected';
  like dies { $PG->load_template_data(_template({x => {random_range => {min => 1, max => 5, min_width => 9}}})) },
    qr/min_width.*must\ not\ exceed\ range/mx, 'a min_width wider than the range is rejected';
  like dies { $PG->load_template_data(_template({x => {random_int => {min => 'soon', max => 5}}})) },
    qr/min\ must\ be\ an\ integer/mx, 'a non-integer bound is rejected';
  like dies { $PG->load_template_data(_template({x => {random_number => {min => 'x', max => 5}}})) },
    qr/min\ must\ be\ an\ number/mx, 'a non-numeric random_number bound is rejected';
};

subtest 'a valid template validates and preserves nested structure' => sub {
  my $template = $PG->load_template_data(
    _template({list => [1, {random_int => {min => 1, max => 2}}], nested => {deep => 'value'}}));
  is $template->{profile}{nested}{deep}, 'value', 'nested ordinary values survive validation';
};

subtest 'expansion draws each operator deterministically' => sub {
  my $int = _expand({random_int => {min => 3, max => 3}});
  is $int, 3, 'a degenerate integer range returns its endpoint';

  my $ranged = _expand({random_int => {min => 1, max => 100}});
  ok $ranged >= 1 && $ranged <= 100, 'an integer is drawn within range';

  my $num = _expand({random_number => {min => 0, max => 1}});
  ok $num >= 0 && $num <= 1, 'a number is drawn within range with the default precision';
  my $precise = _expand({random_number => {min => 0, max => 1, precision => 1}});
  like "$precise", qr/\A\d(?:[.]\d)?\z/mx, 'an explicit precision bounds the fraction digits';

  my $range = _expand({random_range => {min => 1, max => 20, min_width => 5}});
  ok $range->{max} - $range->{min} >= 5, 'a drawn range respects its minimum width';

  my $picked = _expand({one_of => ['alpha', 'beta', 'gamma']});
  ok((grep { $_ eq $picked } qw(alpha beta gamma)), 'one_of picks a listed value');

  my $mapping = _expand({fixed => 7, drawn => {random_int => {min => 2, max => 2}}});
  is $mapping, {fixed => 7, drawn => 2}, 'ordinary mappings pass through while operators expand';
};

subtest 'the minimum-width widening handles both boundary directions' => sub {
  # Sweep seeds so both the widen-up and widen-down adjustments are exercised.
  my %seen_max;
  for my $seed (1 .. 40) {
    my $range = Overnet::Burner::ProfileGenerator::_expand_value(
      "$seed", 'profile', {random_range => {min => 1, max => 3, min_width => 2}});
    ok $range->{max} - $range->{min} >= 2, "seed $seed keeps the minimum width" if $seed <= 3;
    $seen_max{$range->{max}}++;
  }
  ok keys %seen_max, 'the widening produced ranges';
};

subtest 'a widened range never escapes its spec bounds' => sub {
  # A min_width near the full span forces widening; when neither endpoint can be
  # extended to reach the width without crossing a bound, the range must fall
  # back to the whole span, never below spec.min or above spec.max. Sweep seeds
  # so the widen-up, widen-down, and full-span adjustments are all exercised.
  my $spec = {min => 5, max => 30, min_width => 20};
  my @violations;
  for my $seed (0 .. 60) {
    my $range = Overnet::Burner::ProfileGenerator::_expand_value("$seed", 'profile', {random_range => $spec});
    push @violations, "seed $seed => [$range->{min}, $range->{max}]"
      if $range->{min} < $spec->{min}
      || $range->{max} > $spec->{max}
      || $range->{max} - $range->{min} < $spec->{min_width};
  }
  is \@violations, [],
    'every seed stays within [min, max] and keeps the minimum width';
};

subtest 'generate requires an integer seed and produces a valid profile' => sub {
  like dies { $PG->generate(seed => 'later', template => _template({})) }, qr/seed\ must\ be\ an\ integer/mx,
    'a non-integer seed is rejected';

  my $profile = $PG->generate(
    seed     => 7,
    template => _template({roles => {}, relays => {provider => 'generic-relay', min => 1, max => 1}}),
  );
  ok $profile, 'a valid template generates a valid profile';

  my $yaml = $PG->profile_yaml($profile);
  like $yaml, qr/relays/mx, 'the generated profile renders to YAML';
};

done_testing;
