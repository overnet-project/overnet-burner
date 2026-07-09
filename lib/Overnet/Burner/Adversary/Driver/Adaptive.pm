package Overnet::Burner::Adversary::Driver::Adaptive;

use strictures 2;
use Moo;

use Carp qw(croak);

our $VERSION = '0.001';

has policy    => (is => 'ro', required => 1);
has max_turns => (is => 'ro');

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  if (ref($args{policy}) ne 'CODE') {
    croak "policy must be a code reference\n";
  }

  my $max_turns = defined $args{max_turns} ? $args{max_turns} : 1000;
  if (!(!ref($max_turns) && $max_turns =~ /\A[1-9][0-9]*\z/mxs)) {
    croak "max_turns must be a positive integer\n";
  }

  return {policy => $args{policy}, max_turns => $max_turns};
}

sub goal_seeking {
  my ($class, %args) = @_;

  my $attempts = $args{attempts};
  if (ref($attempts) ne 'ARRAY') {
    croak "attempts must be an array reference of action batches\n";
  }
  for my $batch (@{$attempts}) {
    if (ref($batch) ne 'ARRAY') {
      croak "each attempt must be an array reference of actions\n";
    }
  }
  if (defined $args{succeeded} && ref($args{succeeded}) ne 'CODE') {
    croak "succeeded must be a code reference\n";
  }
  if (defined $args{on_success} && ref($args{on_success}) ne 'CODE') {
    croak "on_success must be a code reference\n";
  }

  my $policy = _goal_seeking_policy(
    attempts   => [@{$attempts}],
    succeeded  => $args{succeeded},
    on_success => $args{on_success},
  );

  return $class->new(
    policy => $policy,
    (defined $args{max_turns} ? (max_turns => $args{max_turns}) : ()),
  );
}

sub next_actions {
  my ($self, $session) = @_;

  my $turn = $self->{_turn} ||= 0;
  if ($turn >= $self->max_turns) {
    return [];
  }

  my $observations = $session->steps_of_kind('observation');
  my $seen         = $self->{_seen} ||= 0;
  my @new          = @{$observations}[$seen .. $#{$observations}];

  my $context = {
    session          => $session,
    observations     => $observations,
    new_observations => \@new,
    turn             => $turn,
    memory           => ($self->{_memory} ||= {}),
  };

  my $actions = $self->policy->($context);
  if (ref($actions) ne 'ARRAY') {
    croak "policy must return an array reference of actions\n";
  }

  $self->{_seen} = scalar @{$observations};
  $self->{_turn} = $turn + 1;

  return [map { _copy($_) } @{$actions}];
}

sub _goal_seeking_policy {
  my (%args)     = @_;
  my $attempts   = $args{attempts};
  my $succeeded  = $args{succeeded};
  my $on_success = $args{on_success};

  return sub {
    my ($context) = @_;
    my $memory = $context->{memory};

    if ($memory->{done}) {
      return [];
    }
    if ($succeeded && $succeeded->($context)) {
      $memory->{done} = 1;
      return $on_success ? ($on_success->($context) || []) : [];
    }

    my $cursor = $memory->{cursor} ||= 0;
    if ($cursor >= scalar @{$attempts}) {
      $memory->{done} = 1;
      return [];
    }
    $memory->{cursor} = $cursor + 1;
    return $attempts->[$cursor];
  };
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

Overnet::Burner::Adversary::Driver::Adaptive - a driver that decides its next actions from what it has observed

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # A deterministic, goal-seeking campaign: try each attack vector in turn,
  # stop as soon as the attacker is observed holding a capability.
  my $driver = Overnet::Burner::Adversary::Driver::Adaptive->goal_seeking(
    attempts  => [\@forged_grant_vector, \@forged_snapshot_vector],
    succeeded => sub {
      my ($context) = @_;
      return scalar grep {
        $_->{type} eq 'observed_capability' && $_->{payload}{subject} eq 'attacker'
      } @{$context->{observations}};
    },
  );

  # Or supply any policy - including one backed by a model.
  my $driver = Overnet::Burner::Adversary::Driver::Adaptive->new(
    policy => sub { my ($context) = @_; return $model->next_actions($context); },
  );

=head1 DESCRIPTION

An adaptive driver reacts: on each turn it inspects the observations the arena
has produced so far and chooses what to do next, rather than replaying a fixed
plan. It implements the driver contract (a C<next_actions> method the runner and
server call) and supplies the I<mechanics> of the loop - windowing new
observations, carrying memory across turns, and stopping - while delegating the
I<decision> to a pluggable policy.

The policy is the seam. It is any code reference

  sub { my ($context) = @_; return \@actions }   # [] to stop

so the intelligence can be whatever the caller needs. A deterministic policy
branches on the observations in Perl; a model-backed policy serializes the
context into a prompt and parses the actions back. This driver is therefore
B<AI-drivable> without being B<AI-driven>: it ships a rule-based policy
(L</goal_seeking>) that needs no model, and the same slot accepts an autonomous
one unchanged.

=head2 The policy context

The policy is called once per turn with a context hash reference:

=over

=item * C<session> - the live session, if the policy wants the raw record.

=item * C<observations> - every observation record so far.

=item * C<new_observations> - only those appended since the previous turn.

=item * C<turn> - the zero-based turn index.

=item * C<memory> - a hash reference the policy owns and may mutate across turns
(cursors, seen sets, whatever state it needs).

=back

The policy returns an array reference of actions to submit this turn, or an
empty array reference to end the session.

=head1 SUBROUTINES/METHODS

=head2 new

Creates an adaptive driver. Requires C<policy> (a code reference) and takes an
optional C<max_turns> (default 1000) after which the driver stops regardless of
the policy.

=head2 goal_seeking

Builds an adaptive driver with a deterministic, goal-seeking policy. Takes
C<attempts> (an array reference of action batches, one tried per turn), an
optional C<succeeded> predicate C<< sub { my ($context) = @_; ... } >> checked
before each attempt, an optional C<on_success> C<< sub { my ($context) = @_;
return \@actions } >> emitted when the goal is first met, and an optional
C<max_turns>. The driver tries each attempt in order, stops early the moment
C<succeeded> is true, and stops when the attempts are exhausted.

=head2 next_actions

Returns the actions the policy chooses for this turn given the session's
observations so far, or an empty list to stop. Takes the current session.

=head1 DIAGNOSTICS

A non-code policy, a bad C<goal_seeking> specification, an invalid C<max_turns>,
or a policy that does not return an array reference are reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Moo>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
