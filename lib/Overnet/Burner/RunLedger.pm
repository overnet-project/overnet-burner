package Overnet::Burner::RunLedger;

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;
use POSIX qw(strftime uname);
use Sys::Hostname qw(hostname);

use Overnet::Burner::Config;
use Overnet::Burner::Plan;

sub create {
    my ($class, %args) = @_;

    my $scenario = $args{scenario} || die "scenario is required\n";
    my $scenario_path = $args{scenario_path} || die "scenario_path is required\n";
    my $runs_dir = $args{runs_dir} || 'runs';
    my $run_id = defined $args{run_id} ? $args{run_id} : _default_run_id();
    _validate_run_id($run_id);
    my $run_dir = File::Spec->catdir($runs_dir, $run_id);
    my $now = $args{now} || \&_iso_now;

    die "run already exists: $run_dir\n" if -e $run_dir;

    Overnet::Burner::Config->validate($scenario);
    my $normalized_json = Overnet::Burner::Config->normalized_json($scenario);
    my $plan_json = Overnet::Burner::Plan->canonical_json(
        Overnet::Burner::Plan->build($scenario),
    );

    make_path($runs_dir) unless -d $runs_dir;
    mkdir $run_dir or die "mkdir $run_dir: $!";
    mkdir File::Spec->catdir($run_dir, 'logs')
        or die "mkdir $run_dir/logs: $!";
    mkdir File::Spec->catdir($run_dir, 'artifacts')
        or die "mkdir $run_dir/artifacts: $!";

    copy($scenario_path, File::Spec->catfile($run_dir, 'scenario.yml'))
        or die "copy $scenario_path: $!";

    _write_file(
        File::Spec->catfile($run_dir, 'config.normalized.json'),
        $normalized_json,
    );
    _write_file(
        File::Spec->catfile($run_dir, 'plan.json'),
        $plan_json,
    );

    _write_file(File::Spec->catfile($run_dir, 'metrics.jsonl'), '');

    my $topology_provider_name = $scenario->{topology}{relays}{provider};
    my $runner_name = exists $args{runner_name}
        ? $args{runner_name}
        : undef;
    my $manifest = {
        run_id     => $run_id,
        timestamps => {
            created_at => $now->(),
        },
        seed     => $scenario->{run}{seed},
        scenario => {
            name => $scenario->{run}{name},
        },
        topology_provider => {
            name => $topology_provider_name,
        },
        runner => {
            name => $runner_name,
        },
        host_facts   => $args{host_facts}   || _host_facts(),
        repo_sha     => exists $args{repo_sha} ? $args{repo_sha} : _repo_sha($scenario_path),
        perl_version => sprintf('%vd', $^V),
        rex_version  => exists $args{rex_version}
            ? $args{rex_version}
            : _rex_version(),
    };

    _write_file(
        File::Spec->catfile($run_dir, 'manifest.json'),
        JSON::PP->new->canonical(1)->pretty(1)->space_before(0)->encode($manifest),
    );

    return bless {
        run_id  => $run_id,
        run_dir => $run_dir,
        now     => $now,
    }, $class;
}

sub load_plan {
    my ($class, $run_dir) = @_;

    return _read_json_file(File::Spec->catfile($run_dir, 'plan.json'));
}

sub mark_started {
    my ($self, %args) = @_;

    my $manifest = $self->_read_manifest;
    $manifest->{status} = 'running';
    $manifest->{timestamps}{started_at} = $self->{now}->();
    _set_runner($manifest, $args{runner}) if exists $args{runner};
    $self->_write_manifest($manifest);

    return 1;
}

sub finish {
    my ($self, %args) = @_;

    my $status = $args{status} || die "status is required\n";
    my $manifest = $self->_read_manifest;

    $manifest->{status} = $status;
    $manifest->{timestamps}{finished_at} = $self->{now}->();
    _set_runner($manifest, $args{runner}) if exists $args{runner};

    if (exists $args{lifecycle}) {
        $manifest->{lifecycle} = $args{lifecycle};
    }
    if (exists $args{error}) {
        $manifest->{error} = $args{error};
    }
    else {
        delete $manifest->{error};
    }

    $self->_write_manifest($manifest);

    return 1;
}

sub append_runner_event {
    my ($self, $event) = @_;

    die "event is required\n" unless ref $event eq 'HASH';

    my %record = (
        %{$event},
        timestamp => exists $event->{timestamp}
            ? $event->{timestamp}
            : $self->{now}->(),
    );
    my $path = File::Spec->catfile($self->{run_dir}, 'logs', 'runner.jsonl');

    open my $fh, '>>', $path or die "open $path: $!";
    print {$fh} JSON::PP->new->canonical(1)->encode(\%record), "\n";
    close $fh or die "close $path: $!";

    return 1;
}

sub _set_runner {
    my ($manifest, $name) = @_;

    $manifest->{runner} ||= {};
    $manifest->{runner}{name} = $name;
}

sub _write_file {
    my ($path, $content) = @_;

    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} $content;
    close $fh or die "close $path: $!";
}

sub _read_manifest {
    my ($self) = @_;

    return _read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
}

sub _write_manifest {
    my ($self, $manifest) = @_;

    _write_file(
        File::Spec->catfile($self->{run_dir}, 'manifest.json'),
        JSON::PP->new->canonical(1)->pretty(1)->space_before(0)
            ->encode($manifest),
    );
}

sub _read_json_file {
    my ($path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    return JSON::PP->new->decode(<$fh>);
}

sub _default_run_id {
    return strftime('%Y%m%dT%H%M%SZ', gmtime) . "-$$";
}

sub _validate_run_id {
    my ($run_id) = @_;

    die "invalid run_id: use ASCII letters, digits, underscore, dot, or dash\n"
        unless defined $run_id
        && !ref $run_id
        && $run_id =~ /\A[A-Za-z0-9_.-]+\z/
        && $run_id ne '.'
        && $run_id ne '..';

    return 1;
}

sub _iso_now {
    return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
}

sub _host_facts {
    my @uname = uname();

    return {
        hostname => hostname(),
        os       => $uname[0],
        release  => $uname[2],
        arch     => $uname[4],
    };
}

sub _repo_sha {
    my ($scenario_path) = @_;
    my $git_dir = dirname($scenario_path || getcwd());

    open my $err, '>', File::Spec->devnull or return undef;
    local *STDERR = $err;

    open my $fh, '-|', 'git', '-C', $git_dir, 'rev-parse', '--verify', 'HEAD'
        or return undef;
    my $sha = <$fh>;
    close $fh or return undef;
    return undef unless defined $sha;
    chomp $sha;
    return length($sha) ? $sha : undef;
}

sub _rex_version {
    my $version = eval {
        require Rex;
        return $Rex::VERSION;
    };

    return $version;
}

1;
