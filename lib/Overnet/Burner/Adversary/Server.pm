package Overnet::Burner::Adversary::Server;

use strictures 2;
use Moo;

use Carp    qw(croak);
use English qw(-no_match_vars);

use Overnet::Burner::Adversary::Session;
use Overnet::Burner::Adversary::Oracle;
use Overnet::Burner::Adversary::Runner;

our $VERSION = '0.001';

has arena_factory         => (is => 'lazy');
has max_steps_per_session => (is => 'ro',   default  => 100_000);
has _runner               => (is => 'lazy', init_arg => undef);
has _sessions             => (is => 'ro',   init_arg => undef, default => sub { {} });

sub _build_arena_factory {
  return \&_default_arena;
}

sub _build__runner {
  return Overnet::Burner::Adversary::Runner->new;
}

sub dispatch {
  my ($self, %req) = @_;
  my $method = uc(defined $req{method} ? $req{method} : 'GET');
  my $path   = defined $req{path} ? $req{path} : q{/};
  my $body   = $req{body};

  if (defined $body && ref($body) ne 'HASH') {
    return _response(400, {error => 'request body must be an object'});
  }

  my $response;
  my $ok = eval {
    $response = $self->_route($method, $path, defined $body ? $body : {});
    1;
  };
  if (!$ok) {
    return _error_response($EVAL_ERROR);
  }
  return $response;
}

sub _route {
  my ($self, $method, $path, $body) = @_;

  if ($method eq 'GET' && $path eq '/health') {
    return _response(200, {status => 'ok'});
  }
  if ($method eq 'POST' && $path eq '/sessions') {
    return $self->_create_session($body);
  }
  if ($path =~ m{\A/sessions/([^/]+)\z}mxs) {
    my $id = $1;
    if ($method eq 'GET') {
      return $self->_show_session($id);
    }
    if ($method eq 'DELETE') {
      return $self->_close_session($id);
    }
  }
  if ($method eq 'POST' && $path =~ m{\A/sessions/([^/]+)/actions\z}mxs) {
    return $self->_submit_actions($1, $body);
  }
  if ($method eq 'GET' && $path =~ m{\A/sessions/([^/]+)/verdict\z}mxs) {
    return $self->_evaluate_session($1);
  }
  if ($method eq 'GET' && $path =~ m{\A/sessions/([^/]+)/log\z}mxs) {
    return $self->_session_log($1);
  }

  _client_error(404, "no such route: $method $path");
  return;
}

sub _create_session {
  my ($self, $body) = @_;
  my $id = _require_string($body, 'session_id');
  if (exists $self->_sessions->{$id}) {
    _client_error(409, "session already exists: $id");
  }

  my $spec  = defined $body->{arena} ? $body->{arena} : {type => 'recorded'};
  my $arena = $self->arena_factory->($spec);
  _assert_arena($arena);
  $arena->reset;

  my $session = Overnet::Burner::Adversary::Session->new(
    session_id         => $id,
    seed               => (defined $body->{seed} ? $body->{seed} : '1'),
    arena_baseline_ref => $arena->baseline_ref,
  );

  my $ground_truth = defined $body->{ground_truth} ? $body->{ground_truth} : {};
  if (ref($ground_truth) ne 'HASH') {
    _client_error(400, 'ground_truth must be an object');
  }

  $self->_sessions->{$id} = {
    arena        => $arena,
    session      => $session,
    oracle       => Overnet::Burner::Adversary::Oracle->new,
    ground_truth => $ground_truth,
    steps        => 0,
    closed       => 0,
  };

  return _response(201, {session_id => $id, baseline_ref => $arena->baseline_ref, step_count => 1});
}

sub _submit_actions {
  my ($self, $id, $body) = @_;
  my $entry = $self->_open_session($id);

  my $actions = $self->_actions_from_body($body);

  my @observations;
  for my $action (@{$actions}) {
    if ($entry->{steps} >= $self->max_steps_per_session) {
      _client_error(429, "session step limit reached: $self->{max_steps_per_session}");
    }
    my $recorded = $self->_runner->step(
      arena   => $entry->{arena},
      session => $entry->{session},
      action  => $action,
    );
    $entry->{steps}++;
    push @observations, map { _public_step($_) } @{$recorded};
  }

  return _response(200, {observations => \@observations, step_count => scalar @{$entry->{session}->steps}});
}

