package Overnet::Burner::Runner::RexLocalWorkers;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Runner::RexLocalProvider';

use Carp           qw(croak);
use English        qw(-no_match_vars);
use File::Basename qw(dirname);
use File::Path     qw(make_path);
use File::Spec;
use IO::Socket::INET ();
use JSON             ();
use Time::HiRes      qw(sleep time);

use Overnet::Burner::ContainerEngine;
use Overnet::Burner::Guest::Container;
use Overnet::Burner::Guest::Exec;
use Overnet::Burner::Guest::SSH;
use Overnet::Burner::Guest::Virtual;
use Overnet::Burner::Hardware ();
use Overnet::Burner::Util     qw(json_text read_file read_json_file write_file);

our $VERSION = '0.001';

no Moo;

my %WORKER_ROLES = (
  publisher     => 1,
  subscriber    => 1,
  query_reader  => 1,
  object_reader => 1,
  observer      => 1,
);
my @LAUNCH_WAVES  = ([qw(subscriber query_reader object_reader observer)], [qw(publisher)],);
my %NETEM_ACTIONS = ('net-delay' => 1, 'net-loss' => 1);
my %NET_ACTIONS   = (%NETEM_ACTIONS, partition => 1, heal => 1);

my $READY_TIMEOUT_SECONDS        = 10;
my $EXIT_GRACE_SECONDS           = 15;
my $KILL_GRACE_SECONDS           = 5;
my $VIRTUAL_BOOT_TIMEOUT_SECONDS = 180;
my $DEFAULT_VM_MEMORY_MB         = 1024;

sub prepare {
  my ($self) = @_;

  $self->SUPER::prepare;
  $self->{worker_results}   = [];
  $self->{worker_pids}      = {};
  $self->{worker_log_files} = {};
  $self->{chaos_results}    = [];
  $self->{guest_net_state}  = {};
  $self->_provision_worker_guests;

  return 1;
}

sub _provision_worker_guests {
  my ($self) = @_;

  my $config    = read_json_file(File::Spec->catfile($self->{run_dir}, 'config.normalized.json'));
  my $provision = ref $config->{provision} eq 'HASH'  ? $config->{provision}  : {};
  my $workers   = ref $provision->{workers} eq 'HASH' ? $provision->{workers} : {};
  my $how       = $workers->{how} || 'local';

  $self->{worker_command} = $workers->{worker};

  # Constructed guests are registered as they come up so a failure partway
  # through provisioning still tears down everything already built.
  $self->{worker_guests} = [];
  if ($how eq 'connect') {
    push @{$self->{worker_guests}}, $self->_connect_guests($workers);
  } elsif ($how eq 'container') {
    $self->_container_guests($workers, $config->{chaos} || []);
  } elsif ($how eq 'virtual') {
    $self->_virtual_guests($workers);
  } else {
    push @{$self->{worker_guests}}, Overnet::Burner::Guest::Exec->new(name => 'local', role => 'workers');
  }

  my @guests = @{$self->{worker_guests}};
  $self->{actor_guests} = {};
  for my $actor ($self->_worker_actors) {
    my $guest = $guests[(($actor->{ordinal} || 1) - 1) % @guests];
    $self->{actor_guests}{$actor->{id}} = $guest;
  }

  my $engine        = $self->{worker_engine};
  my @guest_records = map { _guest_record($_) } @guests;
  my %placement     = map { $_ => $self->{actor_guests}{$_}->name } keys %{$self->{actor_guests}};
  write_file(
    File::Spec->catfile($self->{run_dir}, 'guests.json'),
    json_text(
      {
        guests    => \@guest_records,
        placement => \%placement,
        $engine ? (engine => {name => $engine->name, version => $engine->version}) : (),
        $self->{worker_network}
        ? (network => {name => $self->{worker_network}, mode => 'bridge'})
        : (),
        exists $workers->{hardware} ? (hardware_requirements => $workers->{hardware}) : (),
      }
    ),
  );

  return 1;
}

sub _connect_guests {
  my ($self, $workers) = @_;

  my @guests;
  my $ordinal = 0;
  for my $entry (@{$workers->{guests} || []}) {
    $ordinal++;
    push @guests,
      Overnet::Burner::Guest::SSH->new(
      name    => sprintf('worker-guest-%03d', $ordinal),
      role    => 'workers',
      address => $entry->{address},
      exists $entry->{user} ? (user => $entry->{user}) : (),
      exists $entry->{port} ? (port => $entry->{port}) : (),
      exists $entry->{key}  ? (key  => $entry->{key})  : (),
      );
  }

  return @guests;
}

