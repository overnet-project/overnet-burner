package Overnet::Burner::Adversary::Fuzzer;

use strictures 2;
use Moo;

use Carp    qw(croak);
use English qw(-no_match_vars);
use JSON    ();

use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Runner;
use Overnet::Burner::Adversary::Driver::Scripted;

our $VERSION = '0.001';

my $DEFAULT_MAX_VARIANTS = 128;
my $JSON                 = JSON->new->utf8->canonical;

has arena_factory => (is => 'ro', required => 1);
has oracle        => (is => 'ro');
has operators     => (is => 'ro');
has max_variants  => (is => 'ro');

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  if (ref($args{arena_factory}) ne 'CODE') {
    croak "arena_factory must be a code reference returning a fresh arena\n";
  }

  my $operators = defined $args{operators} ? $args{operators} : _default_operators();
  if (ref($operators) ne 'ARRAY') {
    croak "operators must be an array reference of code references\n";
  }
  for my $operator (@{$operators}) {
    if (ref($operator) ne 'CODE') {
      croak "each operator must be a code reference\n";
    }
  }

  my $max_variants = defined $args{max_variants} ? $args{max_variants} : $DEFAULT_MAX_VARIANTS;
  if (!(!ref($max_variants) && $max_variants =~ /\A[1-9][0-9]*\z/mxs)) {
    croak "max_variants must be a positive integer\n";
  }

  my $oracle = defined $args{oracle} ? $args{oracle} : Overnet::Burner::Adversary::Oracle->new;

  return {
    arena_factory => $args{arena_factory},
    oracle        => $oracle,
    operators     => [@{$operators}],
    max_variants  => $max_variants,
  };
}

