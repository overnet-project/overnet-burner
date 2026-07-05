use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use JSON ();
use JSON::Schema::Modern;
use Test2::V0;
use YAML::PP;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::Generator;
use Overnet::Burner::ProfileGenerator;

my $repo          = "$FindBin::Bin/..";
my $template_path = File::Spec->catfile($repo, 'profile-templates', 'local-containers.yml');
my $schema_path   = File::Spec->catfile($repo, 'schemas', 'profile-template-v1.schema.json');
my $docs_path     = File::Spec->catfile($repo, 'docs', 'profile-generation.md');

subtest 'profile template contract artifacts exist and validate' => sub {
  ok -f $template_path, 'local-containers profile template exists';
  ok -f $schema_path,   'profile-template-v1 schema exists';
  ok -f $docs_path,     'profile generation docs exist';

  my $schema   = _read_json($schema_path);
  my $template = _read_yaml($template_path);
  my $docs     = _read_file($docs_path);

  is $schema->{'$schema'}, 'https://json-schema.org/draft/2020-12/schema', 'schema declares draft 2020-12';
  is $schema->{'$id'}, 'https://overnet-project.org/schemas/overnet-burner/profile-template-v1.schema.json',
    'schema has stable id';
  is $schema->{properties}{template_version}{const}, 1, 'schema locks template_version to v1';

  my $result = JSON::Schema::Modern->new->evaluate($template, $schema);
  ok $result->valid, 'shipped local-containers template validates against profile-template-v1'
    or diag(JSON->new->canonical(1)->pretty(1)->encode($result->TO_JSON));
  my $mixed_operator_result = JSON::Schema::Modern->new->evaluate(
    {
      template_version => 1,
      profile          => {
        duration => {
          random_range => {min => 1, max => 3},
          min          => 1,
        },
      },
    },
    $schema,
  );
  ok !$mixed_operator_result->valid, 'profile-template-v1 schema rejects mixed operator mappings';
  my $scalar_profile_result = JSON::Schema::Modern->new->evaluate({template_version => 1, profile => 'not a mapping'}, $schema,);
  ok !$scalar_profile_result->valid, 'profile-template-v1 schema rejects scalar top-level profiles';

  like $docs, qr/template_version:\s+1/mx, 'docs show the versioned template wrapper';
  like $docs, qr/profile-seed/mx,          'docs distinguish profile seed from scenario seed';
  like $docs, qr/profile\.generated\.yml/mx, 'docs describe generated profile ledger artifact';
};

subtest 'profile generation is deterministic and produces ordinary profiles' => sub {
  my $template = Overnet::Burner::ProfileGenerator->load_template($template_path);
  my $first    = Overnet::Burner::ProfileGenerator->generate(seed => 1001, template => $template);
  my $second   = Overnet::Burner::ProfileGenerator->generate(seed => 1001, template => $template);

  is $first, $second, 'same profile seed and template yield identical profile data';
  ok(Overnet::Burner::Generator->validate_profile($first), 'generated profile validates as an ordinary profile');
  is $first->{environment}{kind}, 'local-containers', 'generated profile uses the managed local-container environment';
  is $first->{relays}{min}, 1, 'generated profile keeps at least one relay';
  is $first->{relays}{max}, 1, 'generated profile keeps at most one relay for the smoke template';

  my %seen;
  for my $seed (1 .. 20) {
    my $profile = Overnet::Burner::ProfileGenerator->generate(seed => $seed, template => $template);
    $seen{Overnet::Burner::ProfileGenerator->profile_yaml($profile)}++;
  }
  ok keys(%seen) > 1, 'different profile seeds explore different profiles';
};

subtest 'generated profiles generate valid scenarios' => sub {
  my $template = Overnet::Burner::ProfileGenerator->load_template($template_path);

  for my $profile_seed (1 .. 20) {
    my $profile = Overnet::Burner::ProfileGenerator->generate(seed => $profile_seed, template => $template);
    for my $scenario_seed (1 .. 10) {
      my $scenario = Overnet::Burner::Generator->generate(seed => $scenario_seed, profile => $profile);
      my $ok = eval { Overnet::Burner::Config->validate(Overnet::Burner::Config->normalize($scenario)); 1 };
      ok $ok, "profile seed $profile_seed scenario seed $scenario_seed validates" or diag($@);
    }
  }
};

subtest 'profile YAML round-trips through the existing profile loader' => sub {
  my $tmp      = tempdir(CLEANUP => 1);
  my $template = Overnet::Burner::ProfileGenerator->load_template($template_path);
  my $profile  = Overnet::Burner::ProfileGenerator->generate(seed => 1001, template => $template);
  my $path     = File::Spec->catfile($tmp, 'profile.yml');

  _write_file($path, Overnet::Burner::ProfileGenerator->profile_yaml($profile));

  my $loaded = Overnet::Burner::Generator->load_profile($path);
  is $loaded, $profile, 'serialized generated profile loads as the same normalized profile';
};

subtest 'malformed templates are rejected' => sub {
  my @cases = (
    ['missing version', {profile => {}}, qr/template_version\ must\ be\ 1/mx],
    ['unknown version', {template_version => 2, profile => {}}, qr/template_version\ must\ be\ 1/mx],
    ['missing profile', {template_version => 1}, qr/profile\ must\ be\ a\ mapping/mx],
    [
      'mixed operator',
      {template_version => 1, profile => {duration => {random_range => {min => 1, max => 3}, min => 1}}},
      qr/template\ operator\ at\ profile\.duration\ must\ not\ be\ mixed/mx,
    ],
    [
      'empty one_of',
      {template_version => 1, profile => {environment => {kind => {one_of => []}}}},
      qr/one_of\ at\ profile\.environment\.kind\ must\ not\ be\ empty/mx,
    ],
    [
      'bad random range',
      {template_version => 1, profile => {duration => {random_range => {min => 30, max => 5}}}},
      qr/random_range\ at\ profile\.duration.*min.*must\ not\ exceed.*max/mx,
    ],
    [
      'generated profile fails ordinary profile validation',
      {
        template_version => 1,
        profile          => {
          relays => {random_range => {min => 1, max => 2}},
          roles  => {publishers  => {random_range => {min => 1, max => 1}}},
        },
      },
      qr/relays\.endpoints\ is\ required/mx,
    ],
  );

  for my $case (@cases) {
    my ($name, $template, $pattern) = @{$case};
    my $ok = eval {
      Overnet::Burner::ProfileGenerator->generate(seed => 1, template => $template);
      1;
    };
    ok !$ok, "$name is rejected";
    like $@, $pattern, "$name reports the expected error";
  }
};

done_testing;

sub _read_json {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  return JSON::decode_json(<$fh>);
}

sub _read_yaml {
  my ($path) = @_;

  return YAML::PP->new(schema => ['Core'])->load_string(_read_file($path));
}

sub _read_file {
  my ($path) = @_;

  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  return <$fh>;
}

sub _write_file {
  my ($path, $content) = @_;

  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print $path: $!";
  close $fh or die "close $path: $!";
  return 1;
}
