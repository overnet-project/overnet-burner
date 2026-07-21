package Overnet::Burner::Adversary::Profile;

use strictures 2;

use Carp qw(croak);

our $VERSION = '0.001';

# The adversary application-profile registry. A profile packages everything the
# adversary subsystem needs to know about one Overnet authority application: how
# to build a live arena bound to that application's authority, the seed-attack
# catalog written in that application's vocabulary, and the vocabulary itself.
# The generic engine (runner, oracle, session, drivers, recorded arena, fuzzer)
# stays application-neutral and takes a profile as input. The IRC hosted-channel
# authority is the reference profile and the default.
my %REGISTRY = (
  'irc-hosted-channel' => 'Overnet::Burner::Adversary::Profile::IrcHostedChannel',
  'document-vault'     => 'Overnet::Burner::Adversary::Profile::DocumentVault',
);
my $DEFAULT_PROFILE = 'irc-hosted-channel';

sub names {
  return [sort keys %REGISTRY];
}

sub default_name {
  return $DEFAULT_PROFILE;
}

sub default_profile {
  my ($class) = @_;
  return $class->resolve($DEFAULT_PROFILE);
}

sub resolve {
  my ($class, $name) = @_;

  if (!(defined $name && !ref($name) && length $name)) {
    $name = $DEFAULT_PROFILE;
  }
  my $module = $REGISTRY{$name};
  if (!$module) {
    croak "unknown adversary profile: $name\n";
  }
  (my $path = "$module.pm") =~ s{::}{/}gmsx;
  require $path;

  return $module;
}

1;

=head1 NAME

Overnet::Burner::Adversary::Profile - registry of adversary application profiles

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $profile = Overnet::Burner::Adversary::Profile->default_profile;
  my $catalog = $profile->attack_catalog;
  my $arena   = $profile->build_arena(seed => '1');

=head1 DESCRIPTION

Resolves adversary application profiles by name. A profile is the single seam
that makes the adversary subsystem application-neutral: it supplies the live
arena bound to one Overnet authority application, the seed-attack catalog in
that application's vocabulary, and the vocabulary metadata a fuzzer needs. The
generic engine judges any profile's sessions the same way.

A profile is a class providing C<name>, C<build_arena>, C<attack_catalog>, and
C<vocabulary>. The reference profile is C<irc-hosted-channel>, which is also the
default; C<document-vault> is a second, deliberately non-IRC profile that proves
the subsystem is application-neutral. New applications register their own profile
class.

=head1 SUBROUTINES/METHODS

=head2 names

Returns the sorted list of registered profile names.

=head2 default_name

Returns the name of the default profile.

=head2 default_profile

Resolves and returns the default profile class.

=head2 resolve

Resolves a profile name to its class, loading the class. An undefined or empty
name resolves the default. Dies on an unregistered name.

=head1 DIAGNOSTICS

An unregistered profile name is reported with C<croak>.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires the resolved profile class to be loadable.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