sub _container_guests {
  my ($self, $workers, $chaos) = @_;

  my $engine   = Overnet::Burner::ContainerEngine->detect(engine => $workers->{engine} || 'auto');
  my $manifest = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $run_id   = $manifest->{run_id};
  $self->{worker_engine} = $engine;

  my $network = $workers->{network} || 'host';
  if ($network eq 'bridge') {
    $network = "burner-$run_id";
    $engine->network_create($network);
    $self->{worker_network} = $network;
  }
  my @cap_add = (grep { $NETEM_ACTIONS{$_->{action} || q{}} } @{$chaos}) ? ('NET_ADMIN') : ();

  for my $ordinal (1 .. ($workers->{count} || 1)) {
    my $guest_name = sprintf 'worker-guest-%03d', $ordinal;
    my $container  = "burner-$run_id-$guest_name";
    $engine->run_detached(
      name    => $container,
      image   => $workers->{image},
      network => $network,
      @cap_add ? (cap_add => \@cap_add) : (),
      command => ['sleep', 'infinity'],
    );
    push @{$self->{worker_guests}},
      Overnet::Burner::Guest::Container->new(
      name      => $guest_name,
      role      => 'workers',
      engine    => $engine,
      container => $container,
      image     => $workers->{image},
      cap_add   => \@cap_add,
      );
  }

  return 1;
}

sub _virtual_guests {
  my ($self, $workers) = @_;

  my $manifest = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $run_id   = $manifest->{run_id};

  my $image = $workers->{image};
  if (!-r $image) {
    croak "provision.workers.image $image does not exist or is unreadable\n";
  }

  my %minimums  = Overnet::Burner::Hardware::requirement_minimums($workers->{hardware} || {});
  my $memory_mb = $minimums{memory_mb}            || $DEFAULT_VM_MEMORY_MB;
  my $cpus      = $minimums{cpus}                 || 1;
  my $accel     = $ENV{OVERNET_BURNER_QEMU_ACCEL} || (-w '/dev/kvm' ? 'kvm' : 'tcg');

  my $virtual_dir = File::Spec->catdir($self->{run_dir}, 'virtual');
  make_path($virtual_dir);
  my $key = _generate_ssh_key($virtual_dir);

  for my $ordinal (1 .. ($workers->{count} || 1)) {
    my $guest_name = sprintf 'worker-guest-%03d', $ordinal;
    my $vm_name    = "burner-$run_id-$guest_name";
    my $guest_dir  = File::Spec->catdir($virtual_dir, $guest_name);
    make_path($guest_dir);
    my $seed = _seed_iso(
      guest_dir  => $guest_dir,
      vm_name    => $vm_name,
      guest_name => $guest_name,
      public_key => read_file("$key.pub"),
    );
    my $port     = _free_port();
    my $pid_file = File::Spec->catfile($guest_dir, 'qemu.pid');
    _launch_vm(
      vm_name   => $vm_name,
      image     => $image,
      memory_mb => $memory_mb,
      cpus      => $cpus,
      accel     => $accel,
      seed      => $seed,
      port      => $port,
      pid_file  => $pid_file,
    );
    push @{$self->{worker_guests}},
      Overnet::Burner::Guest::Virtual->new(
      name      => $guest_name,
      role      => 'workers',
      address   => '127.0.0.1',
      port      => $port,
      user      => 'burner',
      key       => $key,
      pid_file  => $pid_file,
      image     => $image,
      memory_mb => $memory_mb,
      cpus      => $cpus,
      accel     => $accel,
      );
  }

  $self->_await_guests_reachable;

  return 1;
}

sub _generate_ssh_key {
  my ($dir) = @_;

  my $key    = File::Spec->catfile($dir, 'id_ed25519');
  my $keygen = $ENV{OVERNET_BURNER_SSH_KEYGEN} || 'ssh-keygen';
  my $status = system $keygen, '-q', '-t', 'ed25519', '-N', q{}, '-f', $key;
  if ($status != 0) {
    croak "could not generate a guest ssh key with $keygen\n";
  }

  return $key;
}

