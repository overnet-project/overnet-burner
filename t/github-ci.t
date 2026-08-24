use strictures 2;

use English qw(-no_match_vars);
use File::Spec;
use FindBin;
use Test2::V0;

my $repo_root = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $workflow  = File::Spec->catfile($repo_root, '.github', 'workflows', 'test.yml');
my $mutation  = File::Spec->catfile($repo_root, '.github', 'workflows', 'mutation.yml');

ok -f $workflow, 'GitHub Actions test workflow exists'
  or bail_out('test workflow is required');
ok -f $mutation, 'GitHub Actions mutation workflow exists'
  or bail_out('mutation workflow is required');

my $content = _read_file($workflow);
like $content, qr/perl:\s*\['5\.40',\s*'latest'\]/mxs,    'workflow tests Perl 5.40 and latest';
like $content, qr/shogo82148\/actions-setup-perl\@v1/mxs, 'workflow installs Perl with the project action';
like $content, qr/cpanm\b[^\n]*--installdeps\s+\./mxs,    'workflow installs repository dependencies';
is scalar(() = $content =~ /echo\s+"\$HOME\/perl5\/bin"\s+>>\s+"\$GITHUB_PATH"/gms), 5,
  'every workflow job adds local-lib scripts to PATH';
like $content, qr{cpanm\b[^\n]*\./overnet-perl-style}mxs,
  'workflow installs shared Overnet Perl style policies from the monorepo';
like $content, qr/prove\s+-r\s+-l\s+-v\s+t\//mxs,          'workflow runs normal tests';
like $content, qr/prove\s+-r\s+-l\s+-v\s+xt\/author\//mxs, 'workflow runs author tests';
like $content, qr/-\s+'README[.]md'/mxs,                   'workflow runs when README changes';
like $content, qr{-\s+'docs/[*][*]'}mxs,                   'workflow runs when documentation changes';
like $content, qr{-\s+'profile-templates/[*][*]'}mxs,      'workflow runs when profile templates change';
like $content, qr{-\s+'schemas/[*][*]'}mxs,                'workflow runs when schemas change';
like $content, qr/-\s+'MANIFEST'/mxs,                      'workflow runs when MANIFEST changes';
is scalar(() = $content =~ /^\s+path:\s+overnet-burner\s*$/gms), 5,
  'every workflow job checks out this repo in the sibling checkout layout';
is scalar(() = $content =~ /repository:\s+overnet-project\/overnet-perl\b/gms), 5,
  'every workflow job checks out the Perl monorepo';
unlike $content, qr/repository:\s+overnet-project\/(?:core-perl|relay-perl|overnet-perl-style)\b/mxs,
  'workflow does not check out archived component repositories';
is scalar(() = $content =~ m{
  cpanm\s+--local-lib\s+~/perl5\s+--notest\s+--reinstall\s+
  Net::Nostr::Core\s+Net::Nostr::Client\s+Net::Nostr::Relay
}gmx), 5, 'every workflow job refreshes the split Net::Nostr distributions together';
like $content, qr/adversary-regression:/mxs,                'workflow has a dedicated adversary regression job';
like $content, qr/prove\s+-r\s+-l\s+-v\s+t\/adversary-/mxs, 'the regression job replays the adversary catalog';
like $content, qr/coverage:/mxs,                            'workflow has a dedicated adversary coverage job';
like $content, qr/OVERNET_COVERAGE:\s*'1'/mxs,              'the coverage job enables the coverage gate';
like $content, qr/managed-local-containers-smoke:/mxs, 'workflow has a dedicated managed local-containers smoke job';
like $content,
qr/bin\/overnet-burner\s+run\s+\\\s+--scenario\s+scenarios\/local-containers-smoke[.]yml\s+\\\s+--runs-dir\s+runs\s+\\\s+--run-id\s+ci-local-containers-smoke\s+\\\s+--runner\s+rex-local-workers/mxs,
  'workflow runs the managed local-containers smoke scenario once';

my $mutation_content = _read_file($mutation);
like $mutation_content, qr/repository:\s+overnet-project\/overnet-perl\b/mxs,
  'mutation workflow checks out the Perl monorepo';
like $mutation_content, qr/^\s+path:\s+overnet-burner\s*$/mxs,
  'mutation workflow checks out this repo beside the monorepo components';
unlike $mutation_content,
  qr/repository:\s+overnet-project\/(?:core-perl|relay-perl|overnet-perl-style)\b/mxs,
  'mutation workflow does not check out archived component repositories';
like $mutation_content, qr{cpanm\b[^\n]*\./overnet-perl-style}mxs,
  'mutation workflow installs style policies from the monorepo';
like $mutation_content, qr{
  cpanm\s+--local-lib\s+~/perl5\s+--notest\s+--reinstall\s+
  Net::Nostr::Core\s+Net::Nostr::Client\s+Net::Nostr::Relay
}mx, 'mutation workflow refreshes the split Net::Nostr distributions together';

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
