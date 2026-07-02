package Overnet::Burner::Worker::Publisher;

use strictures 2;
use Moo;

use AnyEvent;
use Carp qw(croak);
use Crypt::PK::ECC;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use File::Spec;
use JSON ();
use Net::Nostr::Client;
use Net::Nostr::Key;
use POSIX qw(strftime);
use Sys::Hostname;
use Time::HiRes qw(sleep time);

use Overnet::Burner::Metrics;
use Overnet::Burner::Util qw(checked_close checked_print write_file);

our $VERSION = '0.001';

my $JSON            = JSON->new->utf8->canonical;
my $PUBLISH_TIMEOUT = 5;

has input => (is => 'ro');

no Moo;

sub BUILDARGS {
  my ($class, @args) = @_;
  my %args = _constructor_args_hash(@args);

  my $input = $args{input};
  if (ref($input) ne 'HASH') {
    croak "input must be a hash reference\n";
  }
  for my $field (qw(input_version run_id run_dir worker_id role seed duration_seconds metric_stream ready_file)) {
    if (!defined $input->{$field}) {
      croak "input.$field is required\n";
    }
  }
  if ($input->{input_version} ne '1') {
    croak "input.input_version must be 1\n";
  }
  if ($input->{role} ne 'publisher') {
    croak "input.role must be publisher\n";
  }
  my $relays = ref($input->{endpoints}) eq 'HASH' ? $input->{endpoints}{relays} : undef;
  if (!(ref($relays) eq 'ARRAY' && @{$relays} && !ref($relays->[0]) && length $relays->[0])) {
    croak "input.endpoints.relays must name at least one relay\n";
  }

  return {input => $input};
}

sub _constructor_args_hash {
  my (@args) = @_;
  return %{$args[0]} if @args == 1 && ref($args[0]) eq 'HASH';
  return @args       if @args % 2 == 0;
  die "constructor arguments must be a hash or hash reference\n";
}

sub derive_key {
  my ($class, $seed, $worker_id) = @_;

  if (!(defined $seed && !ref($seed) && length $seed)) {
    croak "seed is required\n";
  }
  if (!(defined $worker_id && !ref($worker_id) && length $worker_id)) {
    croak "worker_id is required\n";
  }

  my $secret_hex = sha256_hex("overnet-burner:worker:$seed:$worker_id");
  my $pk         = Crypt::PK::ECC->new;
  $pk->import_key_raw(pack('H*', $secret_hex), 'secp256k1');
  my $der = $pk->export_key_der('private');

  return Net::Nostr::Key->new(privkey => \$der);
}

sub run {
  my ($self) = @_;

  my $input = $self->input;
  my $key   = $self->derive_key($input->{seed}, $input->{worker_id});
  my $host  = hostname;

  my $stream_path = File::Spec->catfile($input->{run_dir}, $input->{metric_stream});
  open my $stream, '>>', $stream_path
    or croak "open $stream_path: $OS_ERROR\n";
  $stream->autoflush(1);

  my %pending;
  my $client = Net::Nostr::Client->new;
  $client->on(
    ok => sub {
      my ($event_id, $accepted, $message) = @_;
      my $waiter = delete $pending{$event_id};
      if ($waiter) {
        $waiter->send([$accepted ? 1 : 0, $message]);
      }
    }
  );
  $client->connect($input->{endpoints}{relays}[0]);

  write_file(File::Spec->catfile($input->{run_dir}, $input->{ready_file}), q{});

  my $stop = 0;
  local $SIG{TERM} = sub { $stop = 1 };

  my $rate = 0 + ($input->{workload}{publish_rate_per_second} || 1);
  if ($rate <= 0) {
    $rate = 1;
  }
  my $started  = time;
  my $deadline = $started + $input->{duration_seconds};
  my $sequence = 0;

  while (!$stop && time < $deadline) {
    my $scheduled = $started + $sequence / $rate;
    if ($scheduled >= $deadline) {
      last;
    }
    my $wait = $scheduled - time;
    if ($wait > 0) {
      sleep $wait;
    }
    if ($stop || time >= $deadline) {
      last;
    }

    $sequence++;
    $self->_publish_once(
      client   => $client,
      key      => $key,
      stream   => $stream,
      host     => $host,
      pending  => \%pending,
      sequence => $sequence,
    );
  }

  $client->disconnect;
  checked_close($stream, $stream_path);

  return;
}

