use strict;
use warnings;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Overnet::Burner',
    VERSION          => '0.001',
    MIN_PERL_VERSION => '5.042000',
    EXE_FILES        => ['bin/overnet-burner'],
    PREREQ_PM        => {
        'JSON::PP' => 0,
        'YAML::PP' => 0,
    },
);
