package Overnet::Burner::ReferenceImage;

use strictures 2;

use Carp           qw(croak);
use Cwd            qw(abs_path);
use English        qw(-no_match_vars);
use File::Basename qw(dirname);
use File::Copy     qw(copy);
use File::Find     qw(find);
use File::Path     qw(make_path remove_tree);
use File::Spec;

use Overnet::Burner::Util qw(write_file);

our $VERSION = '0.001';

sub ensure {
  my ($class, %args) = @_;

  my $engine  = $args{engine}  || croak "engine is required\n";
  my $run_dir = $args{run_dir} || croak "run_dir is required\n";
  my $tag     = $args{tag}     || croak "tag is required\n";

  my $context = File::Spec->catdir($run_dir, 'artifacts', 'images', 'reference');
  $class->write_context($context);
  $engine->build_image(tag => $tag, context => $context);

  return $tag;
}

sub write_context {
  my ($class, $context) = @_;

  if (-d $context) {
    remove_tree($context);
  }
  make_path($context);

  my $repos = _code_repos_root();
  _copy_tree(File::Spec->catdir($repos, 'core-perl',      'lib'), File::Spec->catdir($context, 'core-perl',  'lib'));
  _copy_tree(File::Spec->catdir($repos, 'relay-perl',     'lib'), File::Spec->catdir($context, 'relay-perl', 'lib'));
  _copy_tree(File::Spec->catdir($repos, 'relay-perl',     'bin'), File::Spec->catdir($context, 'relay-perl', 'bin'));
  _copy_tree(File::Spec->catdir($repos, 'overnet-burner', 'lib'),
    File::Spec->catdir($context, 'overnet-burner', 'lib'));
  _copy_tree(File::Spec->catdir($repos, 'overnet-burner', 'bin'),
    File::Spec->catdir($context, 'overnet-burner', 'bin'));

  write_file(File::Spec->catfile($context, 'Dockerfile'), _dockerfile());

  return $context;
}

sub _code_repos_root {
  my $burner_root = abs_path(File::Spec->catdir(dirname(__FILE__), (File::Spec->updir) x 3))
    || croak "could not resolve overnet-burner root\n";

  return dirname($burner_root);
}

sub _copy_tree {
  my ($from, $to) = @_;

  if (!-d $from) {
    croak "reference image source directory does not exist: $from\n";
  }

  make_path($to);
  find(
    {
      no_chdir => 1,
      wanted   => sub {
        my $path = $File::Find::name;
        return if $path eq $from;
        my $rel = File::Spec->abs2rel($path, $from);
        return if $rel =~ m{(?:\A|/)[.]git(?:/|\z)}mxs;

        my $dest = File::Spec->catfile($to, $rel);
        if (-d $path) {
          make_path($dest);
          return;
        }
        make_path(dirname($dest));
        copy($path, $dest)
          or croak "copy $path to $dest: $OS_ERROR\n";
      },
    },
    $from,
  );

  return 1;
}

sub _dockerfile {
  return <<'DOCKERFILE';
FROM docker.io/library/perl:5.42

ENV PERL_MM_USE_DEFAULT=1
RUN cpanm --notest strictures Moo JSON JSON::Schema::Modern YAML::PP Rex AnyEvent AnyEvent::WebSocket::Client CryptX IO::Socket::SSL Package::Stash URI HTTP::Tiny Net::Nostr

COPY core-perl/lib /opt/overnet/core-perl/lib
COPY relay-perl/lib /opt/overnet/relay-perl/lib
COPY relay-perl/bin /usr/local/bin
COPY overnet-burner/lib /opt/overnet/overnet-burner/lib
COPY overnet-burner/bin/overnet-burner /usr/local/bin/overnet-burner
COPY overnet-burner/bin/overnet-burner-worker /usr/local/bin/overnet-burner-worker

ENV PERL5LIB=/opt/overnet/overnet-burner/lib:/opt/overnet/relay-perl/lib:/opt/overnet/core-perl/lib
RUN chmod +x /usr/local/bin/overnet-*
DOCKERFILE
}

1;

=head1 NAME

Overnet::Burner::ReferenceImage - managed reference stack image builder

=head1 DESCRIPTION

Builds the local OCI image used by the managed C<local-containers>
environment. The image contains the active Overnet core, relay, and burner
checkouts plus the CPAN dependencies needed by the reference relay and worker
commands.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  Overnet::Burner::ReferenceImage->ensure(
    engine  => $engine,
    run_dir => $run_dir,
    tag     => 'overnet-burner-reference:local',
  );

=head1 SUBROUTINES/METHODS

=head2 ensure

=head2 write_context

=head1 DIAGNOSTICS

Missing source directories, failed file copies, and image build failures are
reported through exceptions.

=head1 CONFIGURATION AND ENVIRONMENT

The build context is generated under the run directory.

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
