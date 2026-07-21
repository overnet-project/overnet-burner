package Overnet::Burner::Adversary::Profile::DocumentVault;

use strictures 2;

use Overnet::Burner::Adversary::Arena::DocumentVault;

our $VERSION = '0.001';

sub name {
  return 'document-vault';
}

sub build_arena {
  my ($class, %params) = @_;
  return Overnet::Burner::Adversary::Arena::DocumentVault->new(%params);
}

# The application vocabulary a fuzzer or mutator needs to generate variants that
# stay within this authority's model.
sub vocabulary {
  return {
    capabilities => ['vault.writer'],
    scopes       => ['vault:reports'],
    grant_kinds  => [30_000],
    action_types => [qw(new_identity publish_grant observe_capability)],
  };
}

# The seed-attack catalog in the document-vault vocabulary, in the same shape the
# reference IRC profile uses: each entry is pinned to the oracle invariant it
# exercises and carries the harness's independent ground truth, the action
# sequence a driver submits, and the defended and exploited transcripts a
# spec-conformant versus a vulnerable authority would expose.
sub attack_catalog {
  return {
    forged_writer_grant => {
      description      => 'A non-owner forges a writer delegation to grant itself write access to a vault scope.',
      target_invariant => 'authorization',
      ground_truth     => {
        authorized_capabilities => [{subject => 'writer', capability => 'vault.writer', scope => 'vault:reports'}],
      },
      actions => [
        {type => 'new_identity',       payload => {name    => 'attacker'}},
        {type => 'publish_grant',      payload => {actor   => 'attacker', delegate => 'attacker'}},
        {type => 'observe_capability', payload => {subject => 'attacker', scope    => 'vault:reports'}},
      ],
      defended => [
        {type => 'relay_outcome', payload => {accepted => 0, reason => 'grant not signed by the scope owner'}},
        {
          type    => 'observed_capability',
          payload => {subject => 'writer', capability => 'vault.writer', scope => 'vault:reports'},
        },
      ],
      exploited => [
        {type => 'relay_outcome', payload => {accepted => 1}},
        {
          type    => 'observed_capability',
          payload => {subject => 'attacker', capability => 'vault.writer', scope => 'vault:reports'},
        },
      ],
    },
  };
}

1;

=head1 NAME

Overnet::Burner::Adversary::Profile::DocumentVault - a non-IRC adversary application profile

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $profile = Overnet::Burner::Adversary::Profile->resolve('document-vault');
  my $arena   = $profile->build_arena(seed => '1');
  my $catalog = $profile->attack_catalog;

=head1 DESCRIPTION

A second adversary application profile, deliberately unrelated to IRC: a
I<document-vault> authority in which a document scope has a single owner and only
the owner may delegate write access. It packages the live arena that drives that
authority (L<Overnet::Burner::Adversary::Arena::DocumentVault>), the seed-attack
catalog in its owner/writer vocabulary, and that vocabulary.

Its purpose is the neutrality proof for the adversary subsystem: selecting this
profile drives a non-IRC authority through the same generic runner, oracle,
session, and server that the reference IRC profile uses, judged by the same
built-in invariants - demonstrating the subsystem is application-neutral rather
than IRC-specific. See L<Overnet::Burner::Adversary::Profile>.

=head1 SUBROUTINES/METHODS

=head2 name

Returns C<document-vault>.

=head2 build_arena

Builds a live arena bound to the document-vault authority. Passes its arguments
through to L<Overnet::Burner::Adversary::Arena::DocumentVault>.

=head2 vocabulary

Returns the application vocabulary (capabilities, scopes, grant kinds, and action
types) a fuzzer needs to generate in-model variants.

=head2 attack_catalog

Returns the seed-attack catalog: a mapping of attack name to an entry carrying a
description, target invariant, ground truth, action sequence, and the defended
and exploited transcripts.

=head1 DIAGNOSTICS

No diagnostics are emitted directly.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Overnet::Burner::Adversary::Arena::DocumentVault>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
