package Overnet::Burner::Adversary::Attack;

use strictures 2;

use Carp qw(croak);

use Overnet::Burner::Adversary::Session;

our $VERSION = '0.001';

my $LEGIT_OPERATOR = {subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'};

# The seed-attack catalog: driver-neutral adversary scenarios, each pinned to
# the oracle invariant it exercises. Every entry carries the harness's
# independent ground truth, the action sequence a driver would submit, and two
# illustrative system-under-test transcripts - the observations a defended
# (spec-conformant) system exposes versus those a vulnerable one exposes. The
# transcripts make each attack a self-contained regression scenario until an
# arena replays the actions against a live system under test.
sub _catalog {
  return {
    forged_grant_escalation => {
      description      => 'A nobody forges a session delegation and grants itself operator (core C1).',
      target_invariant => 'authorization',
      ground_truth     => {authorized_capabilities => [_copy($LEGIT_OPERATOR)]},
      actions          => [
        {type => 'new_identity', payload => {identity => 'attacker-pk'}},
        {
          type    => 'forge_delegation',
          payload => {actor => 'attacker-pk', delegate => 'attacker-session', authority => 'forged-grant'},
        },
        {
          type    => 'publish_control',
          payload => {kind => 9000, signer => 'attacker-session', actor => 'attacker-pk', role => 'irc.operator'},
        },
      ],
      defended => [
        {type => 'relay_outcome',       payload => {accepted => 0, reason => 'unauthorized'}},
        {type => 'observed_capability', payload => _copy($LEGIT_OPERATOR)},
      ],
      exploited => [
        {type => 'relay_outcome', payload => {accepted => 1}},
        {
          type    => 'observed_capability',
          payload => {subject => 'attacker-pk', capability => 'irc.operator', scope => 'channel:#ops'},
        },
      ],
    },

    forged_snapshot_self_grant => {
      description      => 'A non-authoritative signer publishes a role snapshot naming itself operator (core C2).',
      target_invariant => 'authorization',
      ground_truth     => {authorized_capabilities => [_copy($LEGIT_OPERATOR)]},
      actions          => [
        {type => 'new_identity', payload => {identity => 'attacker-pk'}},
        {
          type    => 'publish_snapshot',
          payload =>
            {kind => 39_001, signer => 'attacker-pk', grants => [{subject => 'attacker-pk', role => 'irc.operator'}]},
        },
      ],
      defended => [
        {type => 'relay_outcome',       payload => {accepted => 0, reason => 'unauthorized'}},
        {type => 'observed_capability', payload => _copy($LEGIT_OPERATOR)},
      ],
      exploited => [
        {type => 'relay_outcome', payload => {accepted => 1}},
        {
          type    => 'observed_capability',
          payload => {subject => 'attacker-pk', capability => 'irc.operator', scope => 'channel:#ops'},
        },
      ],
    },

    ban_mask_evasion => {
      description      => 'A banned subject joins while omitting or spoofing the mask the ban matches.',
      target_invariant => 'admission',
      ground_truth     => {expected_admissions => [{subject => 'banned-pk', scope => 'channel:#ops', admitted => 0}]},
      actions          => [
        {type => 'new_identity', payload => {identity => 'banned-pk'}},
        {type => 'join',         payload => {subject  => 'banned-pk', scope => 'channel:#ops', mask => undef}},
      ],
      defended =>
        [{type => 'observed_admission', payload => {subject => 'banned-pk', scope => 'channel:#ops', admitted => 0}}],
      exploited =>
        [{type => 'observed_admission', payload => {subject => 'banned-pk', scope => 'channel:#ops', admitted => 1}}],
    },

    ordering_divergence => {
      description      => 'Same-second control events drive two instances to different authority state.',
      target_invariant => 'convergence',
      ground_truth     => {},
      actions          => [
        {
          type    => 'publish_control',
          payload => {kind => 9000, created_at => 1000, subject => 'mallory-pk', role => 'irc.operator'}
        },
        {type => 'publish_control', payload => {kind => 9001, created_at => 1000, subject => 'mallory-pk'}},
      ],
      defended => [
        {
          type    => 'observed_state',
          payload => {instance => 'instance-a', scope => 'channel:#ops', state => {operators => ['operator-pk']}}
        },
        {
          type    => 'observed_state',
          payload => {instance => 'instance-b', scope => 'channel:#ops', state => {operators => ['operator-pk']}}
        },
      ],
      exploited => [
        {
          type    => 'observed_state',
          payload => {instance => 'instance-a', scope => 'channel:#ops', state => {operators => ['operator-pk']}}
        },
        {
          type    => 'observed_state',
          payload =>
            {instance => 'instance-b', scope => 'channel:#ops', state => {operators => ['operator-pk', 'mallory-pk']}}
        },
      ],
    },
  };
}

sub names {
  return [sort keys %{_catalog()}];
}

sub attack {
  my ($class, $name) = @_;
  my $catalog = _catalog();
  if (!(defined $name && !ref($name) && exists $catalog->{$name})) {
    my $shown = defined $name && !ref($name) ? $name : '(undef)';
    croak "unknown attack: $shown\n";
  }
  return $catalog->{$name};
}

sub session {
  my ($class, $name, %args) = @_;
  my $attack  = $class->attack($name);
  my $outcome = defined $args{outcome} ? $args{outcome} : 'exploited';
  if (!($outcome eq 'defended' || $outcome eq 'exploited')) {
    croak "outcome must be defended or exploited\n";
  }

  my $session = Overnet::Burner::Adversary::Session->new(
    session_id         => "$name-$outcome",
    seed               => (defined $args{seed} ? $args{seed} : '1'),
    arena_baseline_ref => 'catalog',
  );
  for my $action (@{$attack->{actions}}) {
    $session->append_action(type => $action->{type}, payload => _copy($action->{payload}));
  }
  for my $observation (@{$attack->{$outcome}}) {
    $session->append_observation(type => $observation->{type}, payload => _copy($observation->{payload}));
  }
  return $session;
}

sub interaction {
  my ($class, $name, %args) = @_;
  my $attack  = $class->attack($name);
  my $outcome = defined $args{outcome} ? $args{outcome} : 'exploited';
  if (!($outcome eq 'defended' || $outcome eq 'exploited')) {
    croak "outcome must be defended or exploited\n";
  }

  my @actions   = map { _copy($_) } @{$attack->{actions}};
  my @responses = map { [] } @actions;

  # The catalog's outcome observations are the whole transcript for the attack;
  # a recorded arena aligns one response batch to each action, so we attach the
  # entire transcript to the final action. The oracle judges the session by its
  # observations regardless of which action they trail, so the verdict matches
  # the equivalent Attack->session exactly.
  if (@responses) {
    $responses[-1] = [map { _copy($_) } @{$attack->{$outcome}}];
  }

  return {actions => \@actions, responses => \@responses};
}

sub _copy {
  my ($value) = @_;
  if (ref($value) eq 'HASH') {
    return {map { $_ => _copy($value->{$_}) } keys %{$value}};
  }
  if (ref($value) eq 'ARRAY') {
    return [map { _copy($_) } @{$value}];
  }
  return $value;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Attack - catalog of seed adversary scenarios

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $names   = Overnet::Burner::Adversary::Attack->names;
  my $attack  = Overnet::Burner::Adversary::Attack->attack('forged_grant_escalation');
  my $session = Overnet::Burner::Adversary::Attack->session(
    'forged_grant_escalation', outcome => 'exploited',
  );

=head1 DESCRIPTION

A curated, driver-neutral catalog of adversary scenarios, each pinned to the
oracle invariant it exercises and mapped onto a known class of authority
defect. Each entry carries the harness's independent ground truth, the action
sequence a driver submits, and two illustrative system-under-test transcripts:
the observations a defended (spec-conformant) system exposes and those a
vulnerable one exposes.

The transcripts make each attack a self-contained regression scenario that can
be judged by L<Overnet::Burner::Adversary::Oracle> without a live system under
test. When an arena is available, the same action sequence is replayed against
a real system under test and the observations come from reality instead.

The catalog is not a claim of completeness; it seeds the regression corpus that
adaptive drivers extend.

=head1 SUBROUTINES/METHODS

=head2 names

Returns the sorted list of catalog attack names.

=head2 attack

Returns the catalog entry for a name (description, target_invariant,
ground_truth, actions, and the defended and exploited transcripts). Dies on an
unknown name.

=head2 session

Builds an L<Overnet::Burner::Adversary::Session> for an attack. Takes the attack
name and optional C<outcome> (C<defended> or C<exploited>, default C<exploited>)
and C<seed>. The session replays the attack's actions and then the observations
for the chosen outcome.

=head2 interaction

Builds the driver-and-arena view of an attack for
L<Overnet::Burner::Adversary::Runner>. Takes the attack name and optional
C<outcome> (C<defended> or C<exploited>, default C<exploited>). Returns
C<< { actions => [...], responses => [...] } >>: the actions a driver submits
and a positionally-aligned list of recorded observation batches (one per
action) for a L<Overnet::Burner::Adversary::Arena::Recorded>. The outcome's
whole transcript is attached to the final action's batch.

=head1 DIAGNOSTICS

Unknown attack names and invalid outcomes are reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Overnet::Burner::Adversary::Session>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
