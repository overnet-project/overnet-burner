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
use POSIX            qw(strftime);
use Time::HiRes      qw(sleep time);

use Overnet::Burner::ContainerEngine;
use Overnet::Burner::Guest::Container;
use Overnet::Burner::Guest::Exec;
use Overnet::Burner::Guest::SSH;
use Overnet::Burner::Guest::Virtual;
use Overnet::Burner::Hardware ();
use Overnet::Burner::ReferenceImage;
use Overnet::Burner::Util qw(json_text read_file read_json_file write_file);

our $VERSION = '0.001';

has worker_command_default => (is => 'ro');

no Moo;

my %WORKER_ROLES = (
  publisher           => 1,
  subscriber          => 1,
  query_reader        => 1,
  object_reader       => 1,
  observer            => 1,
  flooder             => 1,
  malformed_publisher => 1,
  replayer            => 1,
  subscription_abuser => 1,
  sybil               => 1,
  connection_flood    => 1,
  provenance_forger   => 1,
);
my @LAUNCH_WAVES = (
  [qw(subscriber query_reader object_reader observer)],
  [qw(publisher flooder malformed_publisher replayer subscription_abuser sybil connection_flood provenance_forger)],
);
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
  $self->_provision_relay_guests;
  $self->_capture_guest_clocks;

  return 1;
}

# subscription_fanout compares a subscriber's receive time against a
# publisher's sent_at stamp, which crosses two clocks once actors run on
# different hosts. Recording each guest's clock offset relative to the
# controller lets the report tell an honest cross-host fanout number from a
# clock-skew artifact. Local guests share the controller clock, so their
# offset is zero by construction.
sub _capture_guest_clocks {
  my ($self) = @_;

  my %seen;
  my @guests =
    grep { !$seen{$_->name}++ } (@{$self->{worker_guests} || []}, @{$self->{relay_guests} || []});

  my @records = map { $self->_measure_guest_clock($_) } @guests;

  write_file(
    File::Spec->catfile($self->{run_dir}, 'clocks.json'),
    json_text(
      {
        measured_at => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        guests      => \@records,
      }
    ),
  );

  return 1;
}

