package Overnet::Burner::Runner::RexRemote;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Runner::RexLocalProvider';

use Carp       qw(croak);
use English    qw(-no_match_vars);
use File::Path qw(make_path);
use File::Spec;

use Overnet::Burner::Util qw(read_json_file write_file);

our $VERSION = '0.001';

no Moo;

# The runner genuinely performs the topology-provider lifecycle through real Rex
# tasks. It renders a performed bundle whose Rexfile connects to the relay's
# host (with key authentication over SSH, or the controller host locally) and
# runs each lifecycle command through Rex's own execution engine, rather than
# through the controller's guest primitive. See docs/rex-backend.md.

sub start {
  my ($self) = @_;

  # Perform the provider lifecycle via Rex. The base runner would also invoke
  # the eight generic phase tasks; a performed bundle renders only the
  # provider-command task, so those are deliberately not run here.
  $self->_run_topology_provider_start;

  return 1;
}

# Before a relay starts, deploy its declared files to the host with a real Rex
# `file` task, so the SUT's config/artifacts are in place before start.
sub _before_relay_start {
  my ($self, $relay) = @_;

  my $deploy = $relay->{deploy};
  if (!(ref $deploy eq 'HASH' && @{$deploy->{files} || []})) {
    return 1;
  }

  $self->_run_deploy(actor_id => $relay->{actor_id}, deploy => $deploy);
  return 1;
}

sub _run_deploy {
  my ($self, %args) = @_;

  my $actor_id         = $args{actor_id} || croak "actor_id is required\n";
  my $file_count       = scalar @{$args{deploy}{files} || []};
  my $log_label        = "$actor_id-deploy";
  my $relative_stdout  = File::Spec->catfile('logs', 'provider', "$log_label.stdout");
  my $relative_stderr  = File::Spec->catfile('logs', 'provider', "$log_label.stderr");
  my $provider_log_dir = File::Spec->catdir($self->{run_dir}, 'logs', 'provider');
  if (!-d $provider_log_dir) {
    make_path($provider_log_dir);
  }

  my %event_base = (
    actor_id     => $actor_id,
    command_kind => 'deploy',
    command      => "deploy $file_count file" . ($file_count == 1 ? q{} : 's'),
    stdout_path  => $relative_stdout,
    stderr_path  => $relative_stderr,
  );
  my $executor = $self->_provider_command_executor($actor_id);
  $self->_record_topology_provider_event(%event_base, guest => $executor, status => 'started');

  my $bundle              = $self->_rex_bundle;
  my $absolute_bundle_dir = File::Spec->catdir(File::Spec->rel2abs($self->{run_dir}), $bundle->{path});
  my ($output, $exit_code) = $self->_capture_rex(
    cwd     => $absolute_bundle_dir,
    command => [$self->_rex_command, '-f', File::Spec->catfile($absolute_bundle_dir, 'Rexfile'), 'deploy'],
  );
  write_file(File::Spec->rel2abs(File::Spec->catfile($self->{run_dir}, $relative_stdout)), $output // q{});
  write_file(File::Spec->rel2abs(File::Spec->catfile($self->{run_dir}, $relative_stderr)), q{});

  my $status = $exit_code == 0 ? 'completed' : 'failed';
  my %result = (%event_base, guest => $executor, status => $status, exit_code => $exit_code);
  push @{$self->{topology_provider_commands}}, \%result;
  $self->_record_topology_provider_event(%result);

  if ($status ne 'completed') {
    croak "deploy failed: $actor_id exited with status $exit_code\n";
  }

  return 1;
}

sub _render_rex_bundle {
  my ($self) = @_;

  my $inventory = $self->_relay_inventory;
  $self->{rex_inventory} = $inventory;

  return Overnet::Burner::RexBundle->render(
    run_dir   => $self->{run_dir},
    plan      => $self->{plan},
    execution => 'performed',
    inventory => $inventory,
  );
}

sub _remote_execution_mode {
  my ($self) = @_;

  my $inventory = $self->{rex_inventory} || {};
  return ($inventory->{transport} || 'local') eq 'ssh' ? 'remote' : 'local';
}

# The relay host Rex targets. A `connect`-provisioned relay is reached over SSH
# with the guest's address and key; every other provisioning keeps the relay on
# the controller host, where Rex runs the lifecycle command locally.
sub _relay_inventory {
  my ($self) = @_;

  my $config    = read_json_file(File::Spec->catfile($self->{run_dir}, 'config.normalized.json'));
  my $provision = ref $config->{provision} eq 'HASH' ? $config->{provision} : {};
  my $relays    = ref $provision->{relays} eq 'HASH' ? $provision->{relays} : {};
  my $how       = $relays->{how} || 'local';

  if ($how ne 'connect') {
    return {transport => 'local'};
  }

  my $guest = ($relays->{guests} || [])->[0];
  if (!(ref $guest eq 'HASH' && defined $guest->{address} && length $guest->{address})) {
    croak "rex-remote connect provisioning requires a relay guest with an address\n";
  }

  return {
    transport => 'ssh',
    host      => $guest->{address},
    (defined $guest->{user} ? (user => $guest->{user}) : ()),
    (defined $guest->{key}  ? (key  => $guest->{key})  : ()),
    (defined $guest->{port} ? (port => $guest->{port}) : ()),
  };
}

sub _provider_command_executor {
  my ($self) = @_;

  my $inventory = $self->{rex_inventory} || {};
  return ($inventory->{transport} || 'local') eq 'ssh' ? "rex:$inventory->{host}" : 'rex:local';
}

sub _provider_command_outcome {
  my ($self, %args) = @_;

  my $bundle              = $self->_rex_bundle;
  my $absolute_run_dir    = File::Spec->rel2abs($self->{run_dir});
  my $absolute_bundle_dir = File::Spec->catdir($absolute_run_dir, $bundle->{path});
  my $absolute_rexfile    = File::Spec->catfile($absolute_bundle_dir, 'Rexfile');

  local $ENV{OVERNET_BURNER_REX_COMMAND} = $args{command};
  my ($output, $exit_code) = $self->_capture_rex(
    cwd     => $absolute_bundle_dir,
    command => [$self->_rex_command, '-f', $absolute_rexfile, 'provider_command'],
  );

  return {stdout => $output, stderr => q{}, exit_code => $exit_code};
}

# Run a Rex invocation, capturing its merged output and exit code without
# dying, so the provider-command bookkeeping in the base runner records the
# outcome (and drives failure handling) the same way it does for guest
# execution.
sub _capture_rex {
  my ($self, %args) = @_;

  my $cwd     = $args{cwd}     || croak "cwd is required\n";
  my $command = $args{command} || croak "command is required\n";

  my $pid = open my $fh, q{-|};
  if (!defined $pid) {
    croak "fork Rex command: $OS_ERROR\n";
  }

  if ($pid == 0) {
    chdir $cwd or exit 127;
    open STDERR, '>&', \*STDOUT or exit 127;
    if (!exec @{$command}) {
      exit 127;
    }
  }

  local $INPUT_RECORD_SEPARATOR = undef;
  my $output = <$fh>;
  my $closed = close $fh;
  my $status = $CHILD_ERROR;

  # A close failure on the pipe still leaves the child's status in $?; only a
  # close that fails with no child status at all is a hard error.
  if (!$closed && $status == 0) {
    croak "close Rex command: $OS_ERROR\n";
  }

  my $exit_code = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);

  return (defined $output ? $output : q{}, $exit_code);
}

