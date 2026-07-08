use strictures 2;

use File::Spec;
use FindBin;
use JSON ();
use JSON::Schema::Modern;
use Test2::V0;

use Overnet::Burner::Adversary::Session;

my $repo        = "$FindBin::Bin/..";
my $schema_path = File::Spec->catfile($repo, 'schemas', 'adversary-session-v1.schema.json');

ok -e $schema_path, 'adversary session v1 schema exists';

my $schema = do {
  open my $fh, '<:raw', $schema_path or die "open $schema_path: $!";
  local $/ = undef;
  JSON->new->decode(<$fh>);
};

is $schema->{'$id'},
  'https://overnet-project.org/schemas/overnet-burner/adversary-session-v1.schema.json',
  'schema has a stable id';
is $schema->{additionalProperties}, JSON::false, 'session record schema is closed';

sub _session {
  return Overnet::Burner::Adversary::Session->new(
    session_id         => 'sess-1',
    seed               => '42',
    arena_baseline_ref => 'baseline-abc',
  );
}

subtest 'a new session opens with a meta record' => sub {
  my $session = _session();
  my $steps   = $session->steps;

  is scalar(@{$steps}),                        1,              'session begins with a single step';
  is $steps->[0]{kind},                        'meta',         'first step is meta';
  is $steps->[0]{type},                        'session_open', 'first step opens the session';
  is $steps->[0]{seq},                         0,              'first step is seq 0';
  is $steps->[0]{payload}{seed},               '42',           'meta carries the seed';
  is $steps->[0]{payload}{arena_baseline_ref}, 'baseline-abc', 'meta carries the arena baseline';
};

subtest 'actions and observations append in order' => sub {
  my $session = _session();
  $session->append_action(type => 'publish_control', payload => {kind => 9000});
  $session->append_observation(type => 'relay_outcome', payload => {accepted => 0, reason => q{unauthorized}});

  my $steps = $session->steps;
  is scalar(@{$steps}),             3,                 'meta plus two steps';
  is [map { $_->{seq} } @{$steps}], [0, 1, 2],         'seqs are contiguous';
  is $steps->[1]{kind},             'action',          'second step is an action';
  is $steps->[1]{type},             'publish_control', 'action type recorded';
  is $steps->[2]{kind},             'observation',     'third step is an observation';
};

subtest 'steps_of_kind filters by kind' => sub {
  my $session = _session();
  $session->append_action(type => 'a', payload => {});
  $session->append_observation(type => 'o', payload => {});
  is scalar(@{$session->steps_of_kind('action')}),      1, 'one action';
  is scalar(@{$session->steps_of_kind('observation')}), 1, 'one observation';
  is scalar(@{$session->steps_of_kind('meta')}),        1, 'one meta';
};

subtest 'append rejects malformed steps' => sub {
  my $session = _session();
  like dies { $session->append_action(payload => {}) }, qr/step\ type\ is\ required/mx, 'type required';
  like dies { $session->append_action(type => 'x', payload => []) }, qr/payload\ must\ be\ an\ object/mx,
    'payload must be an object';
};

subtest 'every emitted record validates against the contract schema' => sub {
  my $session = _session();
  $session->append_action(type => 'new_identity',    payload => {identity => 'attacker'});
  $session->append_action(type => 'publish_control', payload => {kind     => 9000, signer => 'attacker'});
  $session->append_observation(type => 'observed_capability', payload => {subject => 'attacker'});

  my $validator = JSON::Schema::Modern->new;
  for my $record (@{$session->steps}) {
    my $result = $validator->evaluate($record, $schema);
    ok $result->valid, "record seq $record->{seq} validates against adversary-session-v1"
      or diag join "\n", map { $_->{error} } $result->errors;
  }
};

subtest 'a session round-trips through JSONL' => sub {
  my $session = _session();
  $session->append_action(type => 'publish_control', payload => {kind => 9000, signer => 'attacker'});
  $session->append_observation(type => 'relay_outcome', payload => {accepted => 0, reason => q{unauthorized}});

  my $jsonl  = $session->to_jsonl;
  my $replay = Overnet::Burner::Adversary::Session->from_jsonl($jsonl);

  is $replay->session_id,         'sess-1',        'session id survives round-trip';
  is $replay->seed,               '42',            'seed survives round-trip';
  is $replay->arena_baseline_ref, 'baseline-abc',  'arena baseline survives round-trip';
  is $replay->steps,              $session->steps, 'steps are identical after round-trip';
  is $replay->to_jsonl,           $jsonl,          're-serialization is byte-stable';

  # seq must serialize as a bare JSON number for every record, not a string:
  # a dualvar seq encodes inconsistently across JSON backends.
  unlike $jsonl, qr/"seq":"/mx, 'seq is a JSON number, never a quoted string';
};

subtest 'from_jsonl rejects a log without an opening meta record' => sub {
  my $bad = JSON->new->canonical->encode(
    {
      record_version => '1',
      session_id     => 'sess-1',
      seq            => 0,
      kind           => 'action',
      type           => 'publish_control',
      payload        => {},
    }
  ) . "\n";
  like dies { Overnet::Burner::Adversary::Session->from_jsonl($bad) },
    qr/must\ begin\ with\ a\ session_open\ meta\ record/mx, 'meta-first is enforced';
};

done_testing;
