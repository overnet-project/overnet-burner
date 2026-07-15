use strictures 2;

use FindBin;
use JSON ();
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Provenance ();

my $PK    = 'a' x 64;
my $OTHER = 'b' x 64;

sub _verify { return Overnet::Burner::Provenance::verify_event(@_) }

sub _event {
  my (%override) = @_;
  return {
    pubkey     => $PK,
    created_at => 1000,
    provenance => {type => 'adapted', protocol => 'irc', origin => 'irc.example/#chan'},
    %override,
  };
}

sub _record {
  my (%override) = @_;
  return {body => {protocol => 'irc', origin => 'irc.example/#chan', pubkeys => [$PK], %override}};
}

subtest 'non-adapted or malformed events are not applicable' => sub {
  is _verify('not-a-hash'), {outcome => 'not_applicable'}, 'a non-hash event is not applicable';
  is _verify(_event(provenance => {type => 'native'})), {outcome => 'not_applicable'},
    'a native event is not applicable';
  is _verify({pubkey => $PK}), {outcome => 'not_applicable'}, 'an event without provenance is not applicable';
};

subtest 'adapted events without a protocol or origin are unverified' => sub {
  is _verify(_event(provenance => {type => 'adapted', origin => 'x'})), {outcome => 'unverified'},
    'a missing protocol is unverified';
  is _verify(_event(provenance => {type => 'adapted', protocol => 'irc'})), {outcome => 'unverified'},
    'a missing origin is unverified';
};

subtest 'no applicable record leaves the event unverified' => sub {
  is _verify(_event, []), {outcome => 'unverified'}, 'no records means unverified';
  is _verify(_event, [_record(protocol => 'xmpp')]), {outcome => 'unverified'},
    'a record for another protocol does not apply';
  is _verify(_event, [_record(origin => 'irc.other/#chan')]), {outcome => 'unverified'},
    'a record for another origin does not apply';
  is _verify(_event, ['not-a-hash', {body => 'not-a-hash'}, {body => {protocol => 'irc'}}]),
    {outcome => 'unverified'}, 'malformed records are skipped';
};

subtest 'an authority record that lists the signer is authoritative' => sub {
  is _verify(_event, [_record()]), {outcome => 'authoritative'}, 'the listed signer is authoritative';
};

subtest 'an authority record that excludes the signer is forged' => sub {
  is _verify(_event, [_record(pubkeys => [$OTHER])]), {outcome => 'forged'},
    'a signer not on the list is forged';
};

subtest 'conflicting records are unresolvable' => sub {
  is _verify(_event, [_record(pubkeys => [$PK]), _record(pubkeys => [$OTHER])]),
    {outcome => 'unresolvable'}, 'a record listing and a record excluding the key conflict';
};

subtest 'a record that applies but is not in effect is unresolvable' => sub {
  is _verify(_event, [_record(origin_match => 'weird')]), {outcome => 'unresolvable'},
    'an unrecognized origin_match takes the record out of effect';
  is _verify(_event, [_record(pubkeys => ['too-short'])]), {outcome => 'unresolvable'},
    'malformed pubkeys take the record out of effect';
  is _verify(_event, [_record(pubkeys => 'not-an-array')]), {outcome => 'unresolvable'},
    'a non-array pubkeys field takes the record out of effect';
};

subtest 'prefix origin matching' => sub {
  my $event = _event(provenance => {type => 'adapted', protocol => 'irc', origin => 'irc.example/#chan'});
  is _verify($event, [_record(origin => 'irc.example', origin_match => 'prefix')]),
    {outcome => 'authoritative'}, 'a prefix record matches a sub-origin';
  is _verify($event, [_record(origin => 'irc.other', origin_match => 'prefix')]),
    {outcome => 'unverified'}, 'a prefix that is not a prefix does not apply';
};

subtest 'validity windows bound a record' => sub {
  is _verify(_event(created_at => 500), [_record(not_before => 1000)]), {outcome => 'unresolvable'},
    'a record not yet in force is out of effect';
  is _verify(_event(created_at => 5000), [_record(not_after => 1000)]), {outcome => 'unresolvable'},
    'an expired record is out of effect';
  is _verify(_event(created_at => 1500), [_record(not_before => 1000, not_after => 2000)]),
    {outcome => 'authoritative'}, 'a record within its window is in effect';
  is _verify({pubkey => $PK, provenance => {type => 'adapted', protocol => 'irc', origin => 'irc.example/#chan'}},
    [_record(not_before => 1000)]),
    {outcome => 'authoritative'}, 'a record with a window still applies to an event with no timestamp';
};

subtest 'provenance and records may be carried in JSON content' => sub {
  my $json  = JSON->new->utf8->canonical;
  my $event = {
    pubkey     => $PK,
    created_at => 1000,
    content    => $json->encode({provenance => {type => 'adapted', protocol => 'irc', origin => 'irc.example/#chan'}}),
  };
  my $record = {content => $json->encode({body => {protocol => 'irc', origin => 'irc.example/#chan', pubkeys => [$PK]}})};
  is _verify($event, [$record]), {outcome => 'authoritative'}, 'content-encoded provenance and record verify';

  is _verify({pubkey => $PK, content => 'not json'}), {outcome => 'not_applicable'},
    'content that is not JSON yields no provenance';
  is _verify({pubkey => $PK, content => $json->encode([1, 2, 3])}), {outcome => 'not_applicable'},
    'content that decodes to a non-object yields no provenance';
};

subtest 'the origin separator is configurable' => sub {
  my $event = _event(provenance => {type => 'adapted', protocol => 'irc', origin => 'irc.example:#chan'});
  is _verify($event, [_record(origin => 'irc.example', origin_match => 'prefix')], {origin_separator => ':'}),
    {outcome => 'authoritative'}, 'a custom separator drives prefix matching';
};

subtest 'a record with an empty origin does not apply' => sub {
  # An empty-string body origin must fail the non-empty-string guard: if it were
  # treated as a present origin it would prefix-match anything starting with the
  # separator and spuriously authorize the signer.
  my $event = _event(provenance => {type => 'adapted', protocol => 'irc', origin => '/#chan'});
  is _verify($event, [_record(origin => q{}, origin_match => 'prefix')]),
    {outcome => 'unverified'}, 'an empty record origin is not a valid non-empty string';
};

subtest 'a non-integer validity bound is ignored, not treated as zero' => sub {
  # A defined but non-integer not_after must fail the integer guard and be
  # skipped, leaving the record in effect; if it were accepted as an integer it
  # would numify to 0 and push every event past the bound.
  is _verify(_event(created_at => 1000), [_record(not_after => 'abc')]),
    {outcome => 'authoritative'}, 'a non-integer not_after does not bound the record';
};

subtest 'false-but-defined arguments fall back to their defaults' => sub {
  # options and trusted_records use ||= so a defined-but-false scalar is replaced
  # by the empty default rather than kept and dereferenced.
  is _verify(_event, [_record()], 0), {outcome => 'authoritative'},
    'a false options argument falls back to default options';
  is _verify(_event, 0), {outcome => 'unverified'},
    'a false trusted-records argument falls back to no records';
};

done_testing;
