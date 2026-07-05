use strict;
use warnings;

use ExtUtils::MakeMaker;

our $VERSION = '0.001';

WriteMakefile(
  NAME               => 'Overnet::Burner',
  VERSION            => $VERSION,
  AUTHOR             => 'Nicholas B. Hubbard <nicholashubbard@posteo.net>',
  ABSTRACT           => 'Rex-based scalable Overnet system-test harness',
  LICENSE            => 'gpl_3',
  MIN_PERL_VERSION   => '5.040',
  EXE_FILES          => ['bin/overnet-burner', 'bin/overnet-burner-worker'],
  CONFIGURE_REQUIRES => {
    'ExtUtils::MakeMaker' => 0,
  },
  PREREQ_PM => {
    'JSON'       => 0,
    'Moo'        => 0,
    'Net::Nostr' => 0,
    'Rex'        => 0,
    'strictures' => 2,
    'YAML::PP'   => 0,
  },
  TEST_REQUIRES => {
    'JSON::Schema::Modern' => 0,
  },
  META_MERGE => {
    resources => {
      repository => 'https://github.com/overnet-project/overnet-burner',
      bugtracker => 'https://github.com/overnet-project/overnet-burner/issues',
    },
  },
);