1;

=head1 NAME

Overnet::Burner::Runner::RexRemote - Rex runner that genuinely performs the SUT lifecycle

=head1 DESCRIPTION

Executes the topology-provider lifecycle (C<start>, C<health>, C<stop>) through
real Rex tasks against each relay's host, rather than through the controller's
guest primitive. It renders the Rex bundle in C<performed> mode - a real,
executable C<Rexfile> that connects with key authentication over SSH (or runs
locally on the controller host) - and reports a truthful
C<execution.remote_execution> value (C<remote> for an SSH target, C<local> for
the controller host). See F<docs/rex-backend.md>.

Unlike C<rex-local> and C<rex-local-provider>, which render a planned bundle and
run placeholder lifecycle tasks, C<rex-remote> is a performing backend: the
C<rex> binary actually connects and runs the provider command on the host.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(name => 'rex-remote', %args);

=head1 SUBROUTINES/METHODS

=head2 start

Performs the provider start and health commands via Rex.

=head1 DIAGNOSTICS

Provider command failures and a missing relay guest address are reported through
exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

The relay host and key come from C<provision.relays> in the normalized config; a
C<connect> relay is reached over SSH, everything else runs on the controller
host. C<OVERNET_BURNER_REX> overrides the C<rex> executable.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

This runner performs the SUT lifecycle; Rex-driven worker load-generation and
package/service installation are not yet implemented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