sub _seed_iso {
  my (%args) = @_;

  my $public_key = $args{public_key};
  chomp $public_key;
  my $user_data = File::Spec->catfile($args{guest_dir}, 'user-data');
  write_file($user_data, <<"USERDATA");
#cloud-config
users:
  - name: burner
    shell: /bin/sh
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $public_key
USERDATA
  my $meta_data = File::Spec->catfile($args{guest_dir}, 'meta-data');
  write_file($meta_data, "instance-id: $args{vm_name}\nlocal-hostname: $args{guest_name}\n");

  my $iso         = File::Spec->catfile($args{guest_dir}, 'seed.iso');
  my $genisoimage = $ENV{OVERNET_BURNER_GENISOIMAGE} || 'genisoimage';
  my $status      = system $genisoimage, '-quiet', '-output', $iso, '-volid', 'cidata', '-joliet', '-rock',
    $user_data, $meta_data;
  if ($status != 0) {
    croak "could not build the cloud-init seed with $genisoimage\n";
  }

  return $iso;
}

sub _launch_vm {
  my (%args) = @_;

  my $qemu   = $ENV{OVERNET_BURNER_QEMU} || 'qemu-system-x86_64';
  my $format = $args{image} =~ /[.]qcow2\z/mxs ? 'qcow2' : 'raw';
  my $cpu    = $args{accel} eq 'kvm'           ? 'host'  : 'max';
  my $status = system $qemu,
    '-name',    $args{vm_name}, '-machine', 'q35',
    '-m',       "$args{memory_mb}M", '-smp', $args{cpus},
    '-accel',   $args{accel}, '-cpu', $cpu, '-snapshot',
    '-drive',   "file=$args{image},format=$format,if=virtio",
    '-cdrom',   $args{seed},
    '-netdev',  "user,id=net0,hostfwd=tcp:127.0.0.1:$args{port}-:22",
    '-device',  'virtio-net-pci,netdev=net0',
    '-display', 'none', '-daemonize', '-pidfile', $args{pid_file};
  if ($status != 0) {
    croak "$qemu could not launch $args{vm_name}\n";
  }

  return 1;
}

sub _free_port {
  my $socket = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
    Proto     => 'tcp',
  ) or croak "could not find a free port: $OS_ERROR\n";
  my $port = $socket->sockport;
  close $socket or croak "close port probe: $OS_ERROR\n";

  return $port;
}

sub _await_guests_reachable {
  my ($self) = @_;

  my $timeout  = $ENV{OVERNET_BURNER_VIRTUAL_BOOT_TIMEOUT} || $VIRTUAL_BOOT_TIMEOUT_SECONDS;
  my $deadline = time + $timeout;
  my @pending  = @{$self->{worker_guests}};
  while (@pending) {
    @pending = grep { !$_->reachable } @pending;
    if (!@pending) {
      return 1;
    }
    if (time >= $deadline) {
      croak 'virtual guest ' . $pending[0]->name . " did not become reachable within ${timeout}s\n";
    }
    sleep 1;
  }

  return 1;
}

sub _guest_record {
  my ($guest) = @_;

  my %guest_record = (
    name      => $guest->name,
    role      => $guest->role,
    transport => $guest->transport,
  );
  if ($guest->transport eq 'ssh') {
    $guest_record{address} = $guest->address;
    for my $field (qw(user port key)) {
      if (defined $guest->$field) {
        $guest_record{$field} = $guest->$field;
      }
    }
  }
  if ($guest->transport eq 'container') {
    $guest_record{container} = $guest->container;
    $guest_record{image}     = $guest->image;
    if (@{$guest->cap_add}) {
      $guest_record{cap_add} = $guest->cap_add;
    }
  }
  if ($guest->isa('Overnet::Burner::Guest::Virtual')) {
    $guest_record{method}    = $guest->provision_method;
    $guest_record{image}     = $guest->image;
    $guest_record{accel}     = $guest->accel;
    $guest_record{memory_mb} = 0 + $guest->memory_mb;
    $guest_record{cpus}      = 0 + $guest->cpus;
  }

  return \%guest_record;
}

sub _destroy_worker_guests {
  my ($self) = @_;

  for my $guest (@{$self->{worker_guests} || []}) {
    $guest->destroy;
  }
  if ($self->{worker_network}) {
    $self->{worker_engine}->network_remove($self->{worker_network});
    $self->{worker_network} = undef;
  }

  return 1;
}

