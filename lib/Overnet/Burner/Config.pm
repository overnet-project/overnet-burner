package Overnet::Burner::Config;

use strict;
use warnings;

use JSON::PP;
use YAML::PP;

sub load_file {
    my ($class, $path) = @_;

    open my $fh, '<', $path or die "open $path: $!";
    local $/;
    my $text = <$fh>;

    my $config = eval {
        YAML::PP->new(
            boolean => 'JSON::PP',
            schema  => ['Core'],
        )->load_string($text);
    };
    die "$path: $@" if $@;

    $config = {} unless defined $config;
    $config = $class->normalize($config);
    $class->validate($config);

    return $config;
}

sub normalize {
    my ($class, $config) = @_;

    my $copy = decode_json(JSON::PP->new->canonical(1)->encode($config));

    _require_mapping_ref($copy, 'root');
    _require_optional_mapping($copy, 'run');
    _require_optional_mapping($copy, 'topology');
    _require_optional_mapping($copy, 'workload');
    _require_optional_mapping($copy, 'thresholds');
    _require_optional_mapping($copy, 'workload.object_reads');

    $copy->{topology} ||= {};
    $copy->{topology}{publishers} ||= {};
    $copy->{topology}{subscribers} ||= {};
    $copy->{topology}{query_readers} ||= {};
    $copy->{topology}{object_readers} ||= {};

    for my $role (qw(publishers subscribers query_readers object_readers)) {
        $copy->{topology}{$role}{count} = 0
            unless exists $copy->{topology}{$role}{count};
    }

    $copy->{workload} ||= {};
    $copy->{workload}{subscription_filters} ||= [];
    $copy->{workload}{query_filters} ||= [];
    $copy->{workload}{object_reads} ||= {};
    $copy->{chaos} ||= [];
    $copy->{thresholds} ||= {};

    return $copy;
}

sub validate {
    my ($class, $config) = @_;

    _require_string($config, 'run.name');
    _require_positive_integer($config, 'run.duration');
    _require_integer($config, 'run.seed');
    _require_positive_integer($config, 'topology.relays.count');
    _require_string($config, 'topology.relays.provider');
    _require_nonnegative_number($config, 'workload.publish_rate_per_second');

    for my $path (
        qw(
        topology.publishers.count
        topology.subscribers.count
        topology.query_readers.count
        topology.object_readers.count
        )
    ) {
        _require_nonnegative_integer($config, $path);
    }

    _require_array($config, 'workload.subscription_filters');
    _require_array($config, 'workload.query_filters');
    _require_hash($config, 'workload.object_reads');
    _require_array_of_mappings($config, 'chaos');
    _require_hash($config, 'thresholds');

    return 1;
}

sub normalized_json {
    my ($class, $config) = @_;

    return JSON::PP->new->canonical(1)->pretty(1)->space_before(0)
        ->encode($class->normalize($config));
}

sub _require_hash {
    my ($config, $path) = @_;
    my $value = _required_value($config, $path);
    _require_mapping_ref($value, $path);
    return $value;
}

sub _require_optional_mapping {
    my ($config, $path) = @_;
    my $value = _value_at($config, $path);

    return unless defined $value;

    _require_mapping_ref($value, $path);
    return $value;
}

sub _require_mapping_ref {
    my ($value, $path) = @_;

    die "invalid field: $path must be a mapping\n" unless ref $value eq 'HASH';
    return $value;
}

sub _require_array {
    my ($config, $path) = @_;
    my $value = _required_value($config, $path);
    die "invalid field: $path must be an array\n" unless ref $value eq 'ARRAY';
    return $value;
}

sub _require_array_of_mappings {
    my ($config, $path) = @_;
    my $value = _require_array($config, $path);
    my $index = 0;

    for my $item (@{$value}) {
        _require_mapping_ref($item, "$path\[$index\]");
        $index++;
    }

    return $value;
}

sub _require_string {
    my ($config, $path) = @_;
    my $value = _required_value($config, $path);
    die "invalid field: $path must be a non-empty string\n"
        if ref $value || !defined $value || $value eq '';
    return $value;
}

sub _require_integer {
    my ($config, $path) = @_;
    my $value = _required_value($config, $path);
    die "invalid field: $path must be an integer\n"
        if ref $value || !defined $value || "$value" !~ /^-?\d+\z/;
    return $value;
}

sub _require_positive_integer {
    my ($config, $path) = @_;
    my $value = _require_integer($config, $path);
    die "invalid field: $path must be positive\n" unless $value > 0;
    return $value;
}

sub _require_nonnegative_integer {
    my ($config, $path) = @_;
    my $value = _require_integer($config, $path);
    die "invalid field: $path must be non-negative\n" unless $value >= 0;
    return $value;
}

sub _require_nonnegative_number {
    my ($config, $path) = @_;
    my $value = _required_value($config, $path);
    die "invalid field: $path must be a non-negative number\n"
        if ref $value
        || !defined $value
        || "$value" !~ /^-?(?:\d+(?:\.\d*)?|\.\d+)\z/
        || $value < 0;
    return $value;
}

sub _required_value {
    my ($config, $path) = @_;
    my $value = _value_at($config, $path);
    die "missing required field: $path\n" unless defined $value;
    return $value;
}

sub _value_at {
    my ($config, $path) = @_;
    my $value = $config;

    for my $part (split /\./, $path) {
        return undef unless ref $value eq 'HASH';
        return undef unless exists $value->{$part};
        $value = $value->{$part};
    }

    return $value;
}

1;
