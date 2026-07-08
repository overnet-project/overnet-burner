package Overnet::Burner::Adversary::Runner;

use strictures 2;
use Moo;

use Carp         qw(croak);
use Scalar::Util qw(blessed);

use Overnet::Burner::Adversary::Session;

our $VERSION = '0.001';

has max_steps => (is => 'ro', default => 1000);

sub run {
  my ($self, %args) = @_;
  my $driver       = $args{driver};
  my $arena        = $args{arena};
  my $oracle       = $args{oracle};
  my $ground_truth = defined $args{ground_truth} ? $args{ground_truth} : {};

  _require_role($driver, 'driver', 'next_actions');
  _require_role($arena,  'arena',  'apply', 'baseline_ref', 'reset');
  _require_role($oracle, 'oracle', 'evaluate');
  if (ref($ground_truth) ne 'HASH') {
    croak "ground_truth must be an object\n";
  }

  my $session = Overnet::Burner::Adversary::Session->new(
    session_id         => _required_scalar(\%args, 'session_id'),
    seed               => _required_scalar(\%args, 'seed'),
    arena_baseline_ref => $arena->baseline_ref,
  );

  $arena->reset;
  $self->_drive($driver, $arena, $session);

  my $verdict = $oracle->evaluate(session => $session, ground_truth => $ground_truth);
  return {session => $session, verdict => $verdict};
}

sub _drive {
  my ($self, $driver, $arena, $session) = @_;

  my $steps = 0;
  while (1) {
    my $actions = $driver->next_actions($session);
    if (ref($actions) ne 'ARRAY') {
      croak "driver next_actions must return an array reference\n";
    }
    if (!@{$actions}) {
      last;
    }

    for my $action (@{$actions}) {
      if ($steps >= $self->max_steps) {
        croak "runner exceeded max_steps ($self->{max_steps})\n";
      }
      $steps++;
      $self->_apply_action($arena, $session, $action);
    }
  }

  return;
}

sub _apply_action {
  my ($self, $arena, $session, $action) = @_;
  if (!(ref($action) eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
    croak "driver produced an action without a type\n";
  }

  $session->append_action(type => $action->{type}, payload => $action->{payload});

  my $observations = $arena->apply($action);
  if (ref($observations) ne 'ARRAY') {
    croak "arena apply must return an array reference\n";
  }
  for my $observation (@{$observations}) {
    if (!(ref($observation) eq 'HASH' && defined $observation->{type} && !ref($observation->{type}))) {
      croak "arena produced an observation without a type\n";
    }
    $session->append_observation(type => $observation->{type}, payload => $observation->{payload});
  }

  return;
}

sub _require_role {
  my ($object, $role, @methods) = @_;
  if (!blessed($object)) {
    croak "$role is required\n";
  }
  for my $method (@methods) {
    if (!$object->can($method)) {
      croak "$role must implement $method\n";
    }
  }
  return;
}

sub _required_scalar {
  my ($args, $field) = @_;
  my $value = $args->{$field};
  if (!(defined $value && !ref($value) && length $value)) {
    croak "$field is required\n";
  }
  return $value;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Runner - drives a driver against an arena and judges the session

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $result = Overnet::Burner::Adversary::Runner->new->run(
    driver       => $driver,
    arena        => $arena,
    oracle       => $oracle,
    ground_truth => {authorized_capabilities => [...]},
    session_id   => 'sess-1',
    seed         => '42',
  );
  # $result->{session}, $result->{verdict}

=head1 DESCRIPTION

The runner is the orchestration loop of the adversary harness. It repeatedly
asks the driver for the next actions, submits each to the arena, and records
both the action and the arena's observations into a session. When the driver
stops (returns no actions), the runner hands the completed session to the
oracle for judgment and returns both the session and the verdict.

The runner is deliberately policy-free: it neither decides what to attack (the
driver's job) nor what counts as a violation (the oracle's job). It only wires
them together over a single session and enforces a hard C<max_steps> bound so a
runaway driver cannot loop forever. This separation is what lets a scripted
driver, a recorded arena, and a live system under test all run through the same
loop unchanged.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a runner. Takes an optional C<max_steps> (default 1000), the maximum
number of actions the runner will submit before aborting.

=head2 run

Runs one adversary episode. Takes C<driver>, C<arena>, C<oracle>,
C<session_id>, C<seed>, and optional C<ground_truth>. Resets the arena, drives
the driver's actions through it into a fresh session, evaluates the session
with the oracle, and returns C<< { session => $session, verdict => $verdict } >>.

=head1 DIAGNOSTICS

Missing collaborators, collaborators that do not implement the required
methods, malformed actions or observations, and exceeding C<max_steps> are all
reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Moo> and L<Overnet::Burner::Adversary::Session>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
