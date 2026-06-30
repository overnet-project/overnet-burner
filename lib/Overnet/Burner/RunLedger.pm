package Overnet::Burner::RunLedger;

use strictures 2;

use Carp           qw(croak);
use Cwd            qw(getcwd);
use English        qw(-no_match_vars);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use File::Path     qw(make_path);
use File::Spec;
use IPC::Open3    qw(open3);
use JSON          ();
use POSIX         qw(strftime uname);
use Symbol        qw(gensym);
use Sys::Hostname qw(hostname);

use Overnet::Burner::Config;
use Overnet::Burner::Plan;
use Overnet::Burner::Util qw(json_text read_json_file write_file checked_close);

our $VERSION = '0.001';

sub create {
  my ($class, %args) = @_;

  my $scenario      = $args{scenario}      || croak "scenario is required\n";
  my $scenario_path = $args{scenario_path} || croak "scenario_path is required\n";
  my $runs_dir      = $args{runs_dir}      || 'runs';
  my $run_id        = defined $args{run_id} ? $args{run_id} : _default_run_id();
  _validate_run_id($run_id);
  my $run_dir = File::Spec->catdir($runs_dir, $run_id);
  my $now     = $args{now} || \&_iso_now;

  if (-e $run_dir) {
    croak "run already exists: $run_dir\n";
  }

  Overnet::Burner::Config->validate($scenario);
  my $normalized_json = Overnet::Burner::Config->normalized_json($scenario);
  my $plan_json       = Overnet::Burner::Plan->canonical_json(Overnet::Burner::Plan->build($scenario),);

  if (!-d $runs_dir) {
    make_path($runs_dir);
  }
  mkdir $run_dir
    or croak "mkdir $run_dir: $OS_ERROR\n";
  mkdir File::Spec->catdir($run_dir, 'logs')
    or croak "mkdir $run_dir/logs: $OS_ERROR\n";
  mkdir File::Spec->catdir($run_dir, 'artifacts')
    or croak "mkdir $run_dir/artifacts: $OS_ERROR\n";

  copy($scenario_path, File::Spec->catfile($run_dir, 'scenario.yml'))
    or croak "copy $scenario_path: $OS_ERROR\n";

  write_file(File::Spec->catfile($run_dir, 'config.normalized.json'), $normalized_json,);
  write_file(File::Spec->catfile($run_dir, 'plan.json'),              $plan_json,);

  write_file(File::Spec->catfile($run_dir, 'metrics.jsonl'), q{});

  my $topology_provider_name = $scenario->{topology}{relays}{provider};
  my $runner_name =
    exists $args{runner_name}
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
    host_facts   => $args{host_facts} || _host_facts(),
    repo_sha     => exists $args{repo_sha} ? $args{repo_sha} : _repo_sha($scenario_path),
    perl_version => sprintf('%vd', $PERL_VERSION),
    rex_version  => exists $args{rex_version}
    ? $args{rex_version}
    : _rex_version(),
  };

  write_file(File::Spec->catfile($run_dir, 'manifest.json'), json_text($manifest),);

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
  if (exists $args{runner}) {
    _set_runner($manifest, $args{runner});
  }
  $self->_write_manifest($manifest);

  return 1;
}

sub finish {
  my ($self, %args) = @_;

  my $status   = $args{status} || croak "status is required\n";
  my $manifest = $self->_read_manifest;

  $manifest->{status} = $status;
  $manifest->{timestamps}{finished_at} = $self->{now}->();
  if (exists $args{runner}) {
    _set_runner($manifest, $args{runner});
  }

  if (exists $args{lifecycle}) {
    $manifest->{lifecycle} = $args{lifecycle};
  }
  if (exists $args{error}) {
    $manifest->{error} = $args{error};
  } else {
    delete $manifest->{error};
  }

  $self->_write_manifest($manifest);

  return 1;
}

sub append_runner_event {
  my ($self, $event) = @_;

  if (ref $event ne 'HASH') {
    croak "event is required\n";
  }

  my %entry = (
    %{$event}, timestamp => exists $event->{timestamp}
    ? $event->{timestamp}
    : $self->{now}->(),
  );
  my $path = File::Spec->catfile($self->{run_dir}, 'logs', 'runner.jsonl');

  open my $fh, '>>', $path
    or croak "open $path: $OS_ERROR\n";
  print {$fh} JSON->new->canonical(1)->encode(\%entry), "\n"
    or croak "print $path: $OS_ERROR\n";
  checked_close($fh, $path);

  return 1;
}

sub record_rex_bundle {
  my ($self, %args) = @_;

  my $relative_dir = $args{relative_dir} || croak "relative_dir is required\n";
  my $files        = $args{files}        || croak "files is required\n";
  my $manifest     = $self->_read_manifest;

  $manifest->{rex_bundle} = {
    path             => $relative_dir,
    rendered         => 1,
    rendered_at      => $self->{now}->(),
    remote_execution => 'not_performed',
    files            => $files,
  };

  $self->_write_manifest($manifest);

  return 1;
}

sub _set_runner {
  my ($manifest, $name) = @_;

  $manifest->{runner} ||= {};
  $manifest->{runner}{name} = $name;
  return;
}

sub _read_manifest {
  my ($self) = @_;

  return read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
}

sub _write_manifest {
  my ($self, $manifest) = @_;

  write_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'), json_text($manifest),);
  return;
}

sub _read_json_file {
  my ($path) = @_;

  return read_json_file($path);
}

sub _default_run_id {
  return strftime('%Y%m%dT%H%M%SZ', gmtime) . q{-} . $PROCESS_ID;
}

sub _validate_run_id {
  my ($run_id) = @_;

  if (!(defined $run_id && !ref $run_id && $run_id =~ /\A[A-Za-z0-9_.-]+\z/mxs && $run_id ne q{.} && $run_id ne q{..}))
  {
    croak "invalid run_id: use ASCII letters, digits, underscore, dot, or dash\n";
  }

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
  my $missing;

  my $stderr = gensym();
  my ($stdin, $stdout);
  my $pid = eval { open3($stdin, $stdout, $stderr, 'git', '-C', $git_dir, 'rev-parse', '--verify', 'HEAD'); };
  if (!$pid) {
    return $missing;
  }

  checked_close($stdin, 'git rev-parse stdin');
  my $sha           = <$stdout>;
  my @stderr_output = <$stderr>;
  my $stdout_ok     = close $stdout;
  my $stderr_ok     = close $stderr;
  waitpid($pid, 0);
  if (!$stdout_ok || !$stderr_ok || $CHILD_ERROR != 0 || !defined $sha) {
    return $missing;
  }
  chomp $sha;
  return length($sha) ? $sha : $missing;
}

sub _rex_version {
  my $version = eval {
    require Rex;
    $Rex::VERSION;
  };

  return $version;
}

1;

=head1 NAME

Overnet::Burner::RunLedger - run directory ledger management

=head1 DESCRIPTION

Creates run directories and records overnet-burner plan, manifest, lifecycle, and Rex bundle metadata.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $ledger = Overnet::Burner::RunLedger->create(%args);

=head1 SUBROUTINES/METHODS

=head2 create

=head2 load_plan

=head2 mark_started

=head2 finish

=head2 append_runner_event

=head2 record_rex_bundle

=head1 DIAGNOSTICS

Invalid run identifiers and failed IO operations are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

Run metadata is written under the configured runs directory.

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
