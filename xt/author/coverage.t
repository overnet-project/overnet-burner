use strictures 2;

use Config;
use Cwd            qw(abs_path);
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

# Coverage collection is slow and needs Devel::Cover, so it is opt-in: it runs
# only when OVERNET_COVERAGE is set (the coverage CI job sets it). A normal
# `prove xt/author/` run skips it.
if (!$ENV{OVERNET_COVERAGE}) {
  plan skip_all => 'set OVERNET_COVERAGE=1 to run the adversary coverage gate';
}
if (!eval { require Devel::Cover; 1 }) {
  plan skip_all => 'Devel::Cover is not installed';
}

my $ROOT  = abs_path("$FindBin::Bin/../..");
my $PERL  = $^X;
my $PROVE = _tool('prove');
my $COVER = _tool('cover');

# Per-file thresholds for the security-critical adversary namespace. Every
# subroutine must be exercised, statements must be almost fully covered, and no
# file may have catastrophically untested branching.
my %MIN = (subroutine => 100, statement => 90, branch => 60);

chdir $ROOT or die "chdir $ROOT: $!";

my $db   = File::Spec->catdir(tempdir(CLEANUP => 1), 'cover_db');
my @libs = grep {-d} (
  File::Spec->catdir($ROOT, 'lib'),
  File::Spec->catdir($ROOT, File::Spec->updir, 'relay-perl', 'lib'),
  File::Spec->catdir($ROOT, File::Spec->updir, 'core-perl',  'lib'),
);

my @tests = sort glob 't/adversary-*.t';
ok scalar(@tests), 'found adversary test files to cover' or bail_out('no adversary tests');

{
  # Collect every criterion; restricting collection to a subset skews branch
  # data. The report step below is what filters to the metrics we gate on.
  local $ENV{HARNESS_PERL_SWITCHES} = "-MDevel::Cover=-db,$db,-silent,1";
  local $ENV{PERL5LIB}              = join $Config::Config{path_sep} // ':', @libs, ($ENV{PERL5LIB} // ());
  my $status = system $PERL, $PROVE, '-Ilib', @tests;
  is $status, 0, 'the adversary suite passes under coverage instrumentation';
}

my %coverage = _parse_coverage($db);
ok scalar(keys %coverage), 'coverage was collected for the adversary namespace'
  or bail_out('no adversary coverage rows were produced');

for my $file (sort keys %coverage) {
  for my $metric (sort keys %MIN) {
    my $got = $coverage{$file}{$metric};
    ok defined($got) && $got >= $MIN{$metric}, "$file: $metric coverage $got% >= $MIN{$metric}%"
      or diag "coverage shortfall in $file for $metric";
  }
}

done_testing;

sub _tool {
  my ($name) = @_;
  my $beside = File::Spec->catfile(dirname($PERL), $name);
  return -x $beside ? $beside : $name;
}

sub _parse_coverage {
  my ($cover_db) = @_;
  my @rows = qx{$COVER -summary -coverage statement,branch,subroutine $cover_db 2>/dev/null};

  my %seen;
  for my $row (@rows) {

    # Columns: File stmt bran sub total - only the adversary lib modules matter.
    my ($file, $stmt, $bran, $sub) =
      $row =~ m{\A(lib/Overnet/Burner/Adversary/\S+)\s+([\d.]+|n/a)\s+([\d.]+|n/a)\s+([\d.]+|n/a)}mxs;
    next if !defined $file;
    $seen{$file} = {
      statement  => _number($stmt),
      branch     => _number($bran),
      subroutine => _number($sub),
    };
  }
  return %seen;
}

sub _number {
  my ($value) = @_;

  # A file with no branches reports n/a for branch; treat that as fully covered.
  return $value eq 'n/a' ? 100 : $value;
}