sub _publish_once {
  my ($self, %args) = @_;

  my $input = $self->input;
  my $event = $args{key}->create_event(
    kind    => 7800,
    content => $JSON->encode(
      {
        provenance => {type => 'native'},
        body       => {
          text     => "overnet-burner publish $args{sequence}",
          sequence => $args{sequence},
        },
      }
    ),
    tags => [
      ['overnet_v',   '0.1.0'],
      ['overnet_et',  'burner.publish'],
      ['overnet_ot',  'burner.workload'],
      ['overnet_oid', $self->_workload_object_id],
      ['v',           '0.1.0'],
      ['t',           'burner.publish'],
      ['o',           'burner.workload'],
    ],
  );

  my $waiter = AnyEvent->condvar;
  $args{pending}{$event->id} = $waiter;
  my $timeout = AnyEvent->timer(
    after => $PUBLISH_TIMEOUT,
    cb    => sub {
      my $timed_out = delete $args{pending}{$event->id};
      if ($timed_out) {
        $timed_out->send([0, 'publish timed out']);
      }
    },
  );

  my $started_at = time;
  $args{client}->publish($event);
  my ($accepted, $message) = @{$waiter->recv};
  my $finished_at = time;

  my %metric = (
    metric_version => 1,
    run_id         => $input->{run_id},
    worker_id      => $input->{worker_id},
    host           => $args{host},
    role           => $input->{role},
    operation      => 'publish',
    started_at     => _iso($started_at),
    finished_at    => _iso($finished_at),
    duration_ms    => ($finished_at - $started_at) * 1000,
    status         => $accepted ? 'success' : 'error',
    event_id       => $event->id,
    relay_url      => $input->{endpoints}{relays}[0],
  );
  if (!$accepted) {
    $metric{error} = defined $message && length $message ? $message : 'publish rejected';
  }

  my ($ok, $rule_error) = Overnet::Burner::Metrics->validate_event(\%metric);
  if (!$ok) {
    croak "publisher produced an invalid metric event: $rule_error\n";
  }
  checked_print($args{stream}, $JSON->encode(\%metric) . "\n");

  return;
}

sub _workload_object_id {
  my ($self) = @_;
  my $input = $self->input;
  return "burner-$input->{run_id}-$input->{worker_id}";
}

sub _iso {
  my ($epoch)   = @_;
  my $whole     = int $epoch;
  my $millis    = int(($epoch - $whole) * 1000);
  my $formatted = strftime('%Y-%m-%dT%H:%M:%S', gmtime $whole);
  return sprintf '%s.%03dZ', $formatted, $millis;
}

1;

=head1 NAME

Overnet::Burner::Worker::Publisher - reference publisher worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::Publisher;

  my $publisher = Overnet::Burner::Worker::Publisher->new(input => $input);
  $publisher->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<publisher> role
under the worker contract in F<docs/workers.md>. It derives a deterministic
Nostr identity from the run seed and worker id, publishes valid native
Overnet events to the first configured relay endpoint at the configured
rate, waits for each relay acknowledgment, and appends one C<publish>
metric event per attempt to its assigned stream under the contract in
F<docs/METRICS.md>. Workers in other languages are equally valid; the
contract documents are normative.

=head1 SUBROUTINES/METHODS

=head2 new

Public API entry point.

=head2 input

Public API entry point.

=head2 derive_key

Public API entry point.

=head2 run

Public API entry point.

=head1 DIAGNOSTICS

Fatal worker errors are raised via C<croak>; failures of the system under
test are metric events with C<status: error>, not worker failures.

=head1 CONFIGURATION AND ENVIRONMENT

Configuration arrives through the worker input document; see
F<docs/workers.md>.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
