use strictures 2;

use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Provenance;

my $ADAPTER = 'a1b2c3d4' x 8;
my $FORGER  = 'f0' x 32;
my $OTHER   = 'c0' x 32;

sub adapted_event {
  my (%args) = @_;
  return {
    pubkey     => $args{pubkey},
    created_at => $args{created_at} // 1_744_300_860,
    provenance => {
      type     => 'adapted',
      protocol => $args{protocol} // 'irc',
      origin   => $args{origin}   // 'irc.libera.chat/#overnet',
    },
  };
}

sub authority_record {
  my (%args) = @_;
  return {body => {protocol => 'irc', origin => 'irc.libera.chat', origin_match => 'prefix', %args}};
}

sub outcome {
  my ($event, $records, $options) = @_;
  return Overnet::Burner::Provenance::verify_event($event, $records, $options)->{outcome};
}

is outcome({pubkey => $ADAPTER, provenance => {type => 'native'}}, []), 'not_applicable',
  'native provenance is not applicable';

is outcome(adapted_event(pubkey => $FORGER), []), 'unverified', 'no records yields unverified';

is outcome(adapted_event(pubkey => $ADAPTER), [authority_record(pubkeys => [$ADAPTER])]), 'authoritative',
  'a listed pubkey is authoritative';

is outcome(adapted_event(pubkey => $FORGER), [authority_record(pubkeys => [$ADAPTER])]), 'forged',
  'an unlisted pubkey is forged';

is outcome(adapted_event(pubkey => $ADAPTER), [authority_record(pubkeys => [])]), 'forged',
  'an empty pubkey list forges every key';

is outcome(
  adapted_event(pubkey => $ADAPTER, origin => 'irc.libera.chatnet/#x'),
  [authority_record(pubkeys => [$ADAPTER])],
  ),
  'unverified', 'prefix matching respects the separator boundary';

is outcome(adapted_event(pubkey => $ADAPTER), [authority_record(not_after => 1_744_200_000, pubkeys => [$ADAPTER])],),
  'unresolvable', 'an out-of-window record is unresolvable';

is outcome(
  adapted_event(pubkey => $ADAPTER),
  [authority_record(pubkeys => [$ADAPTER]), authority_record(pubkeys => [$OTHER])],
  ),
  'unresolvable', 'conflicting records are unresolvable';

done_testing;
