package Overnet::Burner::Runner::RexLocal;

use strict;
use warnings;

use parent 'Overnet::Burner::Runner';

use File::Spec;
use JSON::PP qw(decode_json);

use Overnet::Burner::RexBundle;

sub prepare {
    my ($self) = @_;

    my $bundle = Overnet::Burner::RexBundle->render(
        run_dir => $self->{run_dir},
        plan    => $self->{plan},
    );

    $self->{ledger}->record_rex_bundle(
        relative_dir => $bundle->{relative_dir},
        files        => $bundle->{files},
    );

    $self->{rex_bundle} = {
        path             => $bundle->{relative_dir},
        rendered         => 1,
        remote_execution => 'not_performed',
        files            => $bundle->{files},
    };
    $self->{rex_tasks} = [];

    return 1;
}

sub start {
    my ($self) = @_;

    my $bundle = $self->_rex_bundle;
    my $bundle_dir = $bundle->{path};
    my $rexfile = File::Spec->catfile($bundle_dir, 'Rexfile');
    my $absolute_run_dir = File::Spec->rel2abs($self->{run_dir});
    my $absolute_bundle_dir = File::Spec->catdir($absolute_run_dir, $bundle_dir);
    my $absolute_rexfile = File::Spec->catfile($absolute_run_dir, $rexfile);
    my $lifecycle = _read_json(
        File::Spec->catfile($absolute_bundle_dir, 'lifecycle.json'),
    );
    my $rexfile_text = _read_file($absolute_rexfile);

    for my $command (@{ $lifecycle->{commands} || [] }) {
        my $task = $command->{rex_task} || die "Rex lifecycle task is required\n";
        $self->_assert_rex_task($rexfile_text, $task, $rexfile);
        $self->_record_rex_task_event(
            task       => $task,
            status     => 'started',
            bundle_dir => $bundle_dir,
            rexfile    => $rexfile,
        );

        my $ok = eval {
            $self->_invoke_rex_task(
                task                => $task,
                absolute_bundle_dir => $absolute_bundle_dir,
                absolute_rexfile    => $absolute_rexfile,
            );
            1;
        };
        if (!$ok) {
            my $error = $@ || 'Rex task failed';
            chomp $error;
            $self->_record_rex_task_event(
                task       => $task,
                status     => 'failed',
                bundle_dir => $bundle_dir,
                rexfile    => $rexfile,
                error      => $error,
            );
            push @{ $self->{rex_tasks} }, {
                task       => $task,
                status     => 'failed',
                bundle_dir => $bundle_dir,
                rexfile    => $rexfile,
            };
            die "$error\n";
        }

        $self->_record_rex_task_event(
            task       => $task,
            status     => 'completed',
            bundle_dir => $bundle_dir,
            rexfile    => $rexfile,
        );
        push @{ $self->{rex_tasks} }, {
            task       => $task,
            status     => 'completed',
            bundle_dir => $bundle_dir,
            rexfile    => $rexfile,
        };
    }

    return 1;
}

sub observe { return 1 }
sub stop    { return 1 }
sub collect { return 1 }

sub summary_fields {
    my ($self) = @_;

    return (
        rex_bundle => $self->_rex_bundle,
        rex_tasks  => $self->{rex_tasks} || [],
    );
}

sub _record_rex_task_event {
    my ($self, %args) = @_;

    $self->{ledger}->append_runner_event({
        runner     => $self->name,
        phase      => 'start',
        rex_task   => $args{task},
        status     => $args{status},
        bundle_dir => $args{bundle_dir},
        rexfile    => $args{rexfile},
        exists $args{error} ? (error => $args{error}) : (),
    });

    return 1;
}

sub _rex_bundle {
    my ($self) = @_;

    return $self->{rex_bundle} || die "Rex bundle has not been rendered\n";
}

sub _assert_rex_task {
    my ($self, $rexfile_text, $task, $rexfile) = @_;

    die "Rex task not rendered in $rexfile: $task\n"
        unless $rexfile_text =~ /\btask\s+['"]\Q$task\E['"]/;

    return 1;
}

sub _invoke_rex_task {
    my ($self, %args) = @_;

    my $task = $args{task};
    my $absolute_rexfile = $args{absolute_rexfile};
    my $absolute_bundle_dir = $args{absolute_bundle_dir};

    $self->_capture_command(
        cwd     => $absolute_bundle_dir,
        command => [$self->_rex_command, '-f', $absolute_rexfile, $task],
    );

    return 1;
}

sub _rex_command {
    return $ENV{OVERNET_BURNER_REX} || 'rex';
}

sub _capture_command {
    my ($self, %args) = @_;

    my $cwd = $args{cwd} || die "cwd is required\n";
    my $command = $args{command} || die "command is required\n";

    my $pid = open my $fh, '-|';
    die "fork Rex command: $!\n" unless defined $pid;

    if ($pid == 0) {
        chdir $cwd or do {
            print STDERR "chdir $cwd: $!\n";
            exit 127;
        };
        open STDERR, '>&', \*STDOUT;
        if (!exec @{$command}) {
            print STDERR "exec $command->[0]: $!\n";
            exit 127;
        }
    }

    local $/;
    my $output = <$fh>;
    my $ok = close $fh;
    my $status = $?;
    return $output if $ok;

    my $exit_code = $status >> 8;
    my $error = "Rex task command failed: $command->[0] exited with status $exit_code";
    $output = '' unless defined $output;
    chomp $output;
    $error .= ": $output" if length $output;
    die "$error\n";
}

sub _read_json {
    my ($path) = @_;

    return decode_json(_read_file($path));
}

sub _read_file {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return <$fh>;
}

1;