sub _measure_guest_clock {
  my ($self, $guest) = @_;

  my %reading = (name => $guest->name, transport => $guest->transport, role => $guest->role);

  # A guest with the controller's own clock has no offset and needs no probe.
  if ($guest->transport eq 'exec') {
    $reading{offset_ms}     = 0;
    $reading{round_trip_ms} = 0;
    return \%reading;
  }

  my $before  = time * 1000;
  my $outcome = eval { $guest->run_command(command => 'date +%s%N') };
  my $after   = time * 1000;

  my ($nanoseconds) = (ref $outcome eq 'HASH' && defined $outcome->{stdout}) ? $outcome->{stdout} =~ /(\d+)/mxs : ();
  if (defined $nanoseconds && ref $outcome eq 'HASH' && ($outcome->{exit_code} // -1) == 0) {
    my $guest_ms = $nanoseconds / 1_000_000;
    my $midpoint = ($before + $after) / 2;
    $reading{offset_ms}     = 0 + sprintf('%.1f', $guest_ms - $midpoint);
    $reading{round_trip_ms} = 0 + sprintf('%.1f', $after - $before);
  } else {
    $reading{offset_ms}     = undef;
    $reading{round_trip_ms} = undef;
  }

  return \%reading;
}

sub _provision_worker_guests {
  my ($self) = @_;

  my $config    = read_json_file(File::Spec->catfile($self->{run_dir}, 'config.normalized.json'));
  my $provision = ref $config->{provision} eq 'HASH'  ? $config->{provision}  : {};
  my $workers   = ref $provision->{workers} eq 'HASH' ? $provision->{workers} : {};
  my $how       = $workers->{how} || 'local';

  $self->_progress_event(action => 'provision', target => 'workers', method => $how, status => 'started');

  $self->{worker_command} = $workers->{worker};

  # Constructed guests are registered as they come up so a failure partway
  # through provisioning still tears down everything already built.
  $self->{worker_guests} = [];
  if ($how eq 'connect') {
    push @{$self->{worker_guests}}, $self->_connect_guests($workers, 'workers');
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

  $self->_progress_event(action => 'provision', target => 'workers', method => $how, status => 'completed');

  return 1;
}

sub _connect_guests {
  my ($self, $spec, $group) = @_;
  $group ||= 'workers';
  my $prefix = $group eq 'relays' ? 'relay' : 'worker';

  my @guests;
  my $ordinal = 0;
  for my $entry (@{$spec->{guests} || []}) {
    $ordinal++;
    push @guests,
      Overnet::Burner::Guest::SSH->new(
      name    => sprintf('%s-guest-%03d', $prefix, $ordinal),
      role    => $group,
      address => $entry->{address},
      exists $entry->{user} ? (user => $entry->{user}) : (),
      exists $entry->{port} ? (port => $entry->{port}) : (),
      exists $entry->{key}  ? (key  => $entry->{key})  : (),
      );
  }

  return @guests;
}

sub _provision_relay_guests {
  my ($self) = @_;

  my $config    = read_json_file(File::Spec->catfile($self->{run_dir}, 'config.normalized.json'));
  my $provision = ref $config->{provision} eq 'HASH' ? $config->{provision} : {};
  my $relays    = ref $provision->{relays} eq 'HASH' ? $provision->{relays} : {};
  my $how       = $relays->{how} || 'local';

  $self->_progress_event(action => 'provision', target => 'relays', method => $how, status => 'started');

  # Connect and container place relays on their own guests. Local keeps them
  # on the controller host, where the base runner already runs lifecycle.
  $self->{relay_actor_guests} = {};
  if ($how eq 'local') {
    $self->_progress_event(action => 'provision', target => 'relays', method => $how, status => 'completed');
    return 1;
  }

  my @guests =
      $how eq 'connect'   ? $self->_connect_guests($relays, 'relays')
    : $how eq 'container' ? $self->_relay_container_guests($relays)
    :                       ();
  if (!@guests) {
    $self->_progress_event(action => 'provision', target => 'relays', method => $how, status => 'completed');
    return 1;
  }
  $self->{relay_guests} = \@guests;

  for my $actor ($self->_relay_actors) {
    my $guest = $guests[(($actor->{ordinal} || 1) - 1) % @guests];
    $self->{relay_actor_guests}{$actor->{id}} = $guest;
  }

  my @guest_records = map { _guest_record($_) } @guests;
  my %placement     = map { $_ => $self->{relay_actor_guests}{$_}->name } keys %{$self->{relay_actor_guests}};
  my $engine        = $self->{relay_engine};
  write_file(
    File::Spec->catfile($self->{run_dir}, 'relay-guests.json'),
    json_text(
      {
        guests    => \@guest_records,
        placement => \%placement,
        $engine ? (engine => {name => $engine->name, version => $engine->version}) : (),
        $self->{worker_network}
        ? (network => {name => $self->{worker_network}, mode => 'bridge'})
        : (),
        exists $relays->{hardware} ? (hardware_requirements => $relays->{hardware}) : (),
      }
    ),
  );

  $self->_progress_event(action => 'provision', target => 'relays', method => $how, status => 'completed');

  return 1;
}

sub _relay_container_guests {
  my ($self, $relays) = @_;

  my $engine   = Overnet::Burner::ContainerEngine->detect(engine => $relays->{engine} || 'auto');
  my $manifest = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $run_id   = $manifest->{run_id};
  my $network  = $self->_container_network($engine, $relays->{network} || 'bridge');
  my $image    = $self->_container_image($engine, $relays);

  $self->{relay_engine} = $engine;

  my @guests;
  for my $ordinal (1 .. ($relays->{count} || 1)) {
    my $guest_name = sprintf 'relay-guest-%03d', $ordinal;
    my $alias      = sprintf 'relay-%03d',       $ordinal;
    my $container  = "burner-$run_id-$guest_name";

    my $guest = Overnet::Burner::Guest::Container->new(
      name      => $guest_name,
      role      => 'relays',
      engine    => $engine,
      container => $container,
      image     => $image,
      alias     => $alias,
    );
    push @{$self->{relay_guests}}, $guest;
    push @guests,                  $guest;

    $self->_progress_event(
      action => 'launch_guest',
      target => 'relays',
      method => 'container',
      guest  => $guest_name,
      status => 'started',
    );
    $engine->run_detached(
      name            => $container,
      image           => $image,
      network         => $network,
      network_aliases => [$alias],
      command         => ['sleep', 'infinity'],
    );
    $self->_progress_event(
      action => 'launch_guest',
      target => 'relays',
      method => 'container',
      guest  => $guest_name,
      status => 'completed',
    );
  }

  return @guests;
}

sub _relay_actors {
  my ($self) = @_;

  return @{$self->{plan}{relays} || []};
}

sub _relay_guest_for {
  my ($self, $actor_id) = @_;

  if (defined $actor_id && ref $self->{relay_actor_guests} eq 'HASH' && $self->{relay_actor_guests}{$actor_id}) {
    return $self->{relay_actor_guests}{$actor_id};
  }

  return $self->SUPER::_relay_guest_for($actor_id);
}

sub _container_guests {
  my ($self, $workers, $chaos) = @_;

  my $engine   = Overnet::Burner::ContainerEngine->detect(engine => $workers->{engine} || 'auto');
  my $manifest = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $run_id   = $manifest->{run_id};
  $self->{worker_engine} = $engine;

  my $network = $self->_container_network($engine, $workers->{network} || 'host');
  my $image   = $self->_container_image($engine, $workers);
  my @cap_add = (grep { $NETEM_ACTIONS{$_->{action} || q{}} } @{$chaos}) ? ('NET_ADMIN') : ();

  for my $ordinal (1 .. ($workers->{count} || 1)) {
    my $guest_name = sprintf 'worker-guest-%03d', $ordinal;
    my $container  = "burner-$run_id-$guest_name";

    # Registered before the engine call: `run -d` can create the container
    # and still fail to start it, and only a registered guest is destroyed
    # by failure cleanup.
    push @{$self->{worker_guests}},
      Overnet::Burner::Guest::Container->new(
      name      => $guest_name,
      role      => 'workers',
      engine    => $engine,
      container => $container,
      image     => $image,
      cap_add   => \@cap_add,
      );
    $self->_progress_event(
      action => 'launch_guest',
      target => 'workers',
      method => 'container',
      guest  => $guest_name,
      status => 'started',
    );
    $engine->run_detached(
      name    => $container,
      image   => $image,
      network => $network,
      @cap_add ? (cap_add => \@cap_add) : (),
      command => ['sleep', 'infinity'],
    );
    $self->_progress_event(
      action => 'launch_guest',
      target => 'workers',
      method => 'container',
      guest  => $guest_name,
      status => 'completed',
    );
  }

  return 1;
}

sub _container_network {
  my ($self, $engine, $network) = @_;

  if ($network ne 'bridge') {
    return $network;
  }

  if ($self->{worker_network}) {
    return $self->{worker_network};
  }

  my $manifest = read_json_file(File::Spec->catfile($self->{run_dir}, 'manifest.json'));
  my $name     = "burner-$manifest->{run_id}";
  $self->_progress_event(
    action  => 'create_network',
    target  => 'containers',
    method  => 'container',
    network => $name,
    engine  => $engine->name,
    status  => 'started',
  );
  $engine->network_create($name);
  $self->_progress_event(
    action  => 'create_network',
    target  => 'containers',
    method  => 'container',
    network => $name,
    engine  => $engine->name,
    status  => 'completed',
  );
  $self->{worker_network} = $name;
  $self->{worker_engine} ||= $engine;

  return $name;
}

sub _container_image {
  my ($self, $engine, $spec) = @_;

  my $image = $spec->{image} || croak "container image is required\n";
  if (($spec->{managed_image} || q{}) ne 'reference') {
    return $image;
  }

  my $key = join "\0", $engine->name, $image;
  if (!$self->{managed_images}{$key}) {
    $self->_progress_event(
      action => 'ensure_image',
      target => 'containers',
      method => 'container',
      image  => $image,
      engine => $engine->name,
      status => 'started',
    );
    Overnet::Burner::ReferenceImage->ensure(engine => $engine, run_dir => $self->{run_dir}, tag => $image);
    $self->_progress_event(
      action => 'ensure_image',
      target => 'containers',
      method => 'container',
      image  => $image,
      engine => $engine->name,
      status => 'completed',
    );
    $self->{managed_images}{$key} = 1;
  }

  return $image;
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
  my $key        = _generate_ssh_key($virtual_dir);
  my $public_key = read_file("$key.pub");

  for my $ordinal (1 .. ($workers->{count} || 1)) {
    my $guest_name = sprintf 'worker-guest-%03d', $ordinal;
    my $vm_name    = "burner-$run_id-$guest_name";
    my $guest_dir  = File::Spec->catdir($virtual_dir, $guest_name);
    make_path($guest_dir);
    my $seed = _seed_iso(
      guest_dir  => $guest_dir,
      vm_name    => $vm_name,
      guest_name => $guest_name,
      public_key => $public_key,
    );
    my $port     = _free_port();
    my $pid_file = File::Spec->catfile($guest_dir, 'qemu.pid');

    # Registered before the launch: qemu can partially start (writing its pid
    # file) and still fail, and only a registered guest is destroyed by failure
    # cleanup. Mirrors the container path.
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
    _launch_vm(
      vm_name     => $vm_name,
      image       => $image,
      memory_mb   => $memory_mb,
      cpus        => $cpus,
      accel       => $accel,
      seed        => $seed,
      port        => $port,
      pid_file    => $pid_file,
      console_log => File::Spec->catfile($guest_dir, 'console.log'),
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

  # The seed rides a virtio disk, not a CDROM: cloud kernels (Debian's
  # cloud-amd64, for one) ship no SATA/AHCI drivers, so a -cdrom seed is
  # invisible to exactly the images this method exists to boot.
  my $status = system $qemu,
    '-name',      $args{vm_name}, '-machine', 'q35',
    '-m',         "$args{memory_mb}M", '-smp', $args{cpus},
    '-accel',     $args{accel}, '-cpu', $cpu, '-snapshot',
    '-drive',     "file=$args{image},format=$format,if=virtio",
    '-drive',     "file=$args{seed},format=raw,if=virtio,readonly=on",
    '-netdev',    "user,id=net0,hostfwd=tcp:127.0.0.1:$args{port}-:22",
    '-device',    'virtio-net-pci,netdev=net0',
    '-display',   'none',     '-serial', "file:$args{console_log}",
    '-daemonize', '-pidfile', $args{pid_file};
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
    if (defined $guest->alias) {
      $guest_record{alias} = $guest->alias;
    }
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

  return 1;
}

sub _destroy_relay_guests {
  my ($self) = @_;

  for my $guest (@{$self->{relay_guests} || []}) {
    $guest->destroy;
  }

  return 1;
}

sub _destroy_container_network {
  my ($self) = @_;

  if (!$self->{worker_network}) {
    return 1;
  }

  my $engine = $self->{worker_engine} || $self->{relay_engine};
  if ($engine) {
    $engine->network_remove($self->{worker_network});
  }
  $self->{worker_network} = undef;

  return 1;
}

sub _destroy_constructed_guests {
  my ($self) = @_;

  $self->_destroy_worker_guests;
  $self->_destroy_relay_guests;
  $self->_destroy_container_network;

  return 1;
}

sub teardown_on_signal {
  my ($self) = @_;

  # Called from a signal handler: TERM/KILL and reap every worker process still
  # running, then destroy every constructed guest, so a Ctrl-C or kill leaves no
  # orphaned worker, container, virtual machine, or per-run network. Reaping the
  # workers first also stops load generators for the local/exec transport, whose
  # guest destroy is a no-op. Both steps are best-effort and idempotent, so an
  # orderly teardown that already drained the workers makes this a quiet no-op.
  # Connect guests are operator-owned and their destroy is a no-op by design.
  $self->_terminate_remaining_workers;
  $self->_destroy_constructed_guests;

  return 1;
}

sub cleanup_after_lifecycle_failure {
  my ($self, %args) = @_;

  # Stop and reap any worker still running from the failed run before anything
  # else, so a launch/readiness/chaos failure mid-observe cannot orphan local
  # load generators.
  $self->_terminate_remaining_workers;

  if (!eval { $self->_pull_worker_logs; 1 }) {
    $self->_record_worker_event(status => 'worker_log_pull_failed', phase => 'cleanup');
  }

  my $ok = eval {
    $self->SUPER::cleanup_after_lifecycle_failure(%args);
    1;
  };
  my $error = $EVAL_ERROR;
  $self->_destroy_constructed_guests;
  if (!$ok) {
    croak $error;
  }

  return 1;
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

    $self->_verify_worker_command_resolves(\@launchable);

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
  my $run_dir    = File::Spec->rel2abs($self->{run_dir});
  for my $stream (@{$plan->{metric_streams} || []}) {
    my $guest   = $self->_guest_for($stream->{actor_id});
    my $path    = File::Spec->catfile($run_dir, $stream->{path});
    my $content = $guest->read_file($path);
    if (!(defined $content && length $content)) {
      next;
    }
    _store_local_copy($guest, $path, $content);
    $aggregated .= $content;
    push @collected, $stream->{path};
  }
  if (!eval { $self->_pull_worker_logs; 1 }) {
    $self->_record_worker_event(status => 'worker_log_pull_failed', phase => 'collect');
  }

  if (@collected) {
    write_file(File::Spec->catfile($self->{run_dir}, 'metrics.jsonl'), $aggregated);
  }
  $self->_record_worker_event(
    status            => 'collected',
    phase             => 'collect',
    streams_collected => \@collected,
  );
  $self->_destroy_constructed_guests;

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
      _store_local_copy($guest, $path, $content);
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
  return map { @{$plan->{$_} || []} } qw(subscribers query_readers object_readers observers publishers
    flooders malformed_publishers replayers subscription_abusers sybils connection_floods provenance_forgers);
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
  my $run_dir    = File::Spec->rel2abs($self->{run_dir});
  my $worker_dir = File::Spec->catdir($run_dir, 'workers', $actor_id);
  my $logs_dir   = File::Spec->catdir($run_dir, 'logs',    'workers');
  my $stream_dir = dirname(File::Spec->catfile($run_dir, $actor->{metric_stream}));

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
    run_dir          => $run_dir,
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

  my $command = $self->_worker_command($guest);
  my $stdout  = File::Spec->catfile($logs_dir, "$actor_id.stdout");
  my $stderr  = File::Spec->catfile($logs_dir, "$actor_id.stderr");
  $self->{worker_log_files}{$actor_id} = [$stdout, $stderr];

  $self->{worker_pids}{$actor_id} = $guest->launch(
    command => $command,
    env     => {OVERNET_BURNER_WORKER_INPUT => $input_path},
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

sub _worker_command {
  my ($self, $guest) = @_;

  return $self->{worker_command} || $ENV{OVERNET_BURNER_WORKER} || _default_worker_command($self, $guest);
}

sub _default_worker_command {
  my ($self, $guest) = @_;

  if ($guest && $guest->transport eq 'exec' && defined $self->worker_command_default) {
    return $self->worker_command_default;
  }

  return 'overnet-burner worker';
}

sub _verify_worker_command_resolves {
  my ($self, $launchable) = @_;

  # Only the local exec transport resolves the worker command in an
  # environment we can cheaply and reliably pre-flight the same way a launch
  # would (/bin/sh -c). Remote, container, and virtual guests resolve it in a
  # foreign filesystem where a probe is both less dependable and less needed:
  # those operators point provision.workers.worker at an absolute path, a
  # baked-in image command, or an installed binary. Catching the common
  # uninstalled-checkout mistake here turns a cryptic launch-time
  # "not found" into an actionable error before a whole wave is launched.
  my %checked;
  for my $actor (@{$launchable}) {
    my $guest = $self->_guest_for($actor->{id});
    if ($guest->transport ne 'exec' || $checked{$guest->name}++) {
      next;
    }

    my $command = $self->_worker_command($guest);
    my $program = _command_program($command);
    if (!(defined $program && length $program)) {
      next;
    }

    my $outcome = $guest->run_command(command => 'command -v ' . _shell_quote($program));
    if (ref $outcome eq 'HASH' && ($outcome->{exit_code} // -1) == 0) {
      next;
    }

    croak "worker command \"$program\" was not found on guest "
      . $guest->name . ".\n"
      . "Install overnet-burner so 'overnet-burner worker' is on PATH, or point the\n"
      . "OVERNET_BURNER_WORKER environment variable or provision.workers.worker at a\n"
      . "runnable command.\n";
  }

  return 1;
}

sub _command_program {
  my ($command) = @_;

  $command = defined $command ? $command : q{};
  $command =~ s/\A\s+//mxs;
  if ($command =~ /\A'((?:[^']|'\\'')*)'/mxs) {
    my $program = $1;
    $program =~ s/'\\''/'/gmxs;
    return $program;
  }
  if ($command =~ /\A"((?:\\"|[^"])*)"/mxs) {
    my $program = $1;
    $program =~ s/\\"/"/gmxs;
    return $program;
  }

  my ($program) = $command =~ /\A(\S+)/mxs;
  return $program;
}

sub _shell_quote {
  my ($value) = @_;

  my $quoted = defined $value ? $value : q{};
  $quoted =~ s/'/'\\''/gmxs;

  return "'$quoted'";
}

sub _await_wave_ready {
  my ($self, $wave_actors) = @_;

  if (!@{$wave_actors}) {
    return 1;
  }

  my $workers_root = File::Spec->catdir(File::Spec->rel2abs($self->{run_dir}), 'workers');
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

  $self->_terminate_remaining_workers;

  if (@pending) {
    my $described = join ', ', map { $_->{hook}{id} } @pending;
    croak "chaos hook $described did not fire within the run window\n";
  }

  if (%{$self->{worker_pids}}) {
    my $described = join ', ', sort keys %{$self->{worker_pids}};
    croak "worker $described could not be reaped\n";
  }

  my @failed = grep { !defined $_->{exit_code} || $_->{exit_code} != 0 } @{$self->{worker_results}};
  if (@failed) {
    my $described = join ', ', map { $_->{actor_id} } @failed;
    croak "worker $described did not complete cleanly\n";
  }

  return 1;
}

sub _terminate_remaining_workers {
  my ($self) = @_;

  # Force every still-tracked worker process down and reap it: a graceful TERM
  # with a grace window, then KILL for anything that ignores it. Best-effort and
  # idempotent -- a no-op when nothing is left running -- so the normal exit
  # path, the lifecycle-failure cleanup, and the signal teardown can all call it.
  # Signalling is guarded so one unreachable guest cannot leave the rest of the
  # workers orphaned.
  if (!%{$self->{worker_pids}}) {
    return 1;
  }

  for my $signal (qw(TERM KILL)) {
    for my $actor_id (sort keys %{$self->{worker_pids}}) {
      eval { $self->_guest_for($actor_id)->signal($self->{worker_pids}{$actor_id}, $signal); 1 }
        or next;
    }
    $self->_reap_until(time + $KILL_GRACE_SECONDS);
    if (!%{$self->{worker_pids}}) {
      last;
    }
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

  # stderr is merged so a failed action records its cause (tc missing, no
  # capability) in the ledger instead of a bare command line.
  my ($output, $status) = $guest->engine->exec_capture($guest->container, "{ $command; } 2>&1");
  if ($status != 0) {
    my $detail = defined $output && length $output ? $output : 'no output';
    chomp $detail;
    croak 'guest ' . $guest->name . " could not run: $command: $detail\n";
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

=head2 teardown_on_signal

=head2 cleanup_after_lifecycle_failure

=head1 DIAGNOSTICS

Worker launch, readiness, and exit failures are reported through exceptions
after being recorded as runner events.

=head1 CONFIGURATION AND ENVIRONMENT

The worker command is resolved first from the scenario's
C<provision.workers.worker>, then from the C<OVERNET_BURNER_WORKER>
environment variable, and finally from C<overnet-burner worker>. For locally
provisioned workers, the default worker command reuses the same
C<overnet-burner> executable that launched the run. The command is
pre-flighted before any local worker launches, so missing custom worker
commands fail with an actionable error rather than at worker start. See
F<docs/workers.md>.

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