sub _evaluate_session {
  my ($self, $id) = @_;
  my $entry   = $self->_session_entry($id);
  my $verdict = $entry->{oracle}->evaluate(
    session      => $entry->{session},
    ground_truth => $entry->{ground_truth},
  );
  return _response(200, {verdict => $verdict});
}

sub _show_session {
  my ($self, $id) = @_;
  my $entry = $self->_session_entry($id);
  return _response(
    200,
    {
      session_id   => $id,
      baseline_ref => $entry->{arena}->baseline_ref,
      closed       => $entry->{closed},
      step_count   => scalar @{$entry->{session}->steps},
    }
  );
}

sub _session_log {
  my ($self, $id) = @_;
  my $entry = $self->_session_entry($id);
  return _response(200, {jsonl => $entry->{session}->to_jsonl});
}

sub _close_session {
  my ($self, $id) = @_;
  $self->_session_entry($id);
  delete $self->_sessions->{$id};
  return _response(200, {session_id => $id, closed => 1});
}

sub _actions_from_body {
  my ($self, $body) = @_;
  if (defined $body->{actions}) {
    if (ref($body->{actions}) ne 'ARRAY') {
      _client_error(400, 'actions must be an array');
    }
    return $body->{actions};
  }
  if (defined $body->{action}) {
    return [$body->{action}];
  }
  _client_error(400, 'an action or actions field is required');
  return;
}

sub _session_entry {
  my ($self, $id) = @_;
  my $entry = $self->_sessions->{$id};
  if (!$entry) {
    _client_error(404, "no such session: $id");
  }
  return $entry;
}

sub _open_session {
  my ($self, $id) = @_;
  my $entry = $self->_session_entry($id);
  if ($entry->{closed}) {
    _client_error(409, "session is closed: $id");
  }
  return $entry;
}

sub _default_arena {
  my ($spec) = @_;
  if (ref($spec) ne 'HASH') {
    croak "arena spec must be an object\n";
  }
  my $type   = defined $spec->{type} ? $spec->{type} : 'recorded';
  my %params = %{$spec};
  delete $params{type};

  if ($type eq 'recorded') {
    require Overnet::Burner::Adversary::Arena::Recorded;
    return Overnet::Burner::Adversary::Arena::Recorded->new(%params);
  }
  if ($type eq 'live') {
    require Overnet::Burner::Adversary::Profile;
    my $profile = Overnet::Burner::Adversary::Profile->resolve(delete $params{profile});
    return $profile->build_arena(%params);
  }
  croak "unknown arena type: $type\n";
}

sub _assert_arena {
  my ($arena) = @_;
  for my $method (qw(reset apply baseline_ref)) {
    if (!(ref($arena) && $arena->can($method))) {
      _client_error(400, "arena does not implement $method");
    }
  }
  return;
}

sub _public_step {
  my ($step) = @_;
  return {
    seq     => $step->{seq},
    type    => $step->{type},
    payload => $step->{payload},
  };
}

sub _require_string {
  my ($body, $field) = @_;
  my $value = $body->{$field};
  if (!(defined $value && !ref($value) && length $value)) {
    _client_error(400, "$field is required");
  }
  return $value;
}

sub _response {
  my ($status, $body) = @_;
  return {status => $status, body => $body};
}

sub _client_error {
  my ($status, $message) = @_;
  die {status => $status, error => $message};    ## no critic (RequireCarping)
}

sub _error_response {
  my ($error) = @_;
  if (ref($error) eq 'HASH' && $error->{status}) {
    return _response($error->{status}, {error => $error->{error}});
  }
  my $message = "$error";
  $message =~ s/\s+\z//mxs;
  return _response(400, {error => $message});
}

1;

=head1 NAME

