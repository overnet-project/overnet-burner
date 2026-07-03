package Overnet::Burner::Plan;

use strictures 2;

use Digest::SHA qw(sha256_hex);
use JSON        ();

use Overnet::Burner::TopologyProvider;
use Overnet::Burner::Util qw(clone_json json_text);

our $VERSION = '0.001';

sub build {
  my ($class, $scenario) = @_;

  my $topology_provider = Overnet::Burner::TopologyProvider->from_relay_config($scenario->{topology}{relays},);
  my $relay_descriptor  = Overnet::Burner::TopologyProvider->relay_actor_descriptor($topology_provider);
  my @relays            = _actors(
    scenario => $scenario,
    field    => 'relays',
    role     => 'relay',
    prefix   => 'relay',
    extra    => {
      topology_provider => $topology_provider->{name},
      (
        keys %{$relay_descriptor}
        ? (topology_provider_descriptor => $relay_descriptor)
        : ()
      ),
    },
  );
  my $relay_endpoints = $scenario->{topology}{relays}{endpoints};
  if (ref($relay_endpoints) eq 'ARRAY') {
    for my $relay (@relays) {
      $relay->{endpoint} = $relay_endpoints->[$relay->{ordinal} - 1];
    }
  }
  my @publishers = _actors(
    scenario => $scenario,
    field    => 'publishers',
    role     => 'publisher',
    prefix   => 'publisher',
  );
  my @subscribers = _actors(
    scenario => $scenario,
    field    => 'subscribers',
    role     => 'subscriber',
    prefix   => 'subscriber',
  );
  my @query_readers = _actors(
    scenario => $scenario,
    field    => 'query_readers',
    role     => 'query_reader',
    prefix   => 'query-reader',
  );
  my @object_readers = _actors(
    scenario => $scenario,
    field    => 'object_readers',
    role     => 'object_reader',
    prefix   => 'object-reader',
  );
  my @observers = _actors(
    scenario => $scenario,
    field    => 'observers',
    role     => 'observer',
    prefix   => 'observer',
  );
  my @flooders = _actors(
    scenario => $scenario,
    field    => 'flooders',
    role     => 'flooder',
    prefix   => 'flooder',
  );
  my @malformed_publishers = _actors(
    scenario => $scenario,
    field    => 'malformed_publishers',
    role     => 'malformed_publisher',
    prefix   => 'malformed-publisher',
  );
  my @replayers = _actors(
    scenario => $scenario,
    field    => 'replayers',
    role     => 'replayer',
    prefix   => 'replayer',
  );
  my @subscription_abusers = _actors(
    scenario => $scenario,
    field    => 'subscription_abusers',
    role     => 'subscription_abuser',
    prefix   => 'subscription-abuser',
  );
  my @sybils = _actors(
    scenario => $scenario,
    field    => 'sybils',
    role     => 'sybil',
    prefix   => 'sybil',
  );
  my @connection_floods = _actors(
    scenario => $scenario,
    field    => 'connection_floods',
    role     => 'connection_flood',
    prefix   => 'connection-flood',
  );
  my @provenance_forgers = _actors(
    scenario => $scenario,
    field    => 'provenance_forgers',
    role     => 'provenance_forger',
    prefix   => 'provenance-forger',
  );

  my @actors = (
    @relays,            @publishers,           @subscribers, @query_readers,        @object_readers,
    @observers,         @malformed_publishers, @replayers,   @subscription_abusers, @sybils,
    @connection_floods, @flooders,             @provenance_forgers,
  );
  my @phases = _phases($scenario, \@actors);
  my $total  = 0;
  for my $phase (@phases) {
    $total += $phase->{duration_seconds};
  }

  return {
    plan_version => 1,
    scenario     => {
      name => $scenario->{run}{name},
    },
    run => {
      name                   => $scenario->{run}{name},
      duration_seconds       => 0 + $scenario->{run}{duration},
      total_duration_seconds => $total,
      seed                   => 0 + $scenario->{run}{seed},
    },
    topology_provider    => $topology_provider,
    relays               => \@relays,
    publishers           => \@publishers,
    subscribers          => \@subscribers,
    query_readers        => \@query_readers,
    object_readers       => \@object_readers,
    observers            => \@observers,
    flooders             => \@flooders,
    malformed_publishers => \@malformed_publishers,
    replayers            => \@replayers,
    subscription_abusers => \@subscription_abusers,
    sybils               => \@sybils,
    connection_floods    => \@connection_floods,
    provenance_forgers   => \@provenance_forgers,
    workload             => {
      phases => \@phases,
    },
    metric_streams => [_metric_streams(@actors)],
    chaos_hooks    => [_chaos_hooks($scenario)],
  };
}

sub canonical_json {
  my ($class, $plan) = @_;

  return json_text($plan);
}

