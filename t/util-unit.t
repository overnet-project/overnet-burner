use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Util
  qw(checked_close checked_print clone_json json_text read_file read_json_file read_jsonl_file write_file);

my $tmp = tempdir(CLEANUP => 1);

subtest 'json_text renders canonical, pretty JSON' => sub {
  my $text = json_text({b => 2, a => 1});
  like $text, qr/"a":\ 1/mx, 'values are rendered';
  ok index($text, '"a"') < index($text, '"b"'), 'keys are sorted canonically';
  like $text, qr/\n/mx, 'the output is pretty printed across lines';
};

subtest 'clone_json deep-copies through JSON' => sub {
  my $original = {list => [1, 2, {nested => 'deep'}]};
  my $clone    = clone_json($original);
  is $clone, $original, 'the clone equals the original';
  $clone->{list}[2]{nested} = 'changed';
  is $original->{list}[2]{nested}, 'deep', 'mutating the clone does not touch the original';
};

subtest 'write_file and read_file round trip' => sub {
  my $path = File::Spec->catfile($tmp, 'round-trip.txt');
  is write_file($path, "hello\nworld\n"), 1, 'write_file reports success';
  is read_file($path), "hello\nworld\n", 'read_file returns the whole file';
};

subtest 'read_json_file parses a JSON document' => sub {
  my $path = File::Spec->catfile($tmp, 'doc.json');
  write_file($path, '{"role":"observer","n":3}');
  is read_json_file($path), {role => 'observer', n => 3}, 'the document is decoded';
};

subtest 'read_jsonl_file parses records and tolerates a missing file' => sub {
  my $path = File::Spec->catfile($tmp, 'stream.jsonl');
  write_file($path, qq({"a":1}\n{"a":2}\n));
  is read_jsonl_file($path), [{a => 1}, {a => 2}], 'each line is decoded to a record';
  is read_jsonl_file(File::Spec->catfile($tmp, 'absent.jsonl')), [], 'a missing stream is an empty list';
};

subtest 'read_file and write_file report open failures' => sub {
  like dies { read_file(File::Spec->catfile($tmp, 'no-such-file')) }, qr/open\ /mx,
    'reading a missing file croaks';
  like dies { write_file(File::Spec->catfile($tmp, 'no-dir', 'x'), 'y') }, qr/open\ /mx,
    'writing under a missing directory croaks';
};

subtest 'checked_print and checked_close report write failures' => sub {
  SKIP: {
    skip 'no writable /dev/full on this platform', 2 if !-w '/dev/full';

    open my $immediate, '>', '/dev/full' or skip 'cannot open /dev/full', 2;
    $immediate->autoflush(1);
    like dies { checked_print($immediate, 'x' x 65_536) }, qr/print\ failed/mx,
      'a write that fails croaks';
    close $immediate;    # already failed; ignore the result

    open my $buffered, '>', '/dev/full' or skip 'cannot open /dev/full', 1;
    print {$buffered} 'x' x 65_536;
    like dies { checked_close($buffered, '/dev/full') }, qr/close\ failed/mx,
      'a close that fails to flush croaks';
  }
};

done_testing;
