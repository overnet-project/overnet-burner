package Overnet::Burner::Adversary::Operator::Guided;

use strictures 2;
use Moo;

use Carp qw(croak);

our $VERSION = '0.001';

# Which payload fields draw their substitutions from which domain. Identity
# fields draw from the attack's own identity graph (the names it already uses);
# scope, capability, and kind fields draw from the application vocabulary. This
# map is what makes the mutation "in-model": a substitution only ever replaces a
# value with another value the same application understands.
my %FIELD_DOMAIN = (
  actor      => 'identity',
  delegate   => 'identity',
  signer     => 'identity',
  subject    => 'identity',
  name       => 'identity',
  scope      => 'scope',
  capability => 'capability',
  role       => 'capability',
  kind       => 'kind',
);

has vocabulary => (is => 'ro', required => 1);
has identities => (is => 'ro');
has propose    => (is => 'ro');

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  if (ref($args{vocabulary}) ne 'HASH') {
    croak "vocabulary must be a hash reference (a profile vocabulary)\n";
  }
  if (defined $args{propose} && ref($args{propose}) ne 'CODE') {
    croak "propose must be a code reference\n";
  }
  my $identities = defined $args{identities} ? $args{identities} : [];
  if (ref($identities) ne 'ARRAY') {
    croak "identities must be an array reference of identity names\n";
  }

  return {
    vocabulary => $args{vocabulary},
    identities => [@{$identities}],
    (defined $args{propose} ? (propose => $args{propose}) : ()),
  };
}

# Return the fuzzer operator: a code reference mapping a base action list to a
# list of labelled mutants, ready for the fuzzer's `operators` slot.
sub operator {
  my ($self) = @_;
  return sub {
    my ($actions) = @_;
    return $self->mutate($actions);
  };
}

sub mutate {
  my ($self, $actions) = @_;
  if (ref($actions) ne 'ARRAY') {
    croak "actions must be an array reference\n";
  }

  if ($self->propose) {
    return $self->_proposed($actions);
  }
  return $self->_guided($actions);
}

# The model seam: hand the model the base and the in-model domains it may draw
# from, and take back its proposed mutants. This is what makes the operator
# AI-drivable - a model-backed proposer drops into the same slot as the built-in
# rule-based one - without being AI-driven.
sub _proposed {
  my ($self, $actions) = @_;

  my $context = {
    actions    => _copy($actions),
    vocabulary => _copy($self->vocabulary),
    identities => [$self->_identity_pool($actions)],
  };
  my $mutants = $self->propose->($context);
  if (ref($mutants) ne 'ARRAY') {
    croak "propose must return an array reference of mutants\n";
  }
  for my $mutant (@{$mutants}) {
    _assert_mutant($mutant);
  }
  return [map { {label => $_->{label}, actions => _copy($_->{actions})} } @{$mutants}];
}

# The built-in, deterministic, vocabulary-guided proposer. For each payload
# field it recognizes, it substitutes every other in-model value that field
# could hold - a different identity from the attack's own graph, a different
# scope/capability/grant-kind from the vocabulary - one substitution per mutant.
# This explores the semantic neighbourhood the structural operators (drop,
# duplicate, swap, collide) cannot reach: does the system confuse one identity,
# scope, or capability for another?
sub _guided {
  my ($self, $actions) = @_;

  my %pool = (
    identity   => [$self->_identity_pool($actions)],
    scope      => [_vocabulary_values($self->vocabulary, 'scopes')],
    capability => [_vocabulary_values($self->vocabulary, 'capabilities')],
    kind       => [_vocabulary_values($self->vocabulary, 'grant_kinds')],
  );

  my @mutants;
  for my $index (0 .. $#{$actions}) {
    my $action = $actions->[$index];
    if (!(ref($action) eq 'HASH' && ref($action->{payload}) eq 'HASH')) {
      next;
    }
    for my $field (sort keys %{$action->{payload}}) {
      my $domain = $FIELD_DOMAIN{$field};
      if (!$domain) {
        next;
      }
      my $current = $action->{payload}{$field};
      if (ref($current)) {
        next;
      }
      for my $alternative (@{$pool{$domain}}) {
        if ($alternative eq $current) {
          next;
        }
        my @mutated = map { _copy($_) } @{$actions};
        $mutated[$index]{payload}{$field} = $alternative;
        push @mutants, {label => "$field=$alternative\@$index", actions => \@mutated};
      }
    }
  }

  return \@mutants;
}

