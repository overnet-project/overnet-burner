use strictures 2;

use English qw(-no_match_vars);
use File::Spec;
use FindBin;
use Test2::V0;

my $repo_root = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $workflow  = File::Spec->catfile($repo_root, '.github', 'workflows', 'test.yml');

ok -f $workflow, 'GitHub Actions test workflow exists'
  or bail_out('test workflow is required');

my $content = _read_file($workflow);
like $content, qr/perl:\s*\['5\.40',\s*'latest'\]/mxs,     'workflow tests Perl 5.40 and latest';
like $content, qr/shogo82148\/actions-setup-perl\@v1/mxs,  'workflow installs Perl with the project action';
like $content, qr/cpanm\b[^\n]*--installdeps\s+\./mxs,     'workflow installs repository dependencies';
like $content, qr/overnet-project\/overnet-perl-style/mxs, 'workflow installs shared Overnet Perl style policies';
like $content, qr/prove\s+-r\s+-l\s+-v\s+t\//mxs,          'workflow runs normal tests';
like $content, qr/prove\s+-r\s+-l\s+-v\s+xt\/author\//mxs, 'workflow runs author tests';

done_testing;

sub _read_file {
  my ($path) = @_;
  open my $fh, '<', $path
    or die "open $path: $!";
  my $content = do { local $INPUT_RECORD_SEPARATOR = undef; <$fh> };
  close $fh
    or die "close $path: $!";
  return $content;
}
