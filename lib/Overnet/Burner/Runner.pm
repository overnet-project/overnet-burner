package Overnet::Burner::Runner;

use strictures 2;
use Moo;

use Carp    qw(croak);
use English qw(-no_match_vars);
use File::Spec;
use JSON ();

use Overnet::Burner::Util qw(json_text write_file);

our $VERSION = '0.001';

has name => (is => 'ro',);
has ledger => (
  is     => 'ro',
  reader => '_ledger',
);
has plan => (
  is     => 'ro',
  reader => '_plan',
);
has run_dir => (
  is     => 'ro',
  reader => '_run_dir',
);

no Moo;

my %RUNNER_MODULE = (
  noop                 => 'Overnet::Burner::Runner::Noop',
  'rex-local'          => 'Overnet::Burner::Runner::RexLocal',
  'rex-local-provider' => 'Overnet::Burner::Runner::RexLocalProvider',
);

sub load {
  my ($class, %args) = @_;

  my $name   = $args{name} || croak "runner name is required\n";
  my $module = $RUNNER_MODULE{$name}
    or croak "unknown runner: $name\n";

  my $loaded = eval {
    (my $path = "$module.pm") =~ s{::}{/}gmxs;
    require $path;
    1;
  };
  if (!$loaded) {
    croak $EVAL_ERROR;
  }

  return $module->new(%args);
}

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = _constructor_args_hash(@args);

  my $name    = $args{name}    || croak "runner name is required\n";
  my $ledger  = $args{ledger}  || croak "ledger is required\n";
  my $plan    = $args{plan}    || croak "plan is required\n";
  my $run_dir = $args{run_dir} || croak "run_dir is required\n";

  return {
    name    => $name,
    ledger  => $ledger,
    plan    => $plan,
    run_dir => $run_dir,
  };
}

sub _constructor_args_hash {
  my (@args) = @_;
  return %{$args[0]} if @args == 1 && ref($args[0]) eq 'HASH';
  return @args       if @args % 2 == 0;
  die "constructor arguments must be a hash or hash reference\n";
}

sub run_lifecycle {
  my ($self) = @_;

  my %phases;
  my $actor_counts = $self->actor_counts;

  for my $phase ($self->lifecycle_phases) {
    $self->{ledger}->append_runner_event(
      {
        runner       => $self->name,
        phase        => $phase,
        status       => 'started',
        actor_counts => $actor_counts,
      }
    );

    my $ok = eval {
      $self->$phase();
      1;
    };
    if (!$ok) {
      my $error = $EVAL_ERROR || 'runner phase failed';
      chomp $error;
      $phases{$phase} = 'failed';
      $self->{ledger}->append_runner_event(
        {
          runner       => $self->name,
          phase        => $phase,
          status       => 'failed',
          actor_counts => $actor_counts,
          error        => $error,
        }
      );
      my $cleanup_ok = eval {
        $self->cleanup_after_lifecycle_failure(
          failed_phase => $phase,
          error        => $error,
          phases       => \%phases,
          actor_counts => $actor_counts,
        );
        1;
      };
      if (!$cleanup_ok) {
        my $cleanup_error = $EVAL_ERROR || 'runner cleanup failed';
        chomp $cleanup_error;
        $error = "$error; cleanup failed: $cleanup_error";
      }
      croak "$error\n";
    }

    $phases{$phase} = 'completed';
    $self->{ledger}->append_runner_event(
      {
        runner       => $self->name,
        phase        => $phase,
        status       => 'completed',
        actor_counts => $actor_counts,
      }
    );
  }

  my %summary_fields = $self->summary_fields;
  my $summary        = {
    runner       => $self->name,
    phases       => \%phases,
    actor_counts => $actor_counts,
    %summary_fields,
  };
  $self->write_summary_artifact($summary);

  return $summary;
}

sub lifecycle_phases {
  return qw(prepare start observe stop collect);
}

sub actor_counts {
  my ($self) = @_;
  my $plan   = $self->{plan};
  my @roles  = qw(relays publishers subscribers query_readers object_readers);

  my $counts = {map { $_ => scalar @{$plan->{$_} || []} } @roles,};
  $counts->{total} = 0;
  for my $role (@roles) {
    $counts->{total} += $counts->{$role};
  }

  return $counts;
}

sub summary_fields {
  return ();
}

sub cleanup_after_lifecycle_failure {
  return 1;
}

sub write_summary_artifact {
  my ($self, $summary) = @_;

  my $path = File::Spec->catfile($self->{run_dir}, 'artifacts', "$self->{name}-runner.json",);
  write_file($path, json_text($summary));

  return 1;
}

1;

=head1 NAME

Overnet::Burner::Runner - base runner lifecycle

=head1 DESCRIPTION

Loads runner implementations and executes the standard overnet-burner lifecycle.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(%args);

=head1 SUBROUTINES/METHODS

=head2 load

=head2 new

=head2 name

=head2 run_lifecycle

=head2 lifecycle_phases

=head2 actor_counts

=head2 summary_fields

=head2 cleanup_after_lifecycle_failure

=head2 write_summary_artifact

=head1 DIAGNOSTICS

Runner loading and lifecycle failures are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Runner configuration is supplied through constructor arguments.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