# The identity substitution pool: every identity name the attack already names,
# plus any the caller configured, sorted and de-duplicated so exploration is
# reproducible.
sub _identity_pool {
  my ($self, $actions) = @_;

  my %seen;
  for my $name (@{$self->identities}) {
    if (defined $name && !ref($name) && length $name) {
      $seen{$name} = 1;
    }
  }
  for my $action (@{$actions}) {
    if (!(ref($action) eq 'HASH' && ref($action->{payload}) eq 'HASH')) {
      next;
    }
    for my $field (keys %{$action->{payload}}) {
      if (($FIELD_DOMAIN{$field} || q{}) ne 'identity') {
        next;
      }
      my $value = $action->{payload}{$field};
      if (defined $value && !ref($value) && length $value) {
        $seen{$value} = 1;
      }
    }
  }
  my @names = sort keys %seen;
  return @names;
}

sub _vocabulary_values {
  my ($vocabulary, $key) = @_;
  my $values = $vocabulary->{$key};
  if (ref($values) ne 'ARRAY') {
    return ();
  }
  return grep { defined && !ref } @{$values};
}

sub _assert_mutant {
  my ($mutant) = @_;
  if (
    !(
         ref($mutant) eq 'HASH'
      && defined $mutant->{label}
      && !ref($mutant->{label})
      && length $mutant->{label}
      && ref($mutant->{actions}) eq 'ARRAY'
    )
  ) {
    croak "each proposed mutant must have a label and an actions array reference\n";
  }
  return;
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

Overnet::Burner::Adversary::Operator::Guided - a model-guided mutation operator for the fuzzer

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $profile = Overnet::Burner::Adversary::Profile->default_profile;
  my $guided  = Overnet::Burner::Adversary::Operator::Guided->new(
    vocabulary => $profile->vocabulary,
  );

  my $fuzzer = Overnet::Burner::Adversary::Fuzzer->new(
    arena_factory => sub { $profile->build_arena(seed => '1') },
    operators     => [$guided->operator],
  );
  my $result = $fuzzer->explore(base => \@attack_actions, ground_truth => {...});

  # Or hand the mutation decision to a model, in the same slot:
  my $model_guided = Overnet::Burner::Adversary::Operator::Guided->new(
    vocabulary => $profile->vocabulary,
    propose    => sub { my ($context) = @_; return $model->mutants($context) },
  );

=head1 DESCRIPTION

The fuzzer (L<Overnet::Burner::Adversary::Fuzzer>) explores the neighbourhood of
a base attack by applying B<operators>: code references that turn a base action
list into labelled mutants. Its built-in operators are I<structural> - drop,
duplicate, swap adjacent, collide timestamps - and blind to meaning. This
operator is I<semantic>: it mutates the attack B<within the application's own
model>, so it reaches holes the structural operators cannot express.

It draws its substitutions from two sources: the application C<vocabulary> a
profile supplies (scopes, capabilities, grant kinds) and the attack's own
identity graph (the identity names it already references). For each payload
field it recognizes, it emits one mutant per alternative in-model value - a
different identity in an C<actor>/C<delegate>/C<signer>/C<subject> slot, a
different scope, capability, or grant kind - asking, in effect, whether the
system under test confuses one identity, scope, or capability for another. Every
mutant stays a well-formed action the same application understands.

=head2 The AI-drivable seam

Like the adaptive driver's policy (L<Overnet::Burner::Adversary::Driver::Adaptive>),
the mutation decision is a pluggable seam. By default this operator uses a
deterministic, rule-based, vocabulary-guided proposer that needs no model. Supply
a C<propose> code reference and the operator hands that proposer the base and the
in-model domains it may draw from

  sub { my ($context) = @_; return [ {label => '...', actions => \@mutant}, ... ] }

where C<context> is C<< { actions => \@base, vocabulary => \%vocab, identities =>
\@names } >>, and takes back its mutants. A model-backed proposer therefore drops
into exactly the slot the rule-based one occupies: the operator is B<AI-drivable
without being AI-driven>.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a guided operator. Requires C<vocabulary> (a profile vocabulary hash
reference, as L<Overnet::Burner::Adversary::Profile> profiles return). Takes an
optional C<identities> (an array reference of extra identity names to add to the
substitution pool) and an optional C<propose> (a code reference that replaces the
built-in proposer).

=head2 operator

Returns the fuzzer operator: a code reference mapping a base action list to a
list of C<< {label, actions} >> mutants, ready for the fuzzer's C<operators>
slot.

=head2 mutate

Applies the operator to a base action list directly and returns its mutants.
This is what L</operator> wraps; call it when you want the mutants without the
code-reference indirection.

=head1 DIAGNOSTICS

A non-hash C<vocabulary>, a non-code C<propose>, a non-array C<identities>, a
non-array base action list, and a C<propose> proposer that returns anything
other than well-formed mutants are all reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Moo>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The built-in proposer substitutes one field at a time, so a hole that only opens
under a combination of substitutions is not reached by the default; a caller
that needs deeper search supplies a composing C<propose>. Report issues at
L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
