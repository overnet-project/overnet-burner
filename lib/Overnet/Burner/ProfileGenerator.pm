package Overnet::Burner::ProfileGenerator;

use strictures 2;

use Carp        qw(croak);
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use YAML::PP;

use Overnet::Burner::Generator;
use Overnet::Burner::Util qw(clone_json read_file);

our $VERSION = '0.001';

my %OPERATOR = map { $_ => 1 } qw(random_int random_number random_range one_of);

sub load_template {
  my ($class, $path) = @_;

  my $text = read_file($path);
  my $raw;
  if (!eval { $raw = YAML::PP->new(schema => ['Core'])->load_string($text); 1 }) {
    croak "$path: $EVAL_ERROR";
  }

  return $class->load_template_data($raw);
}

sub load_template_data {
  my ($class, $raw) = @_;

  my $template = clone_json($raw);
  _validate_template($template);

  return $template;
}

sub generate {
  my ($class, %args) = @_;

  my $seed = $args{seed};
  if (!(defined $seed && !ref $seed && "$seed" =~ /\A-?\d+\z/mxs)) {
    croak "profile seed must be an integer\n";
  }

  my $template = $class->load_template_data($args{template});
  my $profile  = _expand_value($seed, 'profile', $template->{profile});

  return Overnet::Burner::Generator->load_profile_data($profile);
}

sub profile_yaml {
  my ($class, $profile) = @_;

  return YAML::PP->new(schema => ['Core'])->dump_string($profile);
}

