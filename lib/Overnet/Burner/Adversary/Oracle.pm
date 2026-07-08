package Overnet::Burner::Adversary::Oracle;

use strictures 2;
use Moo;

use Carp qw(croak);

our $VERSION = '0.001';

my $CLAIM_SEPARATOR = "\0";
my %VALID_STATUS    = map { $_ => 1 } qw(upheld violated inconclusive);

has invariants => (is => 'lazy');

sub _build_invariants {
  return {authorization => \&_authorization_invariant};
}

sub add_invariant {
  my ($self, $name, $check) = @_;
  if (!(defined $name && !ref($name) && length $name)) {
    croak "invariant name is required\n";
  }
  if (ref($check) ne 'CODE') {
    croak "invariant check must be a code reference\n";
  }
  $self->invariants->{$name} = $check;
  return 1;
}

sub evaluate {
  my ($self, %args) = @_;
  my $session      = $args{session};
  my $ground_truth = $args{ground_truth} || {};

  if (!(ref($session) && $session->can('steps_of_kind'))) {
    croak "session is required\n";
  }
  if (ref($ground_truth) ne 'HASH') {
    croak "ground_truth must be an object\n";
  }

  my %invariant_results;
  my @findings;
  for my $name (sort keys %{$self->invariants}) {
    my $result = $self->invariants->{$name}->($session, $ground_truth);
    my $status = $result->{status};
    if (!(defined $status && !ref($status) && $VALID_STATUS{$status})) {
      croak "invariant $name returned an invalid status\n";
    }
    my $invariant_findings = $result->{findings} || [];
    for my $finding (@{$invariant_findings}) {
      $finding->{invariant} = $name;
      push @findings, $finding;
    }
    $invariant_results{$name} = {
      status   => $status,
      findings => $invariant_findings,
    };
  }

  return {
    violated   => (scalar @findings ? 1 : 0),
    invariants => \%invariant_results,
    findings   => \@findings,
  };
}

sub _authorization_invariant {
  my ($session, $ground_truth) = @_;

  my %authorized = map { _claim_key($_) => 1 } @{$ground_truth->{authorized_capabilities} || []};

  my @observed;
  for my $step (@{$session->steps_of_kind('observation')}) {
    if ($step->{type} eq 'observed_capability') {
      push @observed, $step;
    }
  }

  if (!@observed) {
    return {status => 'inconclusive', findings => []};
  }

  my @findings;
  for my $step (@observed) {
    my $claim = $step->{payload};
    if (!$authorized{_claim_key($claim)}) {
      push @findings,
        {
        summary => sprintf(
          'subject %s holds capability %s in scope %s without an authorizing grant',
          _claim_field($claim, 'subject'),
          _claim_field($claim, 'capability'),
          _claim_field($claim, 'scope'),
        ),
        subject      => _claim_field($claim, 'subject'),
        capability   => _claim_field($claim, 'capability'),
        scope        => _claim_field($claim, 'scope'),
        evidence_seq => $step->{seq},
        };
    }
  }

  return {
    status   => (@findings ? 'violated' : 'upheld'),
    findings => \@findings,
  };
}

sub _claim_key {
  my ($claim) = @_;
  return join $CLAIM_SEPARATOR, map { _claim_field($claim, $_) } qw(subject capability scope);
}

sub _claim_field {
  my ($claim, $field) = @_;
  if (ref($claim) ne 'HASH') {
    return q{};
  }
  my $value = $claim->{$field};
  return defined($value) && !ref($value) ? $value : q{};
}

1;

=head1 NAME

Overnet::Burner::Adversary::Oracle - independent invariant judgment for adversary sessions

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $oracle  = Overnet::Burner::Adversary::Oracle->new;
  my $verdict = $oracle->evaluate(
    session      => $session,
    ground_truth => {
      authorized_capabilities => [
        {subject => 'operator', capability => 'irc.operator', scope => 'channel:#ops'},
      ],
    },
  );
  # $verdict->{violated}, $verdict->{invariants}, $verdict->{findings}

=head1 DESCRIPTION

The oracle judges an adversary session against machine-checkable invariants.
It is independent of both the driver that produced the session and the system
under test: its ground truth is supplied by the harness from the provenance of
the actions it injected, never read back from the system under test.

The built-in C<authorization> invariant enforces the core authority rule in a
protocol-neutral form: every capability the system under test is observed to
hold (an C<observed_capability> observation, with a C<subject>, C<capability>,
and C<scope>) must appear in the harness's set of authorized capabilities. An
observed capability with no authorizing grant is a finding - the generalized
shape of privilege escalation. With no observed capabilities the invariant is
C<inconclusive> rather than C<upheld>, because nothing was checked.

Additional invariants (admission, convergence, defense category, availability)
register through L</add_invariant>; a protocol profile maps its
implementation-specific observations onto the neutral claim shape this oracle
judges.

=head1 SUBROUTINES/METHODS

=head2 new

Creates an oracle with the built-in invariant set.

=head2 add_invariant

Registers an invariant. Takes a name and a code reference
C<< sub { my ($session, $ground_truth) = @_; return { status => ..., findings => [...] } } >>
where status is C<upheld>, C<violated>, or C<inconclusive>.

=head2 evaluate

Evaluates every invariant against a session and ground truth. Takes C<session>
and C<ground_truth>. Returns a verdict with C<violated> (boolean), per-invariant
C<invariants>, and a flat C<findings> list.

=head1 DIAGNOSTICS

Invalid arguments and invalid invariant results are reported with C<croak>.

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
