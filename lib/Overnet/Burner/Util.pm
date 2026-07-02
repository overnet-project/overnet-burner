package Overnet::Burner::Util;

use strictures 2;

use Carp     qw(croak);
use English  qw(-no_match_vars);
use Exporter qw(import);
use JSON::PP ();

our $VERSION   = '0.001';
our @EXPORT_OK = qw(
  checked_close
  checked_print
  clone_json
  json_text
  read_file
  read_json_file
  read_jsonl_file
  write_file
);

sub json_text {
  my ($value) = @_;
  return JSON::PP->new->canonical(1)->pretty(1)->space_before(0)->encode($value);
}

sub clone_json {
  my ($value) = @_;
  return JSON::PP::decode_json(JSON::PP->new->canonical(1)->encode($value));
}

sub checked_print {
  my ($handle, @content) = @_;
  print {$handle} @content
    or croak "print failed: $OS_ERROR\n";
  return 1;
}

sub checked_close {
  my ($handle, $description) = @_;
  close $handle
    or croak "close failed for $description: $OS_ERROR\n";
  return 1;
}

sub read_file {
  my ($path) = @_;
  open my $fh, '<', $path
    or croak "open $path: $OS_ERROR\n";
  local $INPUT_RECORD_SEPARATOR = undef;
  my $content = <$fh>;
  checked_close($fh, $path);
  return $content;
}

sub read_json_file {
  my ($path) = @_;
  return JSON::PP::decode_json(read_file($path));
}

sub read_jsonl_file {
  my ($path) = @_;
  if (!-e $path) {
    return [];
  }

  open my $fh, '<', $path
    or croak "open $path: $OS_ERROR\n";
  my @records = map { JSON::PP::decode_json($_) } <$fh>;
  checked_close($fh, $path);
  return \@records;
}

sub write_file {
  my ($path, $content) = @_;
  open my $fh, '>', $path
    or croak "open $path: $OS_ERROR\n";
  checked_print($fh, $content);
  checked_close($fh, $path);
  return 1;
}

1;

=head1 NAME

Overnet::Burner::Util - shared utility helpers for overnet-burner

=head1 DESCRIPTION

Provides checked file IO and deterministic JSON helpers used by overnet-burner modules.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  use Overnet::Burner::Util qw(read_json_file write_file);

=head1 SUBROUTINES/METHODS

=head2 checked_close

=head2 checked_print

=head2 clone_json

=head2 json_text

=head2 read_file

=head2 read_json_file

=head2 read_jsonl_file

=head2 write_file

=head1 DIAGNOSTICS

Failed IO operations are reported through exceptions.

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
