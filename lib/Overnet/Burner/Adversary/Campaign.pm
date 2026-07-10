package Overnet::Burner::Adversary::Campaign;

use strictures 2;
use Moo;

use Carp qw(croak);
use JSON ();

use Overnet::Burner::Adversary::Arena::Live;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Fuzzer;
use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Runner;

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

has corpus        => (is => 'ro', required => 1);
has arena_factory => (is => 'ro');
has oracle        => (is => 'ro');

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  if (!(defined $args{corpus} && ref $args{corpus} && $args{corpus}->can('entries') && $args{corpus}->can('add'))) {
    croak "corpus is required (an Overnet::Burner::Adversary::Corpus)\n";
  }

  my $arena_factory = defined $args{arena_factory} ? $args{arena_factory} : \&_default_arena_factory;
  if (ref $arena_factory ne 'CODE') {
    croak "arena_factory must be a code reference\n";
  }

  my $oracle = defined $args{oracle} ? $args{oracle} : Overnet::Burner::Adversary::Oracle->new;

  return {corpus => $args{corpus}, arena_factory => $arena_factory, oracle => $oracle};
}

# Sweep the mutation neighbourhood of every guarded attack (the corpus entries
# by default, or a supplied list of bases) against the live relay and aggregate
# the regressions: every variant the oracle now judges violated, tagged with the
# base it mutated. hunt only reports; it never writes to the corpus, because a
# live violation must not be committed into a green regression set.
sub hunt {
  my ($self, %args) = @_;

  my $base_list = defined $args{bases} ? $args{bases} : $self->corpus->entries;
  if (ref $base_list ne 'ARRAY') {
    croak "bases must be an array reference\n";
  }

  my @regressions;
  my @errors;
  my $explored = 0;
  for my $base (@{$base_list}) {
    _validate_base($base);

    my $fuzzer = Overnet::Burner::Adversary::Fuzzer->new(
      arena_factory => sub { return $self->arena_factory->($base) },
      oracle        => $self->oracle,
      (defined $args{max_variants} ? (max_variants => $args{max_variants}) : ()),
    );
    my $result = $fuzzer->explore(
      base         => $base->{actions},
      ground_truth => (ref $base->{ground_truth} eq 'HASH' ? $base->{ground_truth} : {}),
      seed         => (defined $base->{seed}               ? $base->{seed}         : '1'),
    );

    $explored += $result->{explored};
    my $baseline = $self->_baseline_digest($base, $base->{actions});
    for my $finding (@{$result->{findings}}) {

      # Only a mutation that preserves the honest baseline is a sound
      # regression. Dropping or reordering an authoritative snapshot changes the
      # world the ground truth was computed against, so its verdict is a
      # ground-truth artifact, not a reopened hole - the adversary does not get
      # to un-publish the honest authority's established state.
      if ($self->_baseline_digest($base, $finding->{actions}) ne $baseline) {
        next;
      }
      push @regressions,
        {
        base    => $base->{name},
        label   => $finding->{label},
        actions => $finding->{actions},
        verdict => $finding->{verdict},
        };
    }
    for my $error (@{$result->{errors}}) {
      push @errors, {base => $base->{name}, label => $error->{label}, message => $error->{message}};
    }
  }

  return {
    swept       => scalar @{$base_list},
    explored    => $explored,
    regressions => \@regressions,
    errors      => \@errors,
  };
}

# Grow the corpus, but only with an attack the system already withstands. An
# attack is promoted when it is currently defended (its replay verdict is not
# violated) and novel (no existing entry shares its canonical action signature).
# Promoting a live violation is refused; promoting a duplicate is a no-op.
sub promote {
  my ($self, $attack) = @_;

  _validate_base($attack);

  my $signature = $self->_signature($attack->{actions});
  for my $entry (@{$self->corpus->entries}) {
    if ($self->_signature($entry->{actions}) eq $signature) {
      return {added => 0, reason => 'already-guarded', name => $entry->{name}};
    }
  }

  my $verdict = $self->_replay($attack);
  if ($verdict->{violated}) {
    return {added => 0, reason => 'not-defended', verdict => $verdict};
  }

  my $path = $self->corpus->add($attack);
  return {added => 1, name => $attack->{name}, path => $path};
}

sub _replay {
  my ($self, $attack) = @_;

  my $result = Overnet::Burner::Adversary::Runner->new->run(
    driver       => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $attack->{actions}),
    arena        => $self->arena_factory->($attack),
    oracle       => $self->oracle,
    ground_truth => (ref $attack->{ground_truth} eq 'HASH' ? $attack->{ground_truth} : {}),
    session_id   => "promote-$attack->{name}",
    seed         => (defined $attack->{seed} ? $attack->{seed} : '1'),
  );
  return $result->{verdict};
}

sub _signature {
  my ($self, $actions) = @_;
  return $JSON->encode($actions);
}

