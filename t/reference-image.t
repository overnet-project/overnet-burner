use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use File::Path qw(make_path);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::ReferenceImage;

my $tmp     = tempdir(CLEANUP => 1);
my $context = File::Spec->catdir($tmp, 'reference');

Overnet::Burner::ReferenceImage->write_context($context);
# A second write over an existing context removes the stale tree first.
Overnet::Burner::ReferenceImage->write_context($context);

my $dockerfile = _slurp(File::Spec->catfile($context, 'Dockerfile'));
like $dockerfile, qr/\bJSON::Schema::Modern\b/,        'the reference image installs core runtime schema dependency';
like $dockerfile, qr/\bAnyEvent::WebSocket::Client\b/, 'the reference image installs websocket client dependency';
like $dockerfile, qr/\bNet::Nostr\b/,                  'the reference image installs the Nostr client dependency';
ok -f File::Spec->catfile($context, 'relay-perl', 'bin', 'overnet-relay.pl'),
  'the reference image context includes the relay executable';
ok -f File::Spec->catfile($context, 'overnet-burner', 'bin', 'overnet-burner'),
  'the reference image context includes the burner executable';

subtest 'ensure writes the context and builds the tagged image' => sub {
  my $run_dir = tempdir(CLEANUP => 1);
  my $engine  = _FakeEngine->new;
  my $tag     = Overnet::Burner::ReferenceImage->ensure(engine => $engine, run_dir => $run_dir, tag => 'burner:test');
  is $tag, 'burner:test', 'ensure returns the tag';
  is $engine->{built}{tag}, 'burner:test', 'the engine was asked to build the tag';
  ok -f File::Spec->catfile($engine->{built}{context}, 'Dockerfile'), 'ensure wrote a build context with a Dockerfile';

  like dies { Overnet::Burner::ReferenceImage->ensure(run_dir => $run_dir, tag => 't') }, qr/engine\ is\ required/mx,
    'ensure requires an engine';
  like dies { Overnet::Burner::ReferenceImage->ensure(engine => $engine, tag => 't') }, qr/run_dir\ is\ required/mx,
    'ensure requires a run_dir';
  like dies { Overnet::Burner::ReferenceImage->ensure(engine => $engine, run_dir => $run_dir) }, qr/tag\ is\ required/mx,
    'ensure requires a tag';
};

subtest 'the copy helper skips .git and rejects a missing source' => sub {
  my $from = File::Spec->catdir($tmp, 'src');
  make_path(File::Spec->catdir($from, '.git'), File::Spec->catdir($from, 'lib'));
  _spew(File::Spec->catfile($from, '.git', 'config'), "gitdata\n");
  _spew(File::Spec->catfile($from, 'lib', 'keep.pm'), "1;\n");
  my $to = File::Spec->catdir($tmp, 'dest');

  Overnet::Burner::ReferenceImage::_copy_tree($from, $to);
  ok -f File::Spec->catfile($to, 'lib', 'keep.pm'), 'ordinary files are copied';
  ok !-e File::Spec->catdir($to, '.git'), 'the .git directory is skipped';

  like dies { Overnet::Burner::ReferenceImage::_copy_tree(File::Spec->catdir($tmp, 'absent'), $to) },
    qr/source\ directory\ does\ not\ exist/mx, 'a missing source directory is fatal';
};

done_testing;

sub _spew {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content or die "print: $!";
  close $fh or die "close: $!";
  return;
}

package _FakeEngine;
sub new { return bless {}, shift }
sub build_image { my ($self, %args) = @_; $self->{built} = \%args; return 1 }

package main;

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "open $path: $!";
  my $content = do { local $/; <$fh> };
  close $fh or die "close $path: $!";
  return $content;
}
