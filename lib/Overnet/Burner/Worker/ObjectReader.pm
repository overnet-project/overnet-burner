package Overnet::Burner::Worker::ObjectReader;

use strictures 2;
use Moo;

extends 'Overnet::Burner::Worker';

use Carp qw(croak);
use HTTP::Tiny;
use JSON        ();
use Time::HiRes qw(sleep time);

our $VERSION = '0.001';

my $READ_TIMEOUT    = 5;
my $OBJECT_ENDPOINT = '/.well-known/overnet/v1/object';
my $UNREACHABLE     = 599;

no Moo;

sub expected_role {
  return 'object_reader';
}

sub run {
  my ($self) = @_;

  my $input   = $self->input;
  my $reads   = ref($input->{workload}{object_reads}) eq 'HASH' ? $input->{workload}{object_reads} : {};
  my $objects = $reads->{objects};
  if (!(ref($objects) eq 'ARRAY' && @{$objects})) {
    croak "object_reader requires workload.object_reads.objects\n";
  }

  my $origin = $self->_object_read_origin($input->{endpoints}{relays}[0]);
  my $http   = HTTP::Tiny->new(timeout => $READ_TIMEOUT);

  $self->open_metric_stream;

  my $probe = $http->get($origin . $OBJECT_ENDPOINT);
  if ($probe->{status} == $UNREACHABLE) {
    croak "object read endpoint unreachable at $origin\n";
  }

  $self->write_ready_file;

  my $stop = 0;
  local $SIG{TERM} = sub { $stop = 1 };

  my $rate = 0 + ($reads->{rate_per_second} || 1);
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
    $self->_read_once(
      http   => $http,
      origin => $origin,
      object => $objects->[($sequence - 1) % @{$objects}],
    );
  }

  $self->close_metric_stream;

  return;
}

sub _read_once {
  my ($self, %args) = @_;

  my $object = $args{object};
  my $url    = sprintf '%s%s?type=%s&id=%s', $args{origin}, $OBJECT_ENDPOINT,
    _url_escape($object->{type}), _url_escape($object->{id});

  my $started_at  = time;
  my $response    = $args{http}->get($url);
  my $finished_at = time;

  my $fulfilled = $response->{status} == 200;
  my %outcome;
  if ($response->{status} == $UNREACHABLE) {
    my ($reason) = split /\n/mxs, ($response->{content} // q{});
    $outcome{error} = defined $reason && length $reason ? $reason : 'object read failed';
  } else {
    $outcome{http_status} = 0 + $response->{status};
    if (!$fulfilled) {
      my $code = eval { JSON::decode_json($response->{content})->{error}{code} };
      $outcome{error} = defined $code && !ref($code) && length $code ? $code : "http_$response->{status}";
    }
  }

  $self->emit_metric(
    operation   => 'object_read',
    started_at  => $self->iso_timestamp($started_at),
    finished_at => $self->iso_timestamp($finished_at),
    duration_ms => ($finished_at - $started_at) * 1000,
    status      => $fulfilled ? 'success' : 'error',
    object_type => $object->{type},
    object_id   => $object->{id},
    relay_url   => $self->input->{endpoints}{relays}[0],
    %outcome,
  );

  return;
}

sub _object_read_origin {
  my ($class, $endpoint) = @_;

  my $origin = $endpoint;
  if ($origin =~ m{\Awss://}mxs) {
    $origin =~ s{\Awss://}{https://}mxs;
  } elsif ($origin =~ m{\Aws://}mxs) {
    $origin =~ s{\Aws://}{http://}mxs;
  } elsif ($origin !~ m{\Ahttps?://}mxs) {
    croak "cannot derive an object read origin from relay endpoint $endpoint\n";
  }
  $origin =~ s{/+\z}{}mxs;

  return $origin;
}

sub _url_escape {
  my ($value) = @_;

  $value =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/egmxs;

  return $value;
}

1;

=head1 NAME

Overnet::Burner::Worker::ObjectReader - reference object reader worker

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Worker::ObjectReader;

  my $reader = Overnet::Burner::Worker::ObjectReader->new(input => $input);
  $reader->run;

=head1 DESCRIPTION

This module is the Perl reference implementation of the C<object_reader>
role under the worker contract in F<docs/workers.md>. It cycles through
C<workload.object_reads.objects> at C<workload.object_reads.rate_per_second>,
reading each reference from the relay's derived-object endpoint as defined
by the Overnet relay specification, on the origin derived from the first
relay endpoint. A fulfilled read is a C<success> metric event; a structured
relay refusal is an C<error> metric event carrying the relay's outcome code
and HTTP status, because refusals are behavior of the system under test,
not worker failures. An endpoint that is unreachable before the workload
starts is a fatal worker failure. Workers in other languages are equally
valid; the contract documents are normative.

=head1 SUBROUTINES/METHODS

=head2 expected_role

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

The reference object reader requires a relay implementing the Overnet
derived-object read endpoint; a plain Nostr relay does not provide one.

=head1 AUTHOR

Nicholas B. Hubbard <nicholashubbard@posteo.net>

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