sub _actors {
  my (%args) = @_;

  my $scenario = $args{scenario};
  my $field    = $args{field};
  my $role     = $args{role};
  my $prefix   = $args{prefix};
  my $extra    = $args{extra}                         || {};
  my $count    = $scenario->{topology}{$field}{count} || 0;
  my @actors;

  for my $ordinal (1 .. $count) {
    my $id = sprintf('%s-%03d', $prefix, $ordinal);
    push @actors,
      {
      id      => $id,
      name    => $id,
      role    => $role,
      ordinal => $ordinal,
      seed    => _seed($scenario, "actor:$id"),
      $role eq 'relay' ? () : (metric_stream => "metrics/$id.jsonl"),
      %{$extra},
      };
  }

  return @actors;
}

sub _phases {
  my ($scenario, $actors) = @_;

  my @specs = ([warmup => $scenario->{workload}{warmup}], [main => {}], [cooldown => $scenario->{workload}{cooldown}],);

  my @phases;
  my $ordinal = 0;
  my $start   = 0;
  for my $spec (@specs) {
    my ($name, $override) = @{$spec};
    if ($name ne 'main' && ref $override ne 'HASH') {
      next;
    }

    $ordinal++;
    my $phase_id = sprintf 'phase-%03d', $ordinal;
    my $duration =
      $name eq 'main' ? 0 + $scenario->{run}{duration} : 0 + $override->{duration};
    my %actor_seeds = map { $_->{id} => _seed($scenario, "phase:$phase_id:actor:$_->{id}") } @{$actors};

    my $object_reads = _clone($scenario->{workload}{object_reads});
    if (ref $override->{object_reads} eq 'HASH' && exists $override->{object_reads}{rate_per_second}) {
      $object_reads->{rate_per_second} = 0 + $override->{object_reads}{rate_per_second};
    }

    push @phases,
      {
      id                      => $phase_id,
      name                    => $name,
      ordinal                 => $ordinal,
      start_seconds           => $start,
      duration_seconds        => $duration,
      publish_rate_per_second => 0 + _override_or($override, $scenario, 'publish_rate_per_second'),
      query_rate_per_second   => 0 + _override_or($override, $scenario, 'query_rate_per_second'),
      subscription_filters    => _clone($scenario->{workload}{subscription_filters}),
      query_filters           => _clone($scenario->{workload}{query_filters}),
      object_reads            => $object_reads,
      observer                => _clone($scenario->{workload}{observer} || {}),
      abuse                   => _clone($scenario->{workload}{abuse}    || {}),
      actor_seeds             => \%actor_seeds,
      };
    $start += $duration;
  }

  return @phases;
}

sub _override_or {
  my ($override, $scenario, $key) = @_;

  return exists $override->{$key} ? $override->{$key} : $scenario->{workload}{$key};
}

sub _metric_streams {
  my (@actors) = @_;
  my @streams;

  for my $actor (@actors) {
    if (!defined $actor->{metric_stream}) {
      next;
    }
    push @streams,
      {
      id       => "metric-stream-$actor->{id}",
      actor_id => $actor->{id},
      role     => $actor->{role},
      path     => $actor->{metric_stream},
      format   => 'jsonl',
      };
  }

  return @streams;
}

sub _chaos_hooks {
  my ($scenario) = @_;
  my @hooks;
  my $ordinal = 0;

  for my $source_hook (@{$scenario->{chaos} || []}) {
    my %hook = %{_clone($source_hook)};
    $ordinal++;
    my $id = sprintf('chaos-%03d', $ordinal);

    $hook{id}      = $id;
    $hook{ordinal} = $ordinal;
    $hook{seed}    = _seed($scenario, "chaos:$id");
    if (exists $hook{at}) {
      $hook{at_seconds} = delete $hook{at};
    }

    push @hooks, \%hook;
  }

  return @hooks;
}

sub _seed {
  my ($scenario, $label) = @_;

  my $base_seed = $scenario->{run}{seed};
  my $separator = chr 0;
  my $hex       = sha256_hex(join $separator, $base_seed, $label);
  return hex substr($hex, 0, 8);
}

sub _clone {
  my ($value) = @_;

  return clone_json($value);
}

1;

=head1 NAME

Overnet::Burner::Plan - deterministic execution plan builder

=head1 DESCRIPTION

Expands an overnet-burner scenario into a deterministic execution plan.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $plan = Overnet::Burner::Plan->build($scenario);

=head1 SUBROUTINES/METHODS

=head2 build

=head2 canonical_json

=head1 DIAGNOSTICS

Invalid input is reported through exceptions from the underlying validation layer.

=head1 CONFIGURATION AND ENVIRONMENT

No environment configuration is required.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

No known bugs are documented.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
