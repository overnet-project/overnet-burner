use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::ReferenceImage;

my $tmp     = tempdir(CLEANUP => 1);
my $context = File::Spec->catdir($tmp, 'reference');

Overnet::Burner::ReferenceImage->write_context($context);

my $dockerfile = _slurp(File::Spec->catfile($context, 'Dockerfile'));
like $dockerfile, qr/\bJSON::Schema::Modern\b/,        'the reference image installs core runtime schema dependency';
like $dockerfile, qr/\bAnyEvent::WebSocket::Client\b/, 'the reference image installs websocket client dependency';
like $dockerfile, qr/\bNet::Nostr\b/,                  'the reference image installs the Nostr client dependency';
ok -f File::Spec->catfile($context, 'relay-perl', 'bin', 'overnet-relay.pl'),
  'the reference image context includes the relay executable';
ok -f File::Spec->catfile($context, 'overnet-burner', 'bin', 'overnet-burner'),
  'the reference image context includes the burner executable';

done_testing;

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return $content;
}
