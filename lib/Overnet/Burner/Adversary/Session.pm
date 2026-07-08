package Overnet::Burner::Adversary::Session;

use strictures 2;
use Moo;

use Carp qw(croak);
use JSON ();

our $VERSION = '0.001';

my $JSON = JSON->new->utf8->canonical;

my $RECORD_VERSION = '1';
my %STEP_KIND      = map { $_ => 1 } qw(meta action observation);

has session_id         => (is => 'ro');
has seed               => (is => 'ro');
has arena_baseline_ref => (is => 'ro');
has _steps             => (is => 'lazy', init_arg => undef);

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = _constructor_args_hash(@args);

  for my $field (qw(session_id seed arena_baseline_ref)) {
    if (!(defined $args{$field} && !ref($args{$field}) && length $args{$field})) {
      croak "$field is required\n";
    }
  }

  return {
    session_id         => $args{session_id},
    seed               => $args{seed},
    arena_baseline_ref => $args{arena_baseline_ref},
  };
}

# A fresh session opens with a single session_open meta record carrying the
# seed and arena baseline; from_jsonl replaces the step list wholesale.
sub _build__steps {
  my ($self) = @_;
  return [
    {
      record_version => $RECORD_VERSION,
      session_id     => $self->session_id,
      seq            => 0,
      kind           => 'meta',
      type           => 'session_open',
      payload        => {
        seed               => $self->seed,
        arena_baseline_ref => $self->arena_baseline_ref,
      },
    },
  ];
}

sub _constructor_args_hash {
  my (@args) = @_;
  return %{$args[0]} if @args == 1 && ref($args[0]) eq 'HASH';
  return @args       if @args % 2 == 0;
  croak "constructor arguments must be a hash or hash reference\n";
}

sub append_action {
  my ($self, %args) = @_;
  return $self->_append('action', $args{type}, $args{payload});
}

sub append_observation {
  my ($self, %args) = @_;
  return $self->_append('observation', $args{type}, $args{payload});
}

sub _append {
  my ($self, $kind, $type, $payload) = @_;
  if (!(defined $type && !ref($type) && length $type)) {
    croak "step type is required\n";
  }
  if (defined $payload && ref($payload) ne 'HASH') {
    croak "step payload must be an object\n";
  }

  my $steps = $self->_steps;
  my $rec   = {
    record_version => $RECORD_VERSION,
    session_id     => $self->session_id,
    seq            => scalar @{$steps},
    kind           => $kind,
    type           => $type,
    payload        => $payload || {},
  };

  my ($ok, $error) = _record_rule_violation($rec);
  if (!$ok) {
    croak "refusing to append an invalid session record: $error\n";
  }

  push @{$steps}, $rec;
  return $rec;
}

sub steps {
  my ($self) = @_;
  return [map { _copy_record($_) } @{$self->_steps}];
}

sub steps_of_kind {
  my ($self, $kind) = @_;
  return [map { _copy_record($_) } grep { $_->{kind} eq $kind } @{$self->_steps}];
}

sub _copy_record {
  my ($rec) = @_;
  return {%{$rec}};
}

sub to_jsonl {
  my ($self) = @_;
  return join q{}, map { $JSON->encode($_) . "\n" } @{$self->_steps};
}

sub from_jsonl {
  my ($class, $text) = @_;
  if (!(defined $text && !ref($text))) {
    croak "session JSONL text is required\n";
  }

  my @records;
  for my $line (split /\n/mxs, $text) {
    if (!length $line) {
      next;
    }
    my $rec = $JSON->decode($line);
    my ($ok, $error) = _record_rule_violation($rec);
    if (!$ok) {
      croak "invalid session record: $error\n";
    }
    push @records, $rec;
  }

  my $meta = $records[0];
  if (!(ref($meta) eq 'HASH' && $meta->{kind} eq 'meta' && $meta->{type} eq 'session_open')) {
    croak "session JSONL must begin with a session_open meta record\n";
  }

  my $self = $class->new(
    session_id         => $meta->{session_id},
    seed               => $meta->{payload}{seed},
    arena_baseline_ref => $meta->{payload}{arena_baseline_ref},
  );

  _assert_contiguous_seq(\@records);
  $self->{_steps} = [@records];
  return $self;
}

sub validate_record {
  my ($class, $rec) = @_;
  return _record_rule_violation($rec);
}

sub _record_rule_violation {
  my ($rec) = @_;
  if (ref($rec) ne 'HASH') {
    return (0, 'record must be an object');
  }
  if (!(defined $rec->{record_version} && $rec->{record_version} eq $RECORD_VERSION)) {
    return (0, "record_version must be $RECORD_VERSION");
  }
  for my $field (qw(session_id type)) {
    if (!(defined $rec->{$field} && !ref($rec->{$field}) && length $rec->{$field})) {
      return (0, "$field is required");
    }
  }

  # Validate seq against a lexical copy: matching the stored value directly
  # would cache a string form on it, producing a dualvar that some JSON
  # backends then serialize as a string, breaking byte-stable round-trips.
  my $seq = $rec->{seq};
  if (!(defined $seq && !ref($seq) && $seq =~ /\A\d+\z/mxs)) {
    return (0, 'seq must be a non-negative integer');
  }
  if (!(defined $rec->{kind} && $STEP_KIND{$rec->{kind}})) {
    return (0, 'kind must be meta, action, or observation');
  }
  if (ref($rec->{payload}) ne 'HASH') {
    return (0, 'payload must be an object');
  }
  return (1, undef);
}

sub _assert_contiguous_seq {
  my ($records) = @_;
  my $expected = 0;
  for my $rec (@{$records}) {
    if ($rec->{seq} != $expected) {
      croak "session records must have contiguous seq starting at 0\n";
    }
    $expected++;
  }
  return;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Session - append-only replayable adversary session log

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $session = Overnet::Burner::Adversary::Session->new(
    session_id         => 'sess-1',
    seed               => '42',
    arena_baseline_ref => 'baseline-abc',
  );
  $session->append_action(type => 'publish_control', payload => {...});
  $session->append_observation(type => 'observed_capability', payload => {...});
  my $jsonl = $session->to_jsonl;
  my $replay = Overnet::Burner::Adversary::Session->from_jsonl($jsonl);

=head1 DESCRIPTION

A session is the durable, replayable artifact of one adversary episode: an
append-only, seq-ordered log of steps. The first step is always a
C<session_open> meta record carrying the seed and the arena baseline
reference. Actions record what a driver attempted; observations record what
the system under test exposed in response.

Records carry no wall-clock timestamps: ordering is by C<seq> alone, so a log
replays deterministically. Records conform to the
C<adversary-session-v1> contract.

=head1 SUBROUTINES/METHODS

=head2 new

Creates a session and appends the opening meta record. Requires
C<session_id>, C<seed>, and C<arena_baseline_ref>.

=head2 append_action

Appends an action step. Takes C<type> and optional C<payload>.

=head2 append_observation

Appends an observation step. Takes C<type> and optional C<payload>.

=head2 steps

Returns a deep copy of all step records.

=head2 steps_of_kind

Returns a deep copy of step records of one kind (C<meta>, C<action>, or
C<observation>).

=head2 to_jsonl

Serializes the session to JSONL, one record per line.

=head2 from_jsonl

Reconstructs a session from JSONL text. Class method.

=head2 validate_record

Validates one record against the contract rules. Returns C<(1, undef)> or
C<(0, $reason)>. Class method.

=head1 DIAGNOSTICS

Invalid constructor arguments, invalid records, and malformed JSONL are
reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Moo> and L<JSON>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
