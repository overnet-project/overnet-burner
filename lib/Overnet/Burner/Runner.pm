package Overnet::Burner::Runner;

use strictures 2;

use File::Spec;
use JSON ();

my %RUNNER_MODULE = (
    noop                 => 'Overnet::Burner::Runner::Noop',
    'rex-local'          => 'Overnet::Burner::Runner::RexLocal',
    'rex-local-provider' => 'Overnet::Burner::Runner::RexLocalProvider',
);

sub load {
    my ($class, %args) = @_;

    my $name = $args{name} || die "runner name is required\n";
    my $module = $RUNNER_MODULE{$name}
        or die "unknown runner: $name\n";

    eval "require $module; 1" or die $@;

    return $module->new(%args);
}

sub new {
    my ($class, %args) = @_;

    my $name = $args{name} || die "runner name is required\n";
    my $ledger = $args{ledger} || die "ledger is required\n";
    my $plan = $args{plan} || die "plan is required\n";
    my $run_dir = $args{run_dir} || die "run_dir is required\n";

    my $self = bless {
        name    => $name,
        ledger  => $ledger,
        plan    => $plan,
        run_dir => $run_dir,
    }, $class;

    return $self;
}

sub name {
    my ($self) = @_;
    return $self->{name};
}

sub run_lifecycle {
    my ($self) = @_;

    my %phases;
    my $actor_counts = $self->actor_counts;

    for my $phase ($self->lifecycle_phases) {
        $self->{ledger}->append_runner_event({
            runner       => $self->name,
            phase        => $phase,
            status       => 'started',
            actor_counts => $actor_counts,
        });

        my $ok = eval {
            $self->$phase();
            1;
        };
        if (!$ok) {
            my $error = $@ || 'runner phase failed';
            chomp $error;
            $phases{$phase} = 'failed';
            $self->{ledger}->append_runner_event({
                runner       => $self->name,
                phase        => $phase,
                status       => 'failed',
                actor_counts => $actor_counts,
                error        => $error,
            });
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
                my $cleanup_error = $@ || 'runner cleanup failed';
                chomp $cleanup_error;
                $error = "$error; cleanup failed: $cleanup_error";
            }
            die "$error\n";
        }

        $phases{$phase} = 'completed';
        $self->{ledger}->append_runner_event({
            runner       => $self->name,
            phase        => $phase,
            status       => 'completed',
            actor_counts => $actor_counts,
        });
    }

    my %summary_fields = $self->summary_fields;
    my $summary = {
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
    my $plan = $self->{plan};
    my @roles = qw(relays publishers subscribers query_readers object_readers);

    my $counts = {
        map { $_ => scalar @{ $plan->{$_} || [] } } @roles,
    };
    $counts->{total} = 0;
    $counts->{total} += $counts->{$_} for @roles;

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

    my $path = File::Spec->catfile(
        $self->{run_dir},
        'artifacts',
        "$self->{name}-runner.json",
    );

    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} JSON->new->canonical(1)->pretty(1)->space_before(0)
        ->encode($summary);
    close $fh or die "close $path: $!";

    return 1;
}

1;
