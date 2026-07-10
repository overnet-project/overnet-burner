package Overnet::Burner::Adversary::Corpus;

use strictures 2;
use Moo;

use Carp           qw(croak);
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Spec;

use Overnet::Burner::Util qw(json_text read_json_file write_file);
use Overnet::Burner::Adversary::Arena::Live;
use Overnet::Burner::Adversary::Driver::Scripted;
use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Runner;

our $VERSION = '0.001';

has dir => (is => 'ro');

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = @args == 1 && ref($args[0]) eq 'HASH' ? %{$args[0]} : @args;

  return {dir => (defined $args{dir} ? $args{dir} : _default_dir())};
}

# Load every corpus entry from disk, validated and ordered by name so a run is
# reproducible. Each entry is an attack that MUST remain defended.
sub entries {
  my ($self) = @_;

  my @entries;
  if (-d $self->dir) {
    for my $path (sort glob File::Spec->catfile($self->dir, '*.json')) {
      my $entry = read_json_file($path);
      _validate_entry($entry, $path);
      push @entries, $entry;
    }
  }

  my @ordered = sort { $a->{name} cmp $b->{name} } @entries;
  return \@ordered;
}

# Replay one entry against the live relay and return the oracle's verdict. A
# corpus entry passes when the verdict is not violated: the attack it encodes is
# still defended. A regression that reopens the hole flips the verdict.
sub replay {
  my ($self, $entry) = @_;

  _validate_entry($entry, 'entry');
  my $seed  = defined $entry->{seed} ? $entry->{seed} : '1';
  my $arena = Overnet::Burner::Adversary::Arena::Live->new(
    snapshot_signers => $entry->{snapshot_signers} || [],
    seed             => $seed,
  );

  my $result = Overnet::Burner::Adversary::Runner->new->run(
    driver       => Overnet::Burner::Adversary::Driver::Scripted->new(actions => $entry->{actions}),
    arena        => $arena,
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => (ref $entry->{ground_truth} eq 'HASH' ? $entry->{ground_truth} : {}),
    session_id   => "corpus-$entry->{name}",
    seed         => $seed,
  );

  return $result->{verdict};
}

# Grow the corpus: persist a new entry so it is replayed on every future run.
# This is how a newly discovered attack (from the fuzzer, the adaptive driver,
# or by hand) becomes a permanent regression guard.
sub add {
  my ($self, $entry) = @_;

  _validate_entry($entry, 'entry');
  if (!-d $self->dir) {
    make_path($self->dir);
  }

  my $path = File::Spec->catfile($self->dir, "$entry->{name}.json");
  write_file($path, json_text(_canonical_entry($entry)));
  return $path;
}

sub _canonical_entry {
  my ($entry) = @_;

  my %persisted = (
    name             => $entry->{name},
    description      => (defined $entry->{description}      ? $entry->{description}      : q{}),
    target_invariant => (defined $entry->{target_invariant} ? $entry->{target_invariant} : q{}),
    seed             => (defined $entry->{seed}             ? $entry->{seed}             : '1'),
    snapshot_signers => ($entry->{snapshot_signers} || []),
    actions          => $entry->{actions},
    ground_truth     => (ref $entry->{ground_truth} eq 'HASH' ? $entry->{ground_truth} : {}),
  );
  return \%persisted;
}

sub _validate_entry {
  my ($entry, $where) = @_;

  if (ref $entry ne 'HASH') {
    croak "$where must be an object\n";
  }

  my $name = $entry->{name};
  if (!(defined $name && !ref($name) && length $name)) {
    croak "name is required\n";
  }
  if ($name !~ /\A[A-Za-z0-9_-]+\z/mxs) {
    croak "name must be a simple identifier (letters, digits, dash, underscore)\n";
  }

  if (!(ref $entry->{actions} eq 'ARRAY' && @{$entry->{actions}})) {
    croak "actions must be a non-empty array\n";
  }
  for my $action (@{$entry->{actions}}) {
    if (!(ref $action eq 'HASH' && defined $action->{type} && !ref($action->{type}) && length $action->{type})) {
      croak "each action must be an object with a type\n";
    }
  }

  return 1;
}

sub _default_dir {
  my $here = dirname(abs_path(__FILE__));
  return File::Spec->catdir($here, (File::Spec->updir) x 4, 'corpus', 'adversary');
}

1;

=head1 NAME

Overnet::Burner::Adversary::Corpus - a self-growing regression corpus of defended attacks

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $corpus = Overnet::Burner::Adversary::Corpus->new;
  for my $entry (@{$corpus->entries}) {
    my $verdict = $corpus->replay($entry);
    die "regression: $entry->{name}" if $verdict->{violated};
  }

  # Grow the corpus with a newly discovered attack.
  $corpus->add({name => 'new-attack', target_invariant => 'authorization', actions => \@actions, ground_truth => {...}});

=head1 DESCRIPTION

The corpus is the durable memory of the adversary harness. Each entry is an
attack - a list of arena actions plus the harness's independent ground truth -
that the system under test currently defends. Replaying every entry against the
live relay on each run asserts those defenses hold: a corpus entry passes when
the oracle's verdict is B<not> violated, and a regression that reopens a hole
flips the verdict and fails the run.

The corpus is I<self-growing>: when the fuzzer, the adaptive driver, or an
operator finds a new attack worth guarding, L</add> persists it so it is
replayed forever after. The seed corpus captures the core authority and
admission defenses (forged delegation grants, forged authoritative snapshots,
and ban-mask evasion).

=head1 SUBROUTINES/METHODS

=head2 new

Creates a corpus. Takes an optional C<dir> (default: the distribution's
F<corpus/adversary> directory).

=head2 entries

Returns an array reference of the corpus entries, validated and ordered by name.

=head2 replay

Replays one entry against the live relay through the runner, arena, and oracle,
and returns the oracle verdict. Takes the entry.

=head2 add

Validates an entry and writes it into the corpus directory as
F<< <name>.json >>, so it becomes a permanent regression guard. Returns the
written path.

=head1 DIAGNOSTICS

A malformed entry - a missing or path-like name, or missing actions - is
reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

Replaying entries requires C<Overnet::Authority::HostedChannel::Relay> (the
relay dist) to be available.

=head1 DEPENDENCIES

Requires L<Moo>, L<Overnet::Burner::Adversary::Runner>,
L<Overnet::Burner::Adversary::Driver::Scripted>,
L<Overnet::Burner::Adversary::Oracle>, and
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
