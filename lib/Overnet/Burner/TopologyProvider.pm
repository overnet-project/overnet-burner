package Overnet::Burner::TopologyProvider;

use strict;
use warnings;

use JSON::PP qw(decode_json);

my %SUPPORTED_PROVIDER = map { $_ => 1 } qw(generic-relay external-command);

sub from_relay_config {
    my ($class, $relays, %args) = @_;

    my $path = $args{path} || 'topology.relays';
    _require_mapping_ref($relays, $path);

    my $name = _require_member_string($relays, 'provider', "$path.provider");
    die "unknown topology provider: $name\n" unless $SUPPORTED_PROVIDER{$name};

    my $provider = {
        name => $name,
    };

    if ($name eq 'external-command') {
        my $command = _require_member_mapping($relays, 'command', "$path.command");
        $provider->{command} = {
            health => _require_member_string($command, 'health', "$path.command.health"),
            start  => _require_member_string($command, 'start', "$path.command.start"),
            stop   => _require_member_string($command, 'stop', "$path.command.stop"),
        };
    }

    return _clone($provider);
}

sub relay_actor_descriptor {
    my ($class, $provider) = @_;

    my $descriptor = {};
    if (exists $provider->{command}) {
        $descriptor->{command} = _clone($provider->{command});
    }

    return $descriptor;
}

sub _require_member_mapping {
    my ($mapping, $key, $path) = @_;
    my $value = _required_member($mapping, $key, $path);
    _require_mapping_ref($value, $path);
    return $value;
}

sub _require_member_string {
    my ($mapping, $key, $path) = @_;
    my $value = _required_member($mapping, $key, $path);
    die "invalid field: $path must be a non-empty string\n"
        if ref $value || !defined $value || $value eq '';
    return $value;
}

sub _required_member {
    my ($mapping, $key, $path) = @_;

    die "missing required field: $path\n"
        unless ref $mapping eq 'HASH' && exists $mapping->{$key};

    return $mapping->{$key};
}

sub _require_mapping_ref {
    my ($value, $path) = @_;

    die "invalid field: $path must be a mapping\n" unless ref $value eq 'HASH';
    return $value;
}

sub _clone {
    my ($value) = @_;

    return decode_json(JSON::PP->new->canonical(1)->encode($value));
}

1;
