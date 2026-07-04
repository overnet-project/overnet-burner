use strictures 2;

use Cwd     qw(getcwd);
use English qw(-no_match_vars);
use File::Spec;
use FindBin;
use Test2::V0;

my $repo_root   = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $makefile_pl = File::Spec->catfile($repo_root, 'Makefile.PL');
my $license     = File::Spec->catfile($repo_root, 'LICENSE');

ok -f $makefile_pl, 'Makefile.PL exists'
  or bail_out('Makefile.PL is required');
ok -f $license, 'LICENSE exists';

my $args = _capture_makefile_args($makefile_pl);
is $args->{NAME},             'Overnet::Burner',                                  'distribution name';
is $args->{VERSION},          '0.001',                                            'distribution version';
is $args->{AUTHOR},           'Nicholas B. Hubbard <nicholashubbard@posteo.net>', 'author';
is $args->{ABSTRACT},         'Rex-based scalable Overnet system-test harness',   'abstract';
is $args->{LICENSE},          'gpl_3',                                            'license';
is $args->{MIN_PERL_VERSION}, '5.040',                                            'minimum Perl version';
is $args->{EXE_FILES}, ['bin/overnet-burner', 'bin/overnet-burner-worker'],
  'installable CLIs are explicit';
is(
  $args->{CONFIGURE_REQUIRES},
  {
    'ExtUtils::MakeMaker' => 0,
    'strictures'          => 2,
  },
  'configure prerequisites are explicit',
);
is(
  $args->{PREREQ_PM},
  {
    'JSON'       => 0,
    'Moo'        => 0,
    'Net::Nostr' => 0,
    'Rex'        => 0,
    'strictures' => 2,
    'YAML::PP'   => 0,
  },
  'runtime prerequisites are explicit',
);
is(
  $args->{TEST_REQUIRES},
  {
    'JSON::Schema::Modern' => 0,
  },
  'test prerequisites are explicit',
);
is(
  $args->{META_MERGE},
  {
    resources => {
      repository => 'https://github.com/overnet-project/overnet-burner',
      bugtracker => 'https://github.com/overnet-project/overnet-burner/issues',
    },
  },
  'metadata resources point at the public repo',
);

done_testing;

sub _capture_makefile_args {
  my ($path) = @_;
  my $args;
  my $cwd = getcwd();
  my ($volume, $dirs) = File::Spec->splitpath($path);
  my $root = File::Spec->catpath($volume, $dirs, q{});
  $root =~ s{/$}{}mxs;

  {
    require ExtUtils::MakeMaker;

    no warnings qw(redefine once);
    local *ExtUtils::MakeMaker::WriteMakefile = sub {
      $args = {@_};
      return 1;
    };
    local *main::WriteMakefile = \&ExtUtils::MakeMaker::WriteMakefile;

    chdir $root
      or die "unable to chdir to $root: $!";
    my $rv    = do $path;
    my $error = $@;
    chdir $cwd
      or die "unable to restore cwd to $cwd: $!";

    die $error
      if $error;
    die "unable to load $path: $!"
      if !defined $rv;
  }

  return $args;
}