sub cleanup_after_lifecycle_failure {
  my ($self, %args) = @_;

  if (!eval { $self->_pull_worker_logs; 1 }) {
    $self->_record_worker_event(status => 'worker_log_pull_failed', phase => 'cleanup');
  }
  $self->_destroy_worker_guests;

  return $self->SUPER::cleanup_after_lifecycle_failure(%args);
}

sub _guest_for {
  my ($self, $actor_id) = @_;

  return $self->{actor_guests}{$actor_id} || $self->{worker_guests}[0];
}

sub observe {
  my ($self) = @_;

  $self->SUPER::observe;

  my $chaos_hooks = $self->_resolve_chaos_hooks;

  my @actors = $self->_worker_actors;
  my %by_role;
  for my $actor (@actors) {
    if (!$WORKER_ROLES{$actor->{role}}) {
      $self->_record_worker_event(
        actor_id => $actor->{id},
        role     => $actor->{role},
        status   => 'skipped_no_worker',
      );
      next;
    }
    push @{$by_role{$actor->{role}}}, $actor;
  }

  my @launchable = map { @{$by_role{$_} || []} } map { @{$_} } @LAUNCH_WAVES;
  if (!@launchable && !@{$chaos_hooks}) {
    return 1;
  }

  if (@launchable) {
    my $endpoints = $self->_relay_endpoints;
    if (!@{$endpoints}) {
      croak "topology.relays.endpoints is required to launch workers\n";
    }

    for my $wave (@LAUNCH_WAVES) {
      my @wave_actors = map { @{$by_role{$_} || []} } @{$wave};
      for my $actor (@wave_actors) {
        $self->_launch_worker(actor => $actor, endpoints => $endpoints);
      }
      $self->_await_wave_ready(\@wave_actors);
    }
  }

  $self->_await_worker_exits($chaos_hooks);

  return 1;
}

sub collect {
  my ($self) = @_;

  $self->SUPER::collect;

  my $plan = $self->{plan};
  my @collected;
  my $aggregated = q{};
  for my $stream (@{$plan->{metric_streams} || []}) {
    my $guest   = $self->_guest_for($stream->{actor_id});
    my $path    = File::Spec->catfile($self->{run_dir}, $stream->{path});
    my $content = $guest->read_file($path);
    if (!(defined $content && length $content)) {
      next;
    }
    _store_local_copy($guest, $path, $content);
    $aggregated .= $content;
    push @collected, $stream->{path};
  }
  $self->_pull_worker_logs;

  if (@collected) {
    write_file(File::Spec->catfile($self->{run_dir}, 'metrics.jsonl'), $aggregated);
  }
  $self->_record_worker_event(
    status            => 'collected',
    phase             => 'collect',
    streams_collected => \@collected,
  );
  $self->_destroy_worker_guests;

  return 1;
}

sub _store_local_copy {
  my ($guest, $path, $content) = @_;

  if ($guest->transport eq 'exec') {
    return 1;
  }
  make_path(dirname($path));
  write_file($path, $content);

  return 1;
}

sub _pull_worker_logs {
  my ($self) = @_;

  for my $actor_id (sort keys %{$self->{worker_log_files} || {}}) {
    my $guest = $self->_guest_for($actor_id);
    if ($guest->transport eq 'exec') {
      next;
    }
    for my $path (@{$self->{worker_log_files}{$actor_id}}) {
      my $content = $guest->read_file($path);
      if (!defined $content) {
        next;
      }
      make_path(dirname($path));
      write_file($path, $content);
    }
  }

  return 1;
}

sub summary_fields {
  my ($self) = @_;

  return (
    $self->SUPER::summary_fields,
    worker_results => $self->{worker_results} || [],
    chaos_results  => $self->{chaos_results}  || [],
  );
}

sub _worker_actors {
  my ($self) = @_;

  my $plan = $self->{plan};
  return map { @{$plan->{$_} || []} } qw(subscribers query_readers object_readers observers publishers);
}

sub _total_duration_seconds {
  my ($self) = @_;

  my $run = $self->{plan}{run} || {};

  return $run->{total_duration_seconds} // $run->{duration_seconds};
}

