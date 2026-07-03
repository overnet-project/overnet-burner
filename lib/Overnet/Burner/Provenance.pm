package Overnet::Burner::Provenance;

use strictures 2;
use JSON ();

our $VERSION = '0.001';

my $JSON              = JSON->new->utf8;
my $DEFAULT_SEPARATOR = q{/};

# Reference implementation of the Overnet core provenance verification
# operation (core specification section 7.9). Given an adapted event and a
# consumer's trusted adapter authority records (section 6.15), it decides
# whether the signing identity is authoritative for the origin the event
# claims. It is the oracle the provenance_forger abuse role measures a
# verifier against, and like every burner reference module it is a
# reference implementation of a language-neutral contract, not the contract
# itself.

sub verify_event {
  my ($event, $trusted_records, $options) = @_;
  $trusted_records ||= [];
  $options         ||= {};
  my $separator = defined $options->{origin_separator} ? $options->{origin_separator} : $DEFAULT_SEPARATOR;

  my $provenance = _event_provenance($event);
  if (!defined $provenance || ($provenance->{type} // q{}) ne 'adapted') {
    return {outcome => 'not_applicable'};
  }

  my $protocol = $provenance->{protocol};
  my $origin   = $provenance->{origin};
  if (!_is_non_empty_string($protocol) || !_is_non_empty_string($origin)) {
    return {outcome => 'unverified'};
  }

  my $tally = _tally_records(
    $trusted_records,
    {
      protocol  => $protocol,
      origin    => $origin,
      pubkey    => $event->{pubkey},
      at        => $event->{created_at},
      separator => $separator,
    },
  );

  return {outcome => _outcome_from_tally($tally)};
}

sub _event_provenance {
  my ($event) = @_;
  if (!(ref $event eq 'HASH')) {
    return;
  }
  if (ref $event->{provenance} eq 'HASH') {
    return $event->{provenance};
  }
  my $content = _decode_content($event->{content});
  return ref $content eq 'HASH' ? $content->{provenance} : undef;
}

sub _record_body {
  my ($auth_record) = @_;
  if (!(ref $auth_record eq 'HASH')) {
    return;
  }
  if (ref $auth_record->{body} eq 'HASH') {
    return $auth_record->{body};
  }
  my $content = _decode_content($auth_record->{content});
  return ref $content eq 'HASH' ? $content->{body} : undef;
}

sub _decode_content {
  my ($content) = @_;
  if (!defined $content || ref $content) {
    return;
  }
  my $decoded;
  my $ok = eval { $decoded = $JSON->decode($content); 1 };
  return $ok ? $decoded : undef;
}

sub _tally_records {
  my ($records, $ctx) = @_;
  my %tally = (applicable => 0, in_effect => 0, lists_key => 0, excludes_key => 0);

  for my $auth_record (@{$records}) {
    my $body = _record_body($auth_record);
    if (!_record_applies($body, $ctx)) {
      next;
    }
    $tally{applicable}++;
    if (!_record_in_effect($body, $ctx)) {
      next;
    }
    $tally{in_effect}++;
    if (_body_lists_key($body, $ctx->{pubkey})) {
      $tally{lists_key}++;
    } else {
      $tally{excludes_key}++;
    }
  }

  return \%tally;
}

sub _record_applies {
  my ($body, $ctx) = @_;
  if (!(ref $body eq 'HASH')) {
    return 0;
  }
  if (!(_is_non_empty_string($body->{protocol}) && $body->{protocol} eq $ctx->{protocol})) {
    return 0;
  }
  if (!_is_non_empty_string($body->{origin})) {
    return 0;
  }
  return _origin_matches($body, $ctx->{origin}, $ctx->{separator});
}

sub _origin_matches {
  my ($body, $event_origin, $separator) = @_;
  my $record_origin = $body->{origin};
  if ($event_origin eq $record_origin) {
    return 1;
  }
  if (($body->{origin_match} // q{}) eq 'prefix') {
    return index($event_origin, $record_origin . $separator) == 0 ? 1 : 0;
  }
  return 0;
}

sub _record_in_effect {
  my ($body, $ctx) = @_;
  if (!_origin_match_well_formed($body)) {
    return 0;
  }
  if (!_pubkeys_well_formed($body->{pubkeys})) {
    return 0;
  }
  return _within_window($body, $ctx->{at});
}

sub _origin_match_well_formed {
  my ($body) = @_;
  if (!exists $body->{origin_match}) {
    return 1;
  }
  my $match = $body->{origin_match};
  return defined $match && !ref $match && ($match eq 'exact' || $match eq 'prefix') ? 1 : 0;
}

sub _pubkeys_well_formed {
  my ($pubkeys) = @_;
  if (!(ref $pubkeys eq 'ARRAY')) {
    return 0;
  }
  for my $pubkey (@{$pubkeys}) {
    if (ref $pubkey || !defined $pubkey || $pubkey !~ /\A[0-9a-f]{64}\z/mxs) {
      return 0;
    }
  }
  return 1;
}

sub _within_window {
  my ($body, $at) = @_;
  if (!defined $at) {
    return 1;
  }
  if (defined $body->{not_before} && _is_integer($body->{not_before}) && $at < $body->{not_before}) {
    return 0;
  }
  if (defined $body->{not_after} && _is_integer($body->{not_after}) && $at > $body->{not_after}) {
    return 0;
  }
  return 1;
}

sub _body_lists_key {
  my ($body, $pubkey) = @_;
  if (!(defined $pubkey && ref $body->{pubkeys} eq 'ARRAY')) {
    return 0;
  }
  for my $candidate (@{$body->{pubkeys}}) {
    if (defined $candidate && !ref $candidate && $candidate eq $pubkey) {
      return 1;
    }
  }
  return 0;
}

sub _outcome_from_tally {
  my ($tally) = @_;
  if ($tally->{applicable} == 0) {
    return 'unverified';
  }
  if ($tally->{in_effect} == 0) {
    return 'unresolvable';
  }
  if ($tally->{lists_key} && $tally->{excludes_key}) {
    return 'unresolvable';
  }
  return $tally->{lists_key} ? 'authoritative' : 'forged';
}

sub _is_non_empty_string {
  my ($value) = @_;
  return defined $value && !ref($value) && length($value) ? 1 : 0;
}

sub _is_integer {
  my ($value) = @_;
  return defined $value && !ref($value) && $value =~ /\A\d+\z/mxs ? 1 : 0;
}

1;

=head1 NAME

Overnet::Burner::Provenance - reference provenance verification oracle

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Provenance;

  my $result = Overnet::Burner::Provenance::verify_event($event, \@trusted_records);
  # $result->{outcome} is one of:
  #   authoritative, forged, unverified, unresolvable, not_applicable

=head1 DESCRIPTION

The reference implementation of the Overnet core provenance verification
operation (core specification section 7.9). Given an adapted event and a
consumer's trusted adapter authority records (section 6.15), it decides
whether the signing identity is authoritative for the external origin the
event claims.

It is the oracle the C<provenance_forger> abuse role verifies forged events
against: a correct verifier resolves a forged event to C<forged>, and
resolving it to C<authoritative> is the defense failure the experiment
measures. Like every burner reference module it implements a
language-neutral contract rather than defining it.

=head1 SUBROUTINES/METHODS

=head2 verify_event

Verifies one adapted event against an array reference of trusted authority
records and returns a hash reference whose C<outcome> is one of
C<authoritative>, C<forged>, C<unverified>, C<unresolvable>, or
C<not_applicable>. Events and records may be wire-style hashes carrying a
JSON C<content> string or hashes carrying a decoded C<provenance> or
C<body>. The optional C<origin_separator> controls prefix matching and
defaults to C<"/">.

=head1 DIAGNOSTICS

Results are returned as structured values; malformed trusted records are
treated as unresolvable rather than fatal.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

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
