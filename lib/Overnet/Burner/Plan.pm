package Overnet::Burner::Plan;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use JSON::PP qw(decode_json);

sub build {
    my ($class, $scenario) = @_;

    my @relays = _actors(
        scenario => $scenario,
        field    => 'relays',
        role     => 'relay',
        prefix   => 'relay',
        extra    => {
            provider => $scenario->{topology}{relays}{provider},
        },
    );
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

    my @actors = (
        @relays,
        @publishers,
        @subscribers,
        @query_readers,
        @object_readers,
    );

    return {
        plan_version => 1,
        scenario     => {
            name => $scenario->{run}{name},
        },
        run => {
            name             => $scenario->{run}{name},
            duration_seconds => 0 + $scenario->{run}{duration},
            seed             => 0 + $scenario->{run}{seed},
        },
        provider => {
            name => $scenario->{topology}{relays}{provider},
        },
        relays         => \@relays,
        publishers     => \@publishers,
        subscribers    => \@subscribers,
        query_readers  => \@query_readers,
        object_readers => \@object_readers,
        workload       => {
            phases => [_default_phase($scenario, \@actors)],
        },
        metric_streams => [_metric_streams(@actors)],
        chaos_hooks    => [_chaos_hooks($scenario)],
    };
}

sub canonical_json {
    my ($class, $plan) = @_;

    return JSON::PP->new->canonical(1)->pretty(1)->space_before(0)
        ->encode($plan);
}

sub _actors {
    my (%args) = @_;

    my $scenario = $args{scenario};
    my $field = $args{field};
    my $role = $args{role};
    my $prefix = $args{prefix};
    my $extra = $args{extra} || {};
    my $count = $scenario->{topology}{$field}{count} || 0;
    my @actors;

    for my $ordinal (1 .. $count) {
        my $id = sprintf('%s-%03d', $prefix, $ordinal);
        push @actors, {
            id            => $id,
            name          => $id,
            role          => $role,
            ordinal       => $ordinal,
            seed          => _seed($scenario, "actor:$id"),
            metric_stream => "metrics/$id.jsonl",
            %{$extra},
        };
    }

    return @actors;
}

sub _default_phase {
    my ($scenario, $actors) = @_;

    my $phase_id = 'phase-001';
    my %actor_seeds = map {
        $_->{id} => _seed($scenario, "phase:$phase_id:actor:$_->{id}")
    } @{$actors};

    return {
        id                      => $phase_id,
        name                    => 'main',
        ordinal                 => 1,
        start_seconds           => 0,
        duration_seconds        => 0 + $scenario->{run}{duration},
        publish_rate_per_second => 0
            + $scenario->{workload}{publish_rate_per_second},
        subscription_filters => _clone($scenario->{workload}{subscription_filters}),
        query_filters        => _clone($scenario->{workload}{query_filters}),
        object_reads         => _clone($scenario->{workload}{object_reads}),
        actor_seeds          => \%actor_seeds,
    };
}

sub _metric_streams {
    my (@actors) = @_;
    my @streams;

    for my $actor (@actors) {
        push @streams, {
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

    for my $source_hook (@{ $scenario->{chaos} || [] }) {
        my %hook = %{ _clone($source_hook) };
        $ordinal++;
        my $id = sprintf('chaos-%03d', $ordinal);

        $hook{id} = $id;
        $hook{ordinal} = $ordinal;
        $hook{seed} = _seed($scenario, "chaos:$id");
        $hook{at_seconds} = delete $hook{at} if exists $hook{at};

        push @hooks, \%hook;
    }

    return @hooks;
}

sub _seed {
    my ($scenario, $label) = @_;

    my $base_seed = $scenario->{run}{seed};
    my $hex = sha256_hex(join "\0", $base_seed, $label);
    return hex substr($hex, 0, 8);
}

sub _clone {
    my ($value) = @_;

    return decode_json(JSON::PP->new->canonical(1)->encode($value));
}

1;
