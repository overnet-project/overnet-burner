package Overnet::Burner::Adversary::Profile::IrcHostedChannel;

use strictures 2;

use Overnet::Burner::Adversary::Arena::Live;

our $VERSION = '0.001';

sub name {
  return 'irc-hosted-channel';
}

sub build_arena {
  my ($class, %params) = @_;
  return Overnet::Burner::Adversary::Arena::Live->new(%params);
}

# The application vocabulary a fuzzer or mutator needs to generate variants that
# stay in this application's authority model.
sub vocabulary {
  return {
    capabilities => ['irc.operator'],
    scopes       => ['channel:#ops'],
    grant_kinds  => [9000, 39_001],
    action_types => [qw(new_identity forge_delegation publish_control publish_snapshot join)],
  };
}

# The seed-attack catalog: driver-neutral adversary scenarios, each pinned to
# the oracle invariant it exercises. Every entry carries the harness's
# independent ground truth, the action sequence a driver would submit, and two
# illustrative system-under-test transcripts - the observations a defended
# (spec-conformant) system exposes versus those a vulnerable one exposes. The
# transcripts make each attack a self-contained regression scenario until an
# arena replays the actions against a live system under test.
sub attack_catalog {
  return {
    forged_grant_escalation => {
      description      => 'A nobody forges a session delegation and grants itself operator (core C1).',
      target_invariant => 'authorization',
      ground_truth     => {
        authorized_capabilities => [{subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'}]
      },
      actions => [
        {type => 'new_identity', payload => {identity => 'attacker-pk'}},
        {
          type    => 'forge_delegation',
          payload => {actor => 'attacker-pk', delegate => 'attacker-session', authority => 'forged-grant'},
        },
        {
          type    => 'publish_control',
          payload => {kind => 9000, signer => 'attacker-session', actor => 'attacker-pk', role => 'irc.operator'},
        },
      ],
      defended => [
        {type => 'relay_outcome', payload => {accepted => 0, reason => 'unauthorized'}},
        {
          type    => 'observed_capability',
          payload => {subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'}
        },
      ],
      exploited => [
        {type => 'relay_outcome', payload => {accepted => 1}},
        {
          type    => 'observed_capability',
          payload => {subject => 'attacker-pk', capability => 'irc.operator', scope => 'channel:#ops'},
        },
      ],
    },

    forged_snapshot_self_grant => {
      description      => 'A non-authoritative signer publishes a role snapshot naming itself operator (core C2).',
      target_invariant => 'authorization',
      ground_truth     => {
        authorized_capabilities => [{subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'}]
      },
      actions => [
        {type => 'new_identity', payload => {identity => 'attacker-pk'}},
        {
          type    => 'publish_snapshot',
          payload =>
            {kind => 39_001, signer => 'attacker-pk', grants => [{subject => 'attacker-pk', role => 'irc.operator'}]},
        },
      ],
      defended => [
        {type => 'relay_outcome', payload => {accepted => 0, reason => 'unauthorized'}},
        {
          type    => 'observed_capability',
          payload => {subject => 'operator-pk', capability => 'irc.operator', scope => 'channel:#ops'}
        },
      ],
      exploited => [
        {type => 'relay_outcome', payload => {accepted => 1}},
        {
          type    => 'observed_capability',
          payload => {subject => 'attacker-pk', capability => 'irc.operator', scope => 'channel:#ops'},
        },
      ],
    },

    ban_mask_evasion => {
      description      => 'A banned subject joins while omitting or spoofing the mask the ban matches.',
      target_invariant => 'admission',
      ground_truth     => {expected_admissions => [{subject => 'banned-pk', scope => 'channel:#ops', admitted => 0}]},
      actions          => [
        {type => 'new_identity', payload => {identity => 'banned-pk'}},
        {type => 'join',         payload => {subject  => 'banned-pk', scope => 'channel:#ops', mask => undef}},
      ],
      defended =>
        [{type => 'observed_admission', payload => {subject => 'banned-pk', scope => 'channel:#ops', admitted => 0}}],
      exploited =>
        [{type => 'observed_admission', payload => {subject => 'banned-pk', scope => 'channel:#ops', admitted => 1}}],
    },

    ordering_divergence => {
      description      => 'Same-second control events drive two instances to different authority state.',
      target_invariant => 'convergence',
      ground_truth     => {},
      actions          => [
        {
          type    => 'publish_control',
          payload => {kind => 9000, created_at => 1000, subject => 'mallory-pk', role => 'irc.operator'}
        },
        {type => 'publish_control', payload => {kind => 9001, created_at => 1000, subject => 'mallory-pk'}},
      ],
      defended => [
        {
          type    => 'observed_state',
          payload => {instance => 'instance-a', scope => 'channel:#ops', state => {operators => ['operator-pk']}}
        },
        {
          type    => 'observed_state',
          payload => {instance => 'instance-b', scope => 'channel:#ops', state => {operators => ['operator-pk']}}
        },
      ],
      exploited => [
        {
          type    => 'observed_state',
          payload => {instance => 'instance-a', scope => 'channel:#ops', state => {operators => ['operator-pk']}}
        },
        {
          type    => 'observed_state',
          payload =>
            {instance => 'instance-b', scope => 'channel:#ops', state => {operators => ['operator-pk', 'mallory-pk']}}
        },
      ],
    },
  };
}

1;

=head1 NAME

Overnet::Burner::Adversary::Profile::IrcHostedChannel - the IRC hosted-channel adversary profile

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $catalog = Overnet::Burner::Adversary::Profile::IrcHostedChannel->attack_catalog;
  my $arena   = Overnet::Burner::Adversary::Profile::IrcHostedChannel->build_arena(seed => '1');

=head1 DESCRIPTION

The reference adversary application profile: the IRC hosted-channel authority.
It packages the live arena that drives that authority
(L<Overnet::Burner::Adversary::Arena::Live>), the seed-attack catalog written in
its operator/channel vocabulary, and that vocabulary. Selecting this profile
reproduces the adversary subsystem's original, IRC-specific behavior; it is the
default profile.

=head1 SUBROUTINES/METHODS

=head2 name

Returns C<irc-hosted-channel>.

=head2 build_arena

Builds a live arena bound to the IRC hosted-channel authority. Passes its
arguments through to L<Overnet::Burner::Adversary::Arena::Live>.

=head2 vocabulary

Returns the application vocabulary (capabilities, scopes, grant kinds, and
action types) a fuzzer needs to generate in-model variants.

=head2 attack_catalog

Returns a fresh copy of the seed-attack catalog: a mapping of attack name to an
entry carrying a description, target invariant, ground truth, action sequence,
and the defended and exploited transcripts.

=head1 DIAGNOSTICS

No diagnostics are emitted directly.

=head1 CONFIGURATION AND ENVIRONMENT

No module-specific environment configuration is required.

=head1 DEPENDENCIES

Requires L<Overnet::Burner::Adversary::Arena::Live>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Report issues at L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
