package Overnet::Burner::Adversary::Attack;

use strictures 2;

use Carp qw(croak);

use Overnet::Burner::Adversary::Profile;
use Overnet::Burner::Adversary::Session;

our $VERSION = '0.001';

# The seed-attack catalog is supplied by the active adversary application
# profile (default: the IRC hosted-channel authority). This module holds only
# the driver-neutral operations over a catalog -- naming, lookup, and building
# sessions and interactions -- so a different application swaps its own catalog
# in behind the same interface. See L<Overnet::Burner::Adversary::Profile>.
sub _catalog {
  return Overnet::Burner::Adversary::Profile->default_profile->attack_catalog;
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

A driver-neutral accessor over the active adversary application profile's
seed-attack catalog (default: the IRC hosted-channel authority; see
L<Overnet::Burner::Adversary::Profile>). Each catalog entry is pinned to the
oracle invariant it exercises and mapped onto a known class of authority
defect, carrying the harness's independent ground truth, the action sequence a
driver submits, and two illustrative system-under-test transcripts: the
observations a defended (spec-conformant) system exposes and those a vulnerable
one exposes.

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

Requires L<Overnet::Burner::Adversary::Profile> and
L<Overnet::Burner::Adversary::Session>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
