package Overnet::Burner::Runner::RexLocalProvider;

use strictures 2;

use parent 'Overnet::Burner::Runner::RexLocal';

use File::Path qw(make_path);
use File::Spec;
use JSON ();

sub prepare {
    my ($self) = @_;

    $self->SUPER::prepare;
    $self->{topology_provider_commands} = [];
    $self->{topology_provider_started} = {};
    $self->{topology_provider_needs_stop} = 0;
    $self->{topology_provider_stop_attempted} = 0;

    return 1;
}

sub start {
    my ($self) = @_;

    $self->_run_topology_provider_start;
    $self->SUPER::start;

    return 1;
}

sub stop {
    my ($self) = @_;

    return 1 if $self->{topology_provider_stop_attempted};
    return 1 unless $self->{topology_provider_needs_stop};

    $self->{topology_provider_stop_attempted} = 1;

    for my $relay ($self->_topology_provider_command_relays) {
        my $actor_id = $relay->{actor_id} || next;
        next unless $self->{topology_provider_started}{$actor_id};

        $self->_run_topology_provider_command(
            actor_id => $actor_id,
            kind     => 'stop',
            command  => $relay->{lifecycle}{stop}{command},
        );
    }

    $self->{topology_provider_needs_stop} = 0;

    return 1;
}

sub summary_fields {
    my ($self) = @_;

    return (
        $self->SUPER::summary_fields,
        topology_provider_commands => $self->{topology_provider_commands} || [],
    );
}

sub cleanup_after_lifecycle_failure {
    my ($self, %args) = @_;

    return 1 if ($args{failed_phase} || '') eq 'stop';
    return 1 unless $self->{topology_provider_needs_stop};
    return 1 if $self->{topology_provider_stop_attempted};

    my $actor_counts = $args{actor_counts} || $self->actor_counts;
    $self->{ledger}->append_runner_event({
        runner       => $self->name,
        phase        => 'stop',
        status       => 'started',
        actor_counts => $actor_counts,
    });

    my $ok = eval {
        $self->stop;
        1;
    };
    if (!$ok) {
        my $error = $@ || 'runner stop cleanup failed';
        chomp $error;
        $args{phases}{stop} = 'failed' if ref $args{phases} eq 'HASH';
        $self->{ledger}->append_runner_event({
            runner       => $self->name,
            phase        => 'stop',
            status       => 'failed',
            actor_counts => $actor_counts,
            error        => $error,
        });
        die "$error\n";
    }

    $args{phases}{stop} = 'completed' if ref $args{phases} eq 'HASH';
    $self->{ledger}->append_runner_event({
        runner       => $self->name,
        phase        => 'stop',
        status       => 'completed',
        actor_counts => $actor_counts,
    });

    return 1;
}

sub _run_topology_provider_start {
    my ($self) = @_;

    for my $relay ($self->_topology_provider_command_relays) {
        my $actor_id = $relay->{actor_id} || next;

        $self->_run_topology_provider_command(
            actor_id => $actor_id,
            kind     => 'start',
            command  => $relay->{lifecycle}{start}{command},
        );
        $self->{topology_provider_started}{$actor_id} = 1;
        $self->{topology_provider_needs_stop} = 1;

        $self->_run_topology_provider_command(
            actor_id => $actor_id,
            kind     => 'health',
            command  => $relay->{lifecycle}{health}{command},
        );
    }

    return 1;
}

sub _topology_provider_command_relays {
    my ($self) = @_;

    my $bundle = $self->_rex_bundle;
    my $path = File::Spec->catfile(
        $self->{run_dir},
        $bundle->{path},
        'topology-provider.json',
    );
    my $topology_provider = _read_json($path);

    return grep {
        ref $_->{lifecycle} eq 'HASH'
            && ref $_->{lifecycle}{start} eq 'HASH'
            && ref $_->{lifecycle}{health} eq 'HASH'
            && ref $_->{lifecycle}{stop} eq 'HASH'
    } @{ $topology_provider->{relays} || [] };
}

sub _run_topology_provider_command {
    my ($self, %args) = @_;

    my $actor_id = $args{actor_id} || die "actor_id is required\n";
    my $kind = $args{kind} || die "provider command kind is required\n";
    my $command = $args{command} || die "provider command is required\n";
    my $relative_stdout = File::Spec->catfile(
        'logs',
        'provider',
        "$actor_id-$kind.stdout",
    );
    my $relative_stderr = File::Spec->catfile(
        'logs',
        'provider',
        "$actor_id-$kind.stderr",
    );
    my $provider_log_dir = File::Spec->catdir(
        $self->{run_dir},
        'logs',
        'provider',
    );

    make_path($provider_log_dir) unless -d $provider_log_dir;

    my %record = (
        actor_id     => $actor_id,
        command_kind => $kind,
        command      => $command,
        stdout_path  => $relative_stdout,
        stderr_path  => $relative_stderr,
    );

    $self->_record_topology_provider_event(%record, status => 'started');

    my $status = _capture_shell_command(
        cwd         => File::Spec->rel2abs($self->{run_dir}),
        command     => $command,
        stdout_path => File::Spec->rel2abs(
            File::Spec->catfile($self->{run_dir}, $relative_stdout),
        ),
        stderr_path => File::Spec->rel2abs(
            File::Spec->catfile($self->{run_dir}, $relative_stderr),
        ),
    );
    my $exit_code = ($status & 127) ? undef : ($status >> 8);
    my $result_status = defined $exit_code && $exit_code == 0
        ? 'completed'
        : 'failed';
    my %result = (
        %record,
        status => $result_status,
        defined $exit_code ? (exit_code => $exit_code) : (),
    );

    push @{ $self->{topology_provider_commands} }, \%result;
    $self->_record_topology_provider_event(%result);

    return 1 if $result_status eq 'completed';

    my $detail = defined $exit_code
        ? "exited with status $exit_code"
        : "ended by signal " . ($status & 127);
    die "provider command failed: $actor_id $kind $detail\n";
}

sub _record_topology_provider_event {
    my ($self, %args) = @_;

    $self->{ledger}->append_runner_event({
        runner       => $self->name,
        phase        => $args{command_kind} eq 'stop' ? 'stop' : 'start',
        actor_id     => $args{actor_id},
        command_kind => $args{command_kind},
        status       => $args{status},
        stdout_path  => $args{stdout_path},
        stderr_path  => $args{stderr_path},
        command      => $args{command},
        exists $args{exit_code} ? (exit_code => $args{exit_code}) : (),
    });

    return 1;
}

sub _capture_shell_command {
    my (%args) = @_;

    my $cwd = $args{cwd} || die "cwd is required\n";
    my $command = $args{command} || die "command is required\n";
    my $stdout_path = $args{stdout_path} || die "stdout_path is required\n";
    my $stderr_path = $args{stderr_path} || die "stderr_path is required\n";

    my $pid = fork;
    die "fork provider command: $!\n" unless defined $pid;

    if ($pid == 0) {
        chdir $cwd or do {
            print STDERR "chdir $cwd: $!\n";
            exit 127;
        };
        open STDOUT, '>', $stdout_path or do {
            print STDERR "open $stdout_path: $!\n";
            exit 127;
        };
        open STDERR, '>', $stderr_path or do {
            print STDERR "open $stderr_path: $!\n";
            exit 127;
        };
        if (!exec '/bin/sh', '-c', $command) {
            print STDERR "exec /bin/sh: $!\n";
            exit 127;
        }
    }

    waitpid($pid, 0) == $pid or die "wait provider command: $!\n";
    return $?;
}

sub _read_json {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return JSON::decode_json(<$fh>);
}

1;
