use strictures 2;

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Overnet::Burner',
    VERSION          => '0.001',
    MIN_PERL_VERSION => '5.042000',
    EXE_FILES        => ['bin/overnet-burner'],
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
        'strictures'         => 2,
    },
    PREREQ_PM        => {
        'JSON'       => 0,
        'Rex'        => 0,
        'strictures' => 2,
        'YAML::PP'   => 0,
    },
);
