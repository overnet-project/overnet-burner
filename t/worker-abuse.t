use strictures 2;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Socket::INET;
use JSON ();
use Net::Nostr::Relay;
use Test2::V0;
use Time::HiRes qw(time);

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Metrics;
use Overnet::Burner::Worker::Flooder;
use Overnet::Burner::Worker::MalformedPublisher;
use Overnet::Burner::Worker::Replayer;

subtest 'flooder measures rate limiting honestly' => sub {
  my $port  = _free_port();
  my $relay = Net::Nostr::Relay->new(event_rate_limit => '3/60');
  $relay->start('127.0.0.1', $port);

  my $run_dir = _run_layout('flooder-001');
  my $input   = _worker_input(
    $run_dir, $port,
    worker_id        => 'flooder-001',
    role             => 'flooder',
    abuse            => {flooder => {publish_rate_per_second => 50}},
    duration_seconds => 2,
  );

  Overnet::Burner::Worker::Flooder->new(input => $input)->run;

  my $events = _events($run_dir, 'flooder-001');
  ok @{$events} >= 4, 'the flood produced many attempts' or diag(scalar @{$events});

  my @operations = grep { $_->{operation} ne 'flood_publish' } @{$events};
  is \@operations, [], 'every event is a flood_publish operation';

  my @defended = grep { $_->{defended} } @{$events};
  my @accepted = grep { !$_->{defended} } @{$events};
  ok @accepted >= 1, 'the first events under the limit were accepted (a defense gap)';
  ok @defended >= 1, 'the flood above the limit was defended';

  my @correct = grep { $_->{defended} && !$_->{defended_correct} } @{$events};
  is \@correct, [], 'every defended flood used a resource-protection category';

  my ($rate_limited) = grep { $_->{defended} } @{$events};
  is $rate_limited->{outcome},        'rejected',         'a limited flood is a rejection';
  is $rate_limited->{error_category}, 'policy rejection', 'rate limiting is a policy rejection';
  is $rate_limited->{status},         'error',            'a limited flood is an error status';
};

subtest 'malformed_publisher measures signature validation honestly' => sub {
  my $port  = _free_port();
  my $relay = Net::Nostr::Relay->new;
  $relay->start('127.0.0.1', $port);

  my $run_dir = _run_layout('malformed-publisher-001');
  my $input   = _worker_input(
    $run_dir, $port,
    worker_id        => 'malformed-publisher-001',
    role             => 'malformed_publisher',
    abuse            => {malformed_publisher => {publish_rate_per_second => 10}},
    duration_seconds => 1,
  );

  Overnet::Burner::Worker::MalformedPublisher->new(input => $input)->run;

  my $events = _events($run_dir, 'malformed-publisher-001');
  ok @{$events} >= 1, 'the malformed publisher made attempts';

  my @not_defended = grep { !$_->{defended} } @{$events};
  is \@not_defended, [], 'a signature-verifying relay rejected every malformed event';

  my @wrong_category = grep { $_->{error_category} ne 'invalid input' } @{$events};
  is \@wrong_category, [], 'every rejection was categorized as invalid input';

  my @incorrect = grep { !$_->{defended_correct} } @{$events};
  is \@incorrect, [], 'every defense used the correct category';

  is $events->[0]{operation}, 'malformed_publish', 'operation is malformed_publish';
  is $events->[0]{outcome},   'rejected',          'a malformed event is rejected';
};

subtest 'replayer measures idempotency honestly' => sub {
  my $port  = _free_port();
  my $relay = Net::Nostr::Relay->new;
  $relay->start('127.0.0.1', $port);

  my $run_dir = _run_layout('replayer-001');
  my $input   = _worker_input(
    $run_dir, $port,
    worker_id        => 'replayer-001',
    role             => 'replayer',
    abuse            => {replayer => {publish_rate_per_second => 10}},
    duration_seconds => 1,
  );

  Overnet::Burner::Worker::Replayer->new(input => $input)->run;

  my $events = _events($run_dir, 'replayer-001');
  ok @{$events} >= 1, 'the replayer resubmitted the seeded event';

  my @operations = grep { $_->{operation} ne 'replay_submit' } @{$events};
  is \@operations, [], 'every measured event is a replay_submit';

  my @not_defended = grep { !$_->{defended} } @{$events};
  is \@not_defended, [], 'a deduplicating relay defended every replay';

  is $events->[0]{outcome}, 'accepted', 'a duplicate replay is accepted idempotently, not stored anew';
  my @wrong = grep { !$_->{defended_correct} } @{$events};
  is \@wrong, [], 'explicit duplicate handling is the correct defense';
};

done_testing;

sub _worker_input {
  my ($run_dir, $port, %args) = @_;
  my $abuse = delete $args{abuse};
  return {
    input_version    => 1,
    run_id           => 'abuse-test-001',
    run_dir          => $run_dir,
    worker_id        => $args{worker_id},
    role             => $args{role},
    seed             => 12345,
    duration_seconds => $args{duration_seconds},
    metric_stream    => "metrics/$args{worker_id}.jsonl",
    ready_file       => "workers/$args{worker_id}/ready",
    endpoints        => {relays => ["ws://127.0.0.1:$port"]},
    workload         => {abuse  => $abuse},
  };
}

sub _events {
  my ($run_dir, $worker_id) = @_;
  return Overnet::Burner::Metrics->read_stream(File::Spec->catfile($run_dir, 'metrics', "$worker_id.jsonl"));
}

sub _run_layout {
  my ($worker_id) = @_;
  my $run_dir = tempdir(CLEANUP => 1);
  make_path(File::Spec->catdir($run_dir, 'metrics'));
  make_path(File::Spec->catdir($run_dir, 'workers', $worker_id));
  return $run_dir;
}

sub _free_port {
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
    or die "listen: $!";
  my $port = $listener->sockport;
  close $listener or die "close: $!";
  return $port;
}