Overnet::Burner::Adversary::Server - a transport-neutral API over adversary sessions

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $server = Overnet::Burner::Adversary::Server->new;

  my $created = $server->dispatch(
    method => 'POST',
    path   => '/sessions',
    body   => {
      session_id => 'sess-1',
      arena      => {type => 'live', snapshot_signers => ['snapshot-authority']},
      ground_truth => {authorized_capabilities => [...]},
    },
  );

  my $stepped = $server->dispatch(
    method => 'POST',
    path   => '/sessions/sess-1/actions',
    body   => {actions => [{type => 'publish_control', payload => {...}}]},
  );
  # $stepped->{body}{observations}

  my $verdict = $server->dispatch(method => 'GET', path => '/sessions/sess-1/verdict');

=head1 DESCRIPTION

The server exposes the adversary harness as a small request/response API so an
external driver - including an autonomous, looping one - can create a session,
submit actions, read back the observations the arena produced, and ask the
oracle for a verdict, all over the wire. It holds the arena, session, and oracle
server-side; the driver is the remote client.

The server is deliberately transport-neutral: L</dispatch> takes a decomposed
request (method, path, decoded body) and returns a decomposed response (status,
body) as plain Perl data. A thin HTTP binding (see
F<bin/overnet-burner-adversary-server>) is the only part that touches sockets,
so the entire API surface is exercisable without a network.

Each request is one incremental turn of the same loop
L<Overnet::Burner::Adversary::Runner> runs internally: submitting actions calls
C<< $runner->step >> for each, so a session built over the API is byte-for-byte
the same durable artifact as one built by the batch runner.

=head2 Routes

=over

=item * C<GET /health> - liveness; returns C<< {status => 'ok'} >>.

=item * C<POST /sessions> - create a session. Body: C<session_id> (required),
optional C<seed>, C<arena> (a spec C<< {type => 'recorded'|'live', ...params} >>,
default recorded), and C<ground_truth>. Returns 201 with the C<baseline_ref>. A
C<live> spec may name an adversary application C<profile> (default
C<irc-hosted-channel>); the profile builds the arena bound to its application's
authority. See L<Overnet::Burner::Adversary::Profile>.

=item * C<GET /sessions/{id}> - session summary (baseline, closed, step count).

=item * C<POST /sessions/{id}/actions> - submit C<actions> (an array) or a single
C<action>; applies each to the arena and returns the resulting C<observations>.

=item * C<GET /sessions/{id}/verdict> - evaluate the session against its ground
truth and return the oracle C<verdict>.

=item * C<GET /sessions/{id}/log> - the replayable session as C<jsonl>.

=item * C<DELETE /sessions/{id}> - end the session.

=back

=head1 SUBROUTINES/METHODS

=head2 new

Creates a server. Takes an optional C<arena_factory> (a code reference mapping
an arena spec to an arena object; the default builds C<recorded> and C<live>
arenas by name) and C<max_steps_per_session> (default 100000).

=head2 dispatch

Handles one request. Takes C<method>, C<path>, and an optional decoded C<body>
(an object). Returns C<< {status => $http_status, body => $data} >>. Errors are
returned as C<< {error => ...} >> bodies with an appropriate status rather than
thrown.

=head1 DIAGNOSTICS

Client errors (unknown route, missing session, duplicate session, malformed
request, step limit) are returned as JSON error bodies with 4xx statuses.

=head1 CONFIGURATION AND ENVIRONMENT

Building a C<live> arena requires the relay dist on C<@INC>; requesting one
where it is unavailable yields a 4xx error rather than a crash.

=head1 DEPENDENCIES

Requires L<Moo>, L<Overnet::Burner::Adversary::Session>,
L<Overnet::Burner::Adversary::Oracle>, and L<Overnet::Burner::Adversary::Runner>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Sessions are held in memory for the life of the process. Report issues at
L<https://github.com/overnet-project/overnet-burner/issues>.

=head1 AUTHOR

Nicholas B. Hubbard C<< <nicholashubbard@posteo.net> >>

=head1 LICENSE AND COPYRIGHT

This software is distributed under the GNU General Public License, version 3.

=cut
