use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Adversary::Profile;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Server;

# The neutrality proof for the adversary subsystem. The runner, oracle, session,
# and server carry no IRC-specific code; the profile registry is the only seam an
# application plugs into. So the very same generic engine that judges the IRC
# hosted-channel authority must judge a deliberately non-IRC authority - the
# document-vault, where a scope has one owner who alone may delegate write access
# - and reach the correct verdict in both directions. This test drives that
# non-IRC profile through the unmodified engine.

my $SCOPE   = 'vault:reports';
my $PROFILE = Overnet::Burner::Adversary::Profile->resolve('document-vault');

sub _run {
  my (%args) = @_;
  return Overnet::Burner::Adversary::Runner->new->run(
    driver       => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $args{actions}),
    arena        => $PROFILE->build_arena(seed => '1'),
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => $args{ground_truth},
    session_id   => $args{session_id},
    seed         => '1',
  );
}

subtest 'the generic engine defends a correct non-IRC authority' => sub {
  my $result = _run(
    session_id => 'vault-defended',
    actions    => [

      # The owner legitimately delegates write access; the attacker forges its
      # own grant, which the authority must reject.
      {type => 'publish_grant',      payload => {actor   => 'owner',    delegate => 'writer'}},
      {type => 'publish_grant',      payload => {actor   => 'attacker', delegate => 'attacker'}},
      {type => 'observe_capability', payload => {subject => 'attacker', scope    => $SCOPE}},
      {type => 'observe_capability', payload => {subject => 'writer',   scope    => $SCOPE}},
    ],
    ground_truth => {authorized_capabilities => [{subject => 'writer', capability => 'vault.writer', scope => $SCOPE}]},
  );

  ok !$result->{verdict}{violated}, 'the vault authority defends the forged writer grant';
  is $result->{verdict}{invariants}{authorization}{status}, 'upheld', 'the authorization invariant is upheld';

  my @outcomes = map { $_->{payload}{accepted} }
    grep { $_->{type} eq 'relay_outcome' } @{$result->{session}->steps_of_kind('observation')};
  is \@outcomes, [1, 0], 'the owner grant is accepted and the forged grant refused';

  my @caps = map { $_->{payload}{subject} }
    grep { $_->{type} eq 'observed_capability' } @{$result->{session}->steps_of_kind('observation')};
  is \@caps, ['writer'], 'only the legitimately granted writer is observed to hold write access';
};

subtest 'the same generic engine catches a real authorization violation in vault vocabulary' => sub {
  my $result = _run(
    session_id => 'vault-violation',
    actions    => [

      # The owner really does grant a rogue write access, so the authority's
      # derived state genuinely confers the capability - but the harness's
      # independent ground truth authorizes no one, so the oracle must fire.
      {type => 'publish_grant',      payload => {actor   => 'owner', delegate => 'rogue'}},
      {type => 'observe_capability', payload => {subject => 'rogue', scope    => $SCOPE}},
    ],
    ground_truth => {authorized_capabilities => []},
  );

  ok $result->{verdict}{violated}, 'an unauthorized write capability the authority really confers is caught';
  is $result->{verdict}{invariants}{authorization}{status}, 'violated', 'the authorization invariant fires';

  my ($finding) = grep { $_->{invariant} eq 'authorization' } @{$result->{verdict}{findings}};
  is $finding->{subject},    'rogue',        'the finding names the unauthorized subject';
  is $finding->{capability}, 'vault.writer', 'the finding names the vault capability';
  is $finding->{scope},      $SCOPE,         'the finding names the vault scope';
};

subtest 'the non-IRC profile is reachable through the transport-neutral server' => sub {
  my $server = Overnet::Burner::Adversary::Server->new;

  my $created = $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {
      session_id   => 'vault-http',
      seed         => '1',
      arena        => {type                    => 'live', profile => 'document-vault'},
      ground_truth => {authorized_capabilities => []},
    },
  );
  is $created->{status}, 201, 'the server creates a document-vault session';
  is $created->{body}{baseline_ref}, 'live:Overnet::Burner::Adversary::Arena::DocumentVault',
    'the session is bound to the document-vault authority';

  my $stepped = $server->dispatch(
    method => 'POST',
    path   => '/sessions/vault-http/actions',
    body   => {
      actions => [
        {type => 'publish_grant',      payload => {actor   => 'owner', delegate => 'rogue'}},
        {type => 'observe_capability', payload => {subject => 'rogue', scope    => $SCOPE}},
      ],
    },
  );
  is $stepped->{status}, 200, 'the server applies the actions';

  my $verdict = $server->dispatch(method => 'GET', path => '/sessions/vault-http/verdict');
  is $verdict->{status}, 200, 'the server returns a verdict';
  ok $verdict->{body}{verdict}{violated}, 'the server-driven vault session is judged violated by the same oracle';
};

done_testing;