sub _validate_template {
  my ($template) = @_;

  if (ref $template ne 'HASH') {
    croak "profile template must be a mapping\n";
  }
  if (($template->{template_version} // q{}) ne '1') {
    croak "template_version must be 1\n";
  }
  if (ref $template->{profile} ne 'HASH') {
    croak "profile must be a mapping\n";
  }

  my %known = map { $_ => 1 } qw(template_version profile);
  for my $key (sort keys %{$template}) {
    if (!$known{$key}) {
      croak "unknown profile template field: $key\n";
    }
  }

  _validate_template_value('profile', $template->{profile});

  return 1;
}

sub _validate_template_value {
  my ($path, $value) = @_;

  if (ref $value eq 'ARRAY') {
    for my $index (0 .. $#{$value}) {
      _validate_template_value("$path\[$index\]", $value->[$index]);
    }
    return 1;
  }

  if (ref $value eq 'HASH') {
    my @operator_keys = grep { $OPERATOR{$_} } keys %{$value};
    if (@operator_keys) {
      if (keys(%{$value}) != 1) {
        croak "template operator at $path must not be mixed with ordinary fields\n";
      }
      my $operator = $operator_keys[0];
      return _validate_operator($path, $operator, $value->{$operator});
    }

    for my $key (sort keys %{$value}) {
      _validate_template_value("$path.$key", $value->{$key});
    }
    return 1;
  }

  if (ref $value) {
    croak "template value at $path must be a scalar, list, or mapping\n";
  }

  return 1;
}

sub _validate_operator {
  my ($path, $operator, $spec) = @_;

  if ($operator eq 'one_of') {
    if (ref $spec ne 'ARRAY') {
      croak "one_of at $path must be a list\n";
    }
    if (!@{$spec}) {
      croak "one_of at $path must not be empty\n";
    }
    for my $index (0 .. $#{$spec}) {
      _validate_template_value("$path.one_of[$index]", $spec->[$index]);
    }
    return 1;
  }

  _require_mapping($spec, "$operator at $path");
  my %known =
      $operator eq 'random_int'    ? map { $_ => 1 } qw(min max)
    : $operator eq 'random_number' ? map { $_ => 1 } qw(min max precision)
    : $operator eq 'random_range'  ? map { $_ => 1 } qw(min max min_width)
    :                                ();
  for my $key (sort keys %{$spec}) {
    if (!$known{$key}) {
      croak "unknown $operator field at $path: $key\n";
    }
  }

  if ($operator eq 'random_number') {
    my $min = _validate_number($spec->{min}, "$operator at $path min", numeric => 1);
    my $max = _validate_number($spec->{max}, "$operator at $path max", numeric => 1);
    if ($min > $max) {
      croak "$operator at $path min ($min) must not exceed max ($max)\n";
    }
    if (exists $spec->{precision}) {
      my $precision = _validate_number($spec->{precision}, "$operator at $path precision");
      if ($precision < 0) {

        # A negative precision makes sprintf('%.${p}f') emit a literal, malformed
        # format string that numifies to 0, silently collapsing every draw.
        croak "$operator at $path precision must not be negative\n";
      }
    }
    return 1;
  }

  my $min = _validate_number($spec->{min}, "$operator at $path min");
  my $max = _validate_number($spec->{max}, "$operator at $path max");
  if ($min > $max) {
    croak "$operator at $path min ($min) must not exceed max ($max)\n";
  }
  if (exists $spec->{min_width}) {
    my $width = _validate_number($spec->{min_width}, "$operator at $path min_width");
    if ($width < 0) {
      croak "$operator at $path min_width must be non-negative\n";
    }
    if ($width > ($max - $min)) {
      croak "$operator at $path min_width ($width) must not exceed range width\n";
    }
  }

  return 1;
}

sub _expand_value {
  my ($seed, $path, $value) = @_;

  if (ref $value eq 'ARRAY') {
    return [map { _expand_value($seed, "$path\[$_\]", $value->[$_]) } 0 .. $#{$value}];
  }

  if (ref $value eq 'HASH') {
    my @operator_keys = grep { $OPERATOR{$_} } keys %{$value};
    if (@operator_keys) {
      my $operator = $operator_keys[0];
      return _expand_operator($seed, $path, $operator, $value->{$operator});
    }

    return {map { $_ => _expand_value($seed, "$path.$_", $value->{$_}) } sort keys %{$value}};
  }

  return clone_json($value);
}

sub _expand_operator {
  my ($seed, $path, $operator, $spec) = @_;

  if ($operator eq 'random_int') {
    return _draw_int($seed, $path, $spec->{min}, $spec->{max});
  }
  if ($operator eq 'random_number') {
    return _draw_number($seed, $path, $spec);
  }
  if ($operator eq 'random_range') {
    return _draw_range($seed, $path, $spec);
  }
  if ($operator eq 'one_of') {
    my $index = _draw_int($seed, "$path:one_of", 0, $#{$spec});
    return _expand_value($seed, "$path.one_of[$index]", $spec->[$index]);
  }

  croak "unknown profile template operator at $path: $operator\n";
}

sub _draw_range {
  my ($seed, $path, $spec) = @_;

  my $first_draw  = _draw_int($seed, "$path:min", $spec->{min}, $spec->{max});
  my $second_draw = _draw_int($seed, "$path:max", $spec->{min}, $spec->{max});
  my ($min, $max) = $first_draw <= $second_draw ? ($first_draw, $second_draw) : ($second_draw, $first_draw);
  my $width = $spec->{min_width} // 0;

  if (($max - $min) < $width) {
    if ($min + $width <= $spec->{max}) {
      $max = $min + $width;
    } elsif ($max - $width >= $spec->{min}) {
      $min = $max - $width;
    } else {

      # The minimum width does not fit around either drawn endpoint without
      # crossing a bound, so widen to the whole span -- which validation
      # guarantees is at least min_width wide -- rather than run past spec.min.
      $min = $spec->{min};
      $max = $spec->{max};
    }
  }

  return {min => 0 + $min, max => 0 + $max};
}

sub _draw_number {
  my ($seed, $path, $spec) = @_;

  my $precision = exists $spec->{precision} ? $spec->{precision} : 3;
  my $hex       = sha256_hex(join chr(0), 'overnet-burner:profile-template', $seed, $path);
  my $draw      = hex substr($hex, 0, 8);
  my $fraction  = $draw / 0xffffffff;
  my $value     = $spec->{min} + (($spec->{max} - $spec->{min}) * $fraction);

  return 0 + sprintf("%.${precision}f", $value);
}

sub _draw_int {
  my ($seed, $path, $low, $high) = @_;

  if ($high <= $low) {
    return 0 + $low;
  }
  my $hex  = sha256_hex(join chr(0), 'overnet-burner:profile-template', $seed, $path);
  my $draw = hex substr($hex, 0, 8);

  return 0 + ($low + ($draw % ($high - $low + 1)));
}

sub _validate_number {
  my ($value, $path, %opts) = @_;

  my $numeric = $opts{numeric};
  my $kind    = $numeric ? 'number'                             : 'integer';
  my $pattern = $numeric ? qr/\A-?(?:\d+(?:\.\d*)?|\.\d+)\z/mxs : qr/\A-?\d+\z/mxs;
  if (ref $value || !defined $value || "$value" !~ $pattern) {
    croak "$path must be an $kind\n";
  }

  return 0 + $value;
}

sub _require_mapping {
  my ($value, $path) = @_;

  if (ref $value ne 'HASH') {
    croak "$path must be a mapping\n";
  }

  return $value;
}

1;

=head1 NAME

Overnet::Burner::ProfileGenerator - deterministic random profile generation

=head1 DESCRIPTION

Generates an ordinary scenario-generation profile from a versioned profile
template. See F<docs/profile-generation.md>.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $template = Overnet::Burner::ProfileGenerator->load_template($path);
  my $profile = Overnet::Burner::ProfileGenerator->generate(seed => 1001, template => $template);

=head1 SUBROUTINES/METHODS

=head2 load_template

=head2 load_template_data

=head2 generate

=head2 profile_yaml

=head1 DIAGNOSTICS

Malformed templates and generated profiles are reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

No environment configuration is required.

=head1 DEPENDENCIES

See the distribution metadata for runtime dependencies.

=head1 INCOMPATIBILITIES

No known incompatibilities are documented.

=head1 BUGS AND LIMITATIONS

Template v1 supports fixed values, C<random_int>, C<random_number>,
C<random_range>, and C<one_of>. More operators can be added in compatible
future versions.

=head1 AUTHOR

Overnet Project.

=head1 LICENSE AND COPYRIGHT

See the project license.

=cut