sub explore {
  my ($self, %args) = @_;
  my $base = $args{base};
  if (ref($base) ne 'ARRAY') {
    croak "base must be an array reference of actions\n";
  }
  for my $action (@{$base}) {
    if (!(ref($action) eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
      croak "each base action must be an object with a type\n";
    }
  }
  my $ground_truth = defined $args{ground_truth} ? $args{ground_truth} : {};
  if (ref($ground_truth) ne 'HASH') {
    croak "ground_truth must be an object\n";
  }
  my $seed = defined $args{seed} ? $args{seed} : '1';

  my @variants = $self->_variants($base);

  my $total    = scalar @variants;
  my @explored = @variants;
  if ($total > $self->max_variants) {
    @explored = @variants[0 .. $self->max_variants - 1];
  }

  my @findings;
  my @errors;
  for my $variant (@explored) {
    my $outcome = eval { $self->_run_variant($variant, $ground_truth, $seed) };
    if (!$outcome) {
      push @errors, {label => $variant->{label}, message => _one_line($EVAL_ERROR)};
      next;
    }
    if ($outcome->{verdict}{violated}) {
      push @findings,
        {
        label   => $variant->{label},
        actions => $variant->{actions},
        verdict => $outcome->{verdict},
        };
    }
  }

  return {
    explored       => scalar @explored,
    total_variants => $total,
    truncated      => $total - scalar @explored,
    findings       => \@findings,
    errors         => \@errors,
  };
}

sub _run_variant {
  my ($self, $variant, $ground_truth, $seed) = @_;
  my $driver = Overnet::Burner::Adversary::Driver::Scripted->new(actions => $variant->{actions});
  return Overnet::Burner::Adversary::Runner->new->run(
    driver       => $driver,
    arena        => $self->arena_factory->(),
    oracle       => $self->oracle,
    ground_truth => $ground_truth,
    session_id   => "fuzz-$variant->{label}",
    seed         => $seed,
  );
}

# Build the deterministic variant list: the unchanged base first, then every
# operator's mutants in a stable order, deduplicated by canonical action digest
# so the same structural mutant is never explored twice.
sub _variants {
  my ($self, $base) = @_;

  my @candidates = ({label => 'identity', actions => _copy($base)});
  for my $operator (@{$self->operators}) {
    my $mutants = $operator->($base);
    if (ref($mutants) ne 'ARRAY') {
      croak "operator must return an array reference of mutants\n";
    }
    for my $mutant (@{$mutants}) {
      if (
        !(
             ref($mutant) eq 'HASH'
          && defined $mutant->{label}
          && !ref($mutant->{label})
          && length $mutant->{label}
          && ref($mutant->{actions}) eq 'ARRAY'
        )
      ) {
        croak "each mutant must have a label and an actions array reference\n";
      }
      push @candidates, {label => $mutant->{label}, actions => _copy($mutant->{actions})};
    }
  }

  my @ordered = sort { _variant_order($a, $b) } @candidates;

  my %seen;
  my @unique;
  for my $variant (@ordered) {
    my $digest = $JSON->encode($variant->{actions});
    if ($seen{$digest}++) {
      next;
    }
    push @unique, $variant;
  }

  return @unique;
}

# The base scenario always sorts first; the rest sort by label so exploration is
# reproducible and the variant budget always drops the same tail.
sub _variant_order {
  my ($one, $two) = @_;
  my $one_base = $one->{label} eq 'identity' ? 0 : 1;
  my $two_base = $two->{label} eq 'identity' ? 0 : 1;
  if ($one_base != $two_base) {
    return $one_base <=> $two_base;
  }
  return $one->{label} cmp $two->{label};
}

sub _default_operators {
  return [\&_op_drop, \&_op_duplicate, \&_op_swap_adjacent, \&_op_collide_created_at];
}

sub _op_drop {
  my ($actions) = @_;
  my @mutants;
  for my $index (0 .. $#{$actions}) {
    my @mutant = @{$actions};
    splice @mutant, $index, 1;
    push @mutants, {label => "drop\@$index", actions => \@mutant};
  }
  return \@mutants;
}

sub _op_duplicate {
  my ($actions) = @_;
  my @mutants;
  for my $index (0 .. $#{$actions}) {
    my @mutant = @{$actions};
    splice @mutant, $index, 0, $actions->[$index];
    push @mutants, {label => "dup\@$index", actions => \@mutant};
  }
  return \@mutants;
}

sub _op_swap_adjacent {
  my ($actions) = @_;
  my @mutants;
  for my $index (0 .. $#{$actions} - 1) {
    my @mutant = @{$actions};
    @mutant[$index, $index + 1] = @mutant[$index + 1, $index];
    push @mutants, {label => "swap\@$index", actions => \@mutant};
  }
  return \@mutants;
}

# Force two events to share a created_at, collapsing the ordering the system
# would otherwise rely on. This is the mutation that probes replay and
# same-second-convergence defects.
sub _op_collide_created_at {
  my ($actions) = @_;
  my @timed = grep { _has_created_at($actions->[$_]) } 0 .. $#{$actions};

  my @mutants;
  for my $i (0 .. $#timed) {
    for my $j ($i + 1 .. $#timed) {
      my $early  = $timed[$i];
      my $later  = $timed[$j];
      my @mutant = map { _copy($_) } @{$actions};
      $mutant[$later]{payload}{created_at} = $actions->[$early]{payload}{created_at};
      push @mutants, {label => "collide\@$early:$later", actions => \@mutant};
    }
  }
  return \@mutants;
}

sub _has_created_at {
  my ($action) = @_;
  return
       ref($action) eq 'HASH'
    && ref($action->{payload}) eq 'HASH'
    && defined $action->{payload}{created_at}
    && !ref($action->{payload}{created_at}) ? 1 : 0;
}

sub _one_line {
  my ($message) = @_;
  my $text = defined $message ? "$message" : 'unknown error';
  $text =~ s/\s+/ /gmxs;
  $text =~ s/\A\s+|\s+\z//gmxs;
  return $text;
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

Overnet::Burner::Adversary::Fuzzer - a mutation-search harness that hunts for oracle violations

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $profile = Overnet::Burner::Adversary::Profile->default_profile;
  my $fuzzer  = Overnet::Burner::Adversary::Fuzzer->new(
    arena_factory => sub { $profile->build_arena(seed => '1') },
  );
  my $result = $fuzzer->explore(
    base         => \@attack_actions,
    ground_truth => {authorized_capabilities => [...]},
    seed         => '1',
  );
  # $result->{findings} - variants the system under test failed to defend

=head1 DESCRIPTION

The fuzzer takes one base attack - a list of arena actions - and explores the
neighbourhood of I<structural mutations> around it, replaying each mutant
against a fresh system under test and asking the oracle whether the mutation
opened a hole the base did not. It turns a single hand-written scenario into a
search over many, so a defect that only surfaces when events are reordered,
dropped, duplicated, or collide on a timestamp is found without anyone writing
that exact scenario by hand.

It is deliberately built from the existing harness parts rather than around
them: each variant is driven by an L<Overnet::Burner::Adversary::Driver::Scripted>
through an L<Overnet::Burner::Adversary::Runner> against an arena the caller's
factory produces, and judged by an L<Overnet::Burner::Adversary::Oracle>. A
finding is any variant whose verdict is C<violated>. Running the fuzzer over a
hardened system and finding nothing is itself a result: the system withstands
the whole explored neighbourhood of that attack.

=head2 The AI-drivable seam

Mutation is done by B<operators>, and the operator list is the seam. An operator
is any code reference

  sub { my ($actions) = @_; return [ {label => '...', actions => \@mutant}, ... ] }

so the search strategy can be whatever the caller supplies: the built-in set is
exhaustive and deterministic (drop, duplicate, swap-adjacent, collide
timestamps), but a caller may pass a smarter or model-guided generator in the
same slot. This makes the fuzzer B<AI-drivable> without being B<AI-driven>.

L<Overnet::Burner::Adversary::Operator::Guided> is one such generator: a
I<semantic> operator that mutates an attack within an application's vocabulary
and identity graph - substituting one identity, scope, capability, or grant kind
for another - reaching holes the structural operators cannot express, and itself
exposing a C<propose> seam a model can drive.

=head2 Determinism and budget

The built-in operators enumerate mutants deterministically, and variants are
ordered stably (the unchanged base first, then by label) and deduplicated by a
canonical digest of their actions, so a fixed base and operator set always
explore the same variants in the same order. C<max_variants> bounds the number
explored; when the generated set is larger, the tail is dropped and the count
reported in C<truncated> rather than silently discarded. The C<seed> is
forwarded to each run so the arena and session are reproducible.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a fuzzer. Requires C<arena_factory> (a code reference returning a fresh
arena per variant). Takes optional C<oracle> (default a new
L<Overnet::Burner::Adversary::Oracle>), C<operators> (default the built-in set),
and C<max_variants> (default 128).

=head2 explore

Explores the mutation neighbourhood of a base attack. Takes C<base> (an array
reference of arena actions), optional C<ground_truth> (default C<{}>), and
optional C<seed> (default C<1>). Returns a hash reference with C<explored> (how
many variants ran), C<total_variants> (how many were generated), C<truncated>
(how many the budget dropped), C<findings> (each C<< {label, actions, verdict}
>> for a variant the oracle judged violated), and C<errors> (each C<< {label,
message} >> for a variant whose run threw).

=head1 DIAGNOSTICS

A non-code C<arena_factory>, non-code operators, an invalid C<max_variants>, a
non-array C<base>, a base action without a type, a non-object C<ground_truth>,
and an operator that does not return well-formed mutants are all reported with
C<croak>. A variant whose run dies is caught and reported in C<errors> rather
than aborting the search.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Moo>, L<JSON>, L<Overnet::Burner::Adversary::Oracle>,
L<Overnet::Burner::Adversary::Runner>, and
L<Overnet::Burner::Adversary::Driver::Scripted>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The built-in operators apply one mutation at a time, so defects that require a
combination of mutations are not reached by the default set; a caller that needs
deeper search supplies composing operators. Exploration cost is linear in the
number of variants times the cost of one run against the arena.

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
