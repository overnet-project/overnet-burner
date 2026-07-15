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
like $content, qr/perl:\s*\['5\.40',\s*'latest'\]/mxs,    'workflow tests Perl 5.40 and latest';
like $content, qr/shogo82148\/actions-setup-perl\@v1/mxs, 'workflow installs Perl with the project action';
like $content, qr/cpanm\b[^\n]*--installdeps\s+\./mxs,    'workflow installs repository dependencies';
is scalar(() = $content =~ /echo\s+"\$HOME\/perl5\/bin"\s+>>\s+"\$GITHUB_PATH"/gms), 5,
  'every workflow job adds local-lib scripts to PATH';
like $content, qr/overnet-project\/overnet-perl-style/mxs, 'workflow installs shared Overnet Perl style policies';
like $content, qr/prove\s+-r\s+-l\s+-v\s+t\//mxs,          'workflow runs normal tests';
like $content, qr/prove\s+-r\s+-l\s+-v\s+xt\/author\//mxs, 'workflow runs author tests';
like $content, qr/-\s+'README[.]md'/mxs,                   'workflow runs when README changes';
like $content, qr{-\s+'docs/[*][*]'}mxs,                   'workflow runs when documentation changes';
like $content, qr{-\s+'profile-templates/[*][*]'}mxs,      'workflow runs when profile templates change';
like $content, qr{-\s+'schemas/[*][*]'}mxs,                'workflow runs when schemas change';
like $content, qr/-\s+'MANIFEST'/mxs,                      'workflow runs when MANIFEST changes';
is scalar(() = $content =~ /^\s+path:\s+overnet-burner\s*$/gms), 5,
  'every workflow job checks out this repo in the sibling checkout layout';
like $content, qr/repository:\s+overnet-project\/core-perl\b[\s\S]*?path:\s+core-perl/mxs,
  'workflow checks out core-perl as a sibling';
like $content, qr/repository:\s+overnet-project\/relay-perl\b[\s\S]*?path:\s+relay-perl/mxs,
  'workflow checks out relay-perl as a sibling';
is scalar(() = $content =~ /repository:\s+overnet-project\/core-perl\b/gms), 5,
  'every workflow job checks out core-perl';
is scalar(() = $content =~ /repository:\s+overnet-project\/relay-perl\b/gms), 5,
  'every workflow job checks out relay-perl';
like $content, qr/adversary-regression:/mxs,                'workflow has a dedicated adversary regression job';
like $content, qr/prove\s+-r\s+-l\s+-v\s+t\/adversary-/mxs, 'the regression job replays the adversary catalog';
like $content, qr/coverage:/mxs,                            'workflow has a dedicated adversary coverage job';
like $content, qr/OVERNET_COVERAGE:\s*'1'/mxs,              'the coverage job enables the coverage gate';
like $content, qr/managed-local-containers-smoke:/mxs, 'workflow has a dedicated managed local-containers smoke job';
like $content,
qr/bin\/overnet-burner\s+run\s+\\\s+--scenario\s+scenarios\/local-containers-smoke[.]yml\s+\\\s+--runs-dir\s+runs\s+\\\s+--run-id\s+ci-local-containers-smoke\s+\\\s+--runner\s+rex-local-workers/mxs,
  'workflow runs the managed local-containers smoke scenario once';

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
