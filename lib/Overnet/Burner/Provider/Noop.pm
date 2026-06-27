package Overnet::Burner::Provider::Noop;

use strict;
use warnings;

use parent 'Overnet::Burner::Provider';

sub prepare { return 1 }
sub start   { return 1 }
sub observe { return 1 }
sub stop    { return 1 }
sub collect { return 1 }

1;