# The honest baseline of a scenario is the ordered set of authoritative
# snapshots - publish_snapshot events signed by a declared snapshot signer. A
# mutation that leaves this digest unchanged has not disturbed the state the
# ground truth was computed against; forged snapshots (foreign signers) are not
# baseline and remain fair game for mutation.
sub _baseline_digest {
  my ($self, $base, $actions) = @_;

  my %is_signer = map { $_ => 1 } @{$base->{snapshot_signers} || []};
  my @baseline  = grep {
         ref $_ eq 'HASH'
      && defined $_->{type}
      && $_->{type} eq 'publish_snapshot'
      && ref $_->{payload} eq 'HASH'
      && defined $_->{payload}{signer}
      && $is_signer{$_->{payload}{signer}}
  } @{$actions};

  return $JSON->encode(\@baseline);
}

sub _default_arena_factory {
  my ($base) = @_;

  return Overnet::Burner::Adversary::Arena::Live->new(
    snapshot_signers => ($base->{snapshot_signers} || []),
    seed             => (defined $base->{seed} ? $base->{seed} : '1'),
  );
}

sub _validate_base {
  my ($base) = @_;

  if (ref $base ne 'HASH') {
    croak "base must be an object\n";
  }
  my $name = $base->{name};
  if (!(defined $name && !ref($name) && length $name)) {
    croak "base name is required\n";
  }
  if (!(ref $base->{actions} eq 'ARRAY' && @{$base->{actions}})) {
    croak "base actions must be a non-empty array\n";
  }
  return 1;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Campaign - the discover-then-guard loop over the corpus

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $corpus   = Overnet::Burner::Adversary::Corpus->new;
  my $campaign = Overnet::Burner::Adversary::Campaign->new(corpus => $corpus);

  # Hunt: sweep every guarded attack's mutation neighbourhood for reopened holes.
  my $sweep = $campaign->hunt(max_variants => 32);
  warn "regression: $_->{base}/$_->{label}" for @{$sweep->{regressions}};

  # Guard: once a hole is closed, promote the attack that found it.
  my $result = $campaign->promote(\%defended_attack);
  # $result->{added} is true only if the attack is defended and novel.

=head1 DESCRIPTION

The campaign is the loop that turns the L<fuzzer|Overnet::Burner::Adversary::Fuzzer>
and the L<corpus|Overnet::Burner::Adversary::Corpus> into an autonomous red-team
cycle, composing both without changing either. It splits the discover-then-guard
loop into its two honest halves.

L</hunt> sweeps the mutation neighbourhood of every guarded attack against the
live relay and aggregates the B<regressions> - every variant the oracle now
judges violated, tagged with the base it mutated. Over a hardened relay it finds
nothing; over a regressed relay it surfaces the reopened hole and the minimal
trace that reaches it. hunt only reports.

L</promote> is the guard half: it adds an attack to the corpus only when the
attack is B<currently defended> and B<novel>, so the only thing that ever enters
the corpus is a fresh attack the system already withstands. Promoting a live
violation is refused; promoting a duplicate is a no-op.

The arena is injectable through C<arena_factory>, so the loop runs against the
in-process live relay by default and against a stub in unit tests.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a campaign. Requires C<corpus> (an
L<Overnet::Burner::Adversary::Corpus>). Takes optional C<arena_factory> (a code
reference C<< sub { my ($base) = @_; ... } >> returning a fresh arena for a base;
default builds an L<Overnet::Burner::Adversary::Arena::Live> from the base's
C<snapshot_signers> and C<seed>) and C<oracle> (default a new
L<Overnet::Burner::Adversary::Oracle>).

=head2 hunt

Sweeps the mutation neighbourhood of a set of bases and returns the aggregated
result. Takes optional C<bases> (an array reference of attack descriptors;
default the corpus entries) and optional C<max_variants> (forwarded to the
fuzzer). Returns a hash reference with C<swept> (how many bases ran), C<explored>
(how many variants ran in total), C<regressions> (each C<< {base, label, actions,
verdict} >> for a variant judged violated), and C<errors> (each C<< {base, label,
message} >> for a variant whose run threw).

=head2 promote

Adds an attack to the corpus when it is currently defended and novel. Takes the
attack descriptor. Returns C<< {added => 1, name, path} >> on success, C<< {added
=> 0, reason => 'already-guarded', name} >> when an existing entry shares the
attack's canonical action signature, or C<< {added => 0, reason =>
'not-defended', verdict} >> when replaying the attack violates an invariant.

=head1 DIAGNOSTICS

A missing or unusable C<corpus>, a non-code C<arena_factory>, non-array C<bases>,
or a base without a name or actions are reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

Hunting and promoting against the default arena require
C<Overnet::Authority::HostedChannel::Relay> (the relay dist) to be available.

=head1 DEPENDENCIES

Requires L<Moo>, L<JSON>, L<Overnet::Burner::Adversary::Corpus>,
L<Overnet::Burner::Adversary::Fuzzer>,
L<Overnet::Burner::Adversary::Driver::Scripted>,
L<Overnet::Burner::Adversary::Oracle>,
L<Overnet::Burner::Adversary::Runner>, and
L<Overnet::Burner::Adversary::Arena::Live>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