sub _assigned_relays {
  my ($endpoints, $ordinal) = @_;

  my $rotation = (($ordinal || 1) - 1) % @{$endpoints};

  return [@{$endpoints}[$rotation .. $#{$endpoints}], @{$endpoints}[0 .. $rotation - 1]];
}

sub _relay_endpoints {
  my ($self) = @_;

  my @endpoints =
    grep { defined && length } map { $_->{endpoint} } @{$self->{plan}{relays} || []};

  return \@endpoints;
}

sub _launch_worker {
  my ($self, %args) = @_;

  my $actor      = $args{actor};
  my $actor_id   = $actor->{id};
  my $guest      = $self->_guest_for($actor_id);
  my $manifest   = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $worker_dir = File::Spec->catdir($self->{run_dir}, 'workers', $actor_id);
  my $logs_dir   = File::Spec->catdir($self->{run_dir}, 'logs',    'workers');
  my $stream_dir = dirname(File::Spec->catfile($self->{run_dir}, $actor->{metric_stream}));
  for my $dir ($worker_dir, $logs_dir, $stream_dir) {
    $guest->make_path($dir);
  }

  my @phases;
  for my $plan_phase (@{$self->{plan}{workload}{phases} || []}) {
    my %phase = %{$plan_phase};
    delete $phase{actor_seeds};
    push @phases, \%phase;
  }
  my ($main_phase) = grep { $_->{name} eq 'main' } @phases;

  my $input = {
    input_version    => 1,
    run_id           => $manifest->{run_id},
    run_dir          => File::Spec->rel2abs($self->{run_dir}),
    worker_id        => $actor_id,
    role             => $actor->{role},
    seed             => $actor->{seed},
    duration_seconds => $self->_total_duration_seconds,
    metric_stream    => $actor->{metric_stream},
    ready_file       => File::Spec->catfile('workers', $actor_id, 'ready'),
    endpoints        => {relays => _assigned_relays($args{endpoints}, $actor->{ordinal})},
    workload         => $main_phase || $phases[0] || {},
    @phases ? (phases => \@phases) : (),
  };
  my $input_path = File::Spec->catfile($worker_dir, 'input.json');
  $guest->write_file($input_path, json_text($input));

  my $command = $self->{worker_command} || $ENV{OVERNET_BURNER_WORKER} || 'overnet-burner-worker';
  my $stdout  = File::Spec->catfile($logs_dir, "$actor_id.stdout");
  my $stderr  = File::Spec->catfile($logs_dir, "$actor_id.stderr");
  $self->{worker_log_files}{$actor_id} = [$stdout, $stderr];

  $self->{worker_pids}{$actor_id} = $guest->launch(
    command => $command,
    env     => {OVERNET_BURNER_WORKER_INPUT => File::Spec->rel2abs($input_path)},
    stdout  => $stdout,
    stderr  => $stderr,
  );
  $self->_record_worker_event(
    actor_id => $actor_id,
    role     => $actor->{role},
    status   => 'launched',
    command  => $command,
    guest    => $guest->name,
  );

  return 1;
}

sub _await_wave_ready {
  my ($self, $wave_actors) = @_;

  if (!@{$wave_actors}) {
    return 1;
  }

  my $workers_root = File::Spec->catdir($self->{run_dir}, 'workers');
  my $deadline     = time + $READY_TIMEOUT_SECONDS;
  my %pending      = map { $_->{id} => 1 } @{$wave_actors};

  while (time < $deadline) {
    my %ready;
    my %polled;
    for my $actor (@{$wave_actors}) {
      my $guest = $self->_guest_for($actor->{id});
      if ($polled{$guest->name}++) {
        next;
      }
      %ready = (%ready, map { $_ => 1 } @{$guest->ready_actors($workers_root)});
    }
    for my $actor (@{$wave_actors}) {
      if ($pending{$actor->{id}} && $ready{$actor->{id}}) {
        delete $pending{$actor->{id}};
        $self->_record_worker_event(actor_id => $actor->{id}, role => $actor->{role}, status => 'ready',);
      }
    }
    if (!%pending) {
      return 1;
    }

    for my $actor (@{$wave_actors}) {
      if (!$pending{$actor->{id}}) {
        next;
      }
      my $guest  = $self->_guest_for($actor->{id});
      my $handle = $self->{worker_pids}{$actor->{id}};
      my $status = $handle ? $guest->try_reap($handle) : undef;
      if (defined $status) {
        $self->_reap_worker($actor->{id}, $status);
        my %now_ready = map { $_ => 1 } @{$guest->ready_actors($workers_root)};
        if ($now_ready{$actor->{id}}) {
          delete $pending{$actor->{id}};
          $self->_record_worker_event(actor_id => $actor->{id}, role => $actor->{role}, status => 'ready',);
          next;
        }
        croak "worker $actor->{id} exited before becoming ready\n";
      }
    }
    sleep 0.05;
  }

  my ($first) = grep { $pending{$_->{id}} } @{$wave_actors};
  croak "worker $first->{id} was not ready within ${READY_TIMEOUT_SECONDS}s\n";
}

sub _await_worker_exits {
  my ($self, $chaos_hooks) = @_;

  my $window_start = time;
  my $deadline     = $window_start + $self->_total_duration_seconds + $EXIT_GRACE_SECONDS;
  my @pending      = @{$chaos_hooks || []};

  while ((%{$self->{worker_pids}} || @pending) && time < $deadline) {
    my $progressed = $self->_reap_pass;
    while (@pending && time - $window_start >= $pending[0]{hook}{at_seconds}) {
      my $entry = shift @pending;
      $self->_execute_chaos_hook(%{$entry}, window_start => $window_start);
      $progressed = 1;
    }
    if (!$progressed) {
      sleep 0.05;
    }
  }

  if (%{$self->{worker_pids}}) {
    for my $actor_id (sort keys %{$self->{worker_pids}}) {
      $self->_guest_for($actor_id)->signal($self->{worker_pids}{$actor_id}, 'TERM');
    }
    $self->_reap_until(time + $KILL_GRACE_SECONDS);
  }
  if (%{$self->{worker_pids}}) {
    for my $actor_id (sort keys %{$self->{worker_pids}}) {
      $self->_guest_for($actor_id)->signal($self->{worker_pids}{$actor_id}, 'KILL');
    }
    $self->_reap_until(time + $KILL_GRACE_SECONDS);
  }

  if (@pending) {
    my $described = join ', ', map { $_->{hook}{id} } @pending;
    croak "chaos hook $described did not fire within the run window\n";
  }

  my @failed = grep { !defined $_->{exit_code} || $_->{exit_code} != 0 } @{$self->{worker_results}};
  if (@failed) {
    my $described = join ', ', map { $_->{actor_id} } @failed;
    croak "worker $described did not complete cleanly\n";
  }

  return 1;
}

sub _reap_until {
  my ($self, $deadline) = @_;

  while (%{$self->{worker_pids}} && time < $deadline) {
    if (!$self->_reap_pass) {
      sleep 0.05;
    }
  }

  return 1;
}

sub _reap_pass {
  my ($self) = @_;

  my $reaped = 0;
  for my $actor_id (sort keys %{$self->{worker_pids}}) {
    my $status = $self->_guest_for($actor_id)->try_reap($self->{worker_pids}{$actor_id});
    if (defined $status) {
      $self->_reap_worker($actor_id, $status);
      $reaped = 1;
    }
  }

  return $reaped;
}

sub _reap_worker {
  my ($self, $actor_id, $status) = @_;

  delete $self->{worker_pids}{$actor_id};
  my $exit_code = ($status & 127) ? undef : ($status >> 8);
  my %result    = (
    actor_id => $actor_id,
    status   => 'exited',
    defined $exit_code ? (exit_code => $exit_code) : (signal => ($status & 127)),
  );
  push @{$self->{worker_results}}, \%result;
  $self->_record_worker_event(%result);

  return 1;
}

sub _resolve_chaos_hooks {
  my ($self) = @_;

  my @hooks = sort { $a->{at_seconds} <=> $b->{at_seconds} || $a->{ordinal} <=> $b->{ordinal} }
    @{$self->{plan}{chaos_hooks} || []};
  if (!@hooks) {
    return [];
  }

  my %provider_relays = map { $_->{actor_id} => $_ } $self->_topology_provider_command_relays;
  my @resolved;
  for my $hook (@hooks) {
    if ($NET_ACTIONS{$hook->{action}}) {
      push @resolved, {hook => $hook, guest => $self->_net_target_guest($hook)};
      next;
    }
    my ($ordinal) = $hook->{target} =~ /\Arelay:([0-9]+)\z/mxs;
    my $actor_id  = defined $ordinal  ? sprintf('relay-%03d', $ordinal) : undef;
    my $relay     = defined $actor_id ? $provider_relays{$actor_id}     : undef;
    if (!$relay) {
      croak "chaos hook $hook->{id} targets $hook->{target}," . " which has no topology provider lifecycle commands\n";
    }
    push @resolved, {hook => $hook, actor_id => $actor_id, relay => $relay};
  }

  return \@resolved;
}

sub _net_target_guest {
  my ($self, $hook) = @_;

  my ($ordinal) = $hook->{target} =~ /\Aworker-guest:([0-9]+)\z/mxs;
  my $name      = defined $ordinal ? sprintf('worker-guest-%03d', $ordinal) : q{};
  my ($guest)   = grep { $_->name eq $name } @{$self->{worker_guests} || []};
  if (!($guest && $guest->transport eq 'container' && $self->{worker_network})) {
    croak "chaos hook $hook->{id} targets $hook->{target}," . " which is not a container guest on a per-run network\n";
  }

  return $guest;
}

sub _execute_chaos_hook {
  my ($self, %args) = @_;

  if ($args{guest}) {
    return $self->_execute_net_chaos_hook(%args);
  }

  my ($hook, $actor_id, $relay) = @args{qw(hook actor_id relay)};
  my $started_at = time;
  my %base       = (
    hook_id        => $hook->{id},
    action         => $hook->{action},
    target         => $hook->{target},
    actor_id       => $actor_id,
    at_seconds     => 0 + $hook->{at_seconds},
    offset_seconds => 0 + sprintf('%.3f', $started_at - $args{window_start}),
  );

  $self->_record_chaos_event(%base, status => 'started');

  my @steps =
      $hook->{action} eq 'restart' ? qw(stop start health)
    : $hook->{action} eq 'start'   ? qw(start health)
    :                                qw(stop);
  my $ok = eval {
    for my $step (@steps) {
      $self->_run_topology_provider_command(
        actor_id  => $actor_id,
        kind      => $step,
        command   => $relay->{lifecycle}{$step}{command},
        phase     => 'observe',
        log_label => "$hook->{id}-$actor_id-$step",
      );
      if ($step eq 'stop') {
        $self->{topology_provider_started}{$actor_id} = 0;
      }
      if ($step eq 'start') {
        $self->{topology_provider_started}{$actor_id} = 1;
        $self->{topology_provider_needs_stop} = 1;
      }
    }
    1;
  };
  my $duration_ms = int((time - $started_at) * 1000 + 0.5);

  if (!$ok) {
    my $error = $EVAL_ERROR || 'chaos hook failed';
    chomp $error;
    my %failed = (%base, status => 'failed', duration_ms => $duration_ms, error => $error);
    push @{$self->{chaos_results}}, \%failed;
    $self->_record_chaos_event(%failed);
    croak "chaos hook $hook->{id} ($hook->{action} $hook->{target}) failed: $error\n";
  }

  my %completed = (%base, status => 'completed', duration_ms => $duration_ms);
  push @{$self->{chaos_results}}, \%completed;
  $self->_record_chaos_event(%completed);

  return 1;
}

sub _execute_net_chaos_hook {
  my ($self, %args) = @_;

  my ($hook, $guest) = @args{qw(hook guest)};
  my $started_at = time;
  my %base       = (
    hook_id        => $hook->{id},
    action         => $hook->{action},
    target         => $hook->{target},
    guest          => $guest->name,
    at_seconds     => 0 + $hook->{at_seconds},
    offset_seconds => 0 + sprintf('%.3f', $started_at - $args{window_start}),
  );

  $self->_record_chaos_event(%base, status => 'started');

  my $evidence;
  my $ok          = eval { $evidence = $self->_apply_net_action($hook, $guest); 1 };
  my $duration_ms = int((time - $started_at) * 1000 + 0.5);

  if (!$ok) {
    my $error = $EVAL_ERROR || 'chaos hook failed';
    chomp $error;
    my %failed = (%base, status => 'failed', duration_ms => $duration_ms, error => $error);
    push @{$self->{chaos_results}}, \%failed;
    $self->_record_chaos_event(%failed);
    croak "chaos hook $hook->{id} ($hook->{action} $hook->{target}) failed: $error\n";
  }

  my %completed = (%base, status => 'completed', duration_ms => $duration_ms, evidence => $evidence);
  push @{$self->{chaos_results}}, \%completed;
  $self->_record_chaos_event(%completed);

  return 1;
}

sub _apply_net_action {
  my ($self, $hook, $guest) = @_;

  my $action = $hook->{action};
  if ($action eq 'partition') {
    $guest->engine->network_disconnect($self->{worker_network}, $guest->container);
    $self->{guest_net_state}{$guest->name} = {partitioned => 1};
    return $self->_route_evidence($guest);
  }
  if ($action eq 'heal') {
    my $state = delete($self->{guest_net_state}{$guest->name}) || {};
    if ($state->{partitioned}) {
      $guest->engine->network_connect($self->{worker_network}, $guest->container);
    } elsif ($state->{netem}) {
      $self->_exec_net_command($guest, _tc_command(undef));
    }
    return $self->_route_evidence($guest);
  }

  my $netem =
    $action eq 'net-delay'
    ? "delay $hook->{delay_ms}ms" . (defined $hook->{jitter_ms} ? " $hook->{jitter_ms}ms" : q{})
    : "loss $hook->{loss_percent}%";
  my $evidence = $self->_exec_net_command($guest, _tc_command($netem));
  $self->{guest_net_state}{$guest->name} = {netem => 1};

  return $evidence;
}

sub _tc_command {
  my ($netem) = @_;

  my $resolve = "dev=\$(ip -o route show default); dev=\"\${dev#*dev }\"; dev=\"\${dev%% *}\"; [ -n \"\$dev\" ]";
  my $apply =
    defined $netem
    ? "tc qdisc replace dev \"\$dev\" root netem $netem"
    : "tc qdisc del dev \"\$dev\" root";

  return "$resolve && $apply && tc qdisc show dev \"\$dev\"";
}

sub _exec_net_command {
  my ($self, $guest, $command) = @_;

  my ($output, $status) = $guest->engine->exec_capture($guest->container, $command);
  if ($status != 0) {
    croak 'guest ' . $guest->name . " could not run: $command\n";
  }

  return defined $output ? $output : q{};
}

sub _route_evidence {
  my ($self, $guest) = @_;

  return $self->_exec_net_command($guest, 'ip -o route show default');
}

sub _record_chaos_event {
  my ($self, %args) = @_;

  $self->{ledger}->append_runner_event(
    {
      runner     => $self->name,
      phase      => 'observe',
      event_kind => 'chaos_hook',
      %args,
    }
  );

  return 1;
}

sub _record_worker_event {
  my ($self, %args) = @_;

  $self->{ledger}->append_runner_event(
    {
      runner     => $self->name,
      phase      => delete $args{phase} || 'observe',
      event_kind => 'worker',
      %args,
    }
  );

  return 1;
}

1;

=head1 NAME

Overnet::Burner::Runner::RexLocalWorkers - local runner that launches workers

=head1 DESCRIPTION

Extends the provider runner to launch worker processes for plan actors under
the worker contract in F<docs/workers.md>: it writes each actor's
worker-input-v1 document, starts one worker process per actor whose role has
a reference worker, sequences readiness (subscribers and readers before
publishers), waits for orderly exits within the run duration plus grace,
and concatenates the collected metric streams into the run's aggregated
C<metrics.jsonl> artifact. Actor roles without a reference worker are
recorded as explicitly skipped.

It also executes the plan's chaos hooks under the contract in
F<docs/chaos.md>: once every worker is ready the workload window opens, and
each hook fires at its scheduled offset, recorded as C<chaos_hook> ledger
events. Lifecycle hooks run the target relay's topology provider lifecycle
commands. Network hooks act on container worker guests attached to the
per-run network: C<net-delay> and C<net-loss> shape the guest's
default-route interface with C<tc netem> through the container engine,
C<partition> disconnects the guest from the per-run network, and C<heal>
undoes whichever fault is active; each completed network hook records the
captured post-action state as C<evidence>. A hook that cannot execute
fails the run.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Burner::Runner->load(name => 'rex-local-workers', %args);

=head1 SUBROUTINES/METHODS

=head2 prepare

=head2 observe

=head2 collect

=head2 summary_fields

=head2 cleanup_after_lifecycle_failure

=head1 DIAGNOSTICS

Worker launch, readiness, and exit failures are reported through exceptions
after being recorded as runner events.

=head1 CONFIGURATION AND ENVIRONMENT

C<OVERNET_BURNER_WORKER> may override the worker command used for every
launched actor; it defaults to the installed C<overnet-burner-worker>.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

All current plan actor roles have reference workers. If a plan ever carries
an actor role without one, that actor is skipped with an explicit runner
event rather than silently ignored.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
