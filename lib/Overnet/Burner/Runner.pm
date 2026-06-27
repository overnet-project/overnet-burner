package Overnet::Burner::Runner;

use strict;
use warnings;

use File::Spec;
use JSON::PP;

my %RUNNER_MODULE = (
    noop => 'Overnet::Burner::Runner::Noop',
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

    my $summary = {
        runner       => $self->name,
        phases       => \%phases,
        actor_counts => $actor_counts,
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

sub write_summary_artifact {
    my ($self, $summary) = @_;

    my $path = File::Spec->catfile(
        $self->{run_dir},
        'artifacts',
        "$self->{name}-runner.json",
    );

    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} JSON::PP->new->canonical(1)->pretty(1)->space_before(0)
        ->encode($summary);
    close $fh or die "close $path: $!";

    return 1;
}

1;
