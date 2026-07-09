use strictures 2;

use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use Test2::V0;

use lib "$FindBin::Bin/../lib";

use Overnet::Burner::Config;
use Overnet::Burner::RexBundle;
use Overnet::Burner::RunLedger;
use Overnet::Burner::Util qw(read_json_file);
use YAML::PP;

# A scenario whose relay uses the external-command provider, so the rendered
# topology-provider bundle carries real start/health/stop command strings.
my $scenario_yaml = <<'YAML';
run:
  name: performed-bundle
  duration: 60
  seed: 13579

topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: touch {config}.started
      stop: rm -f {config}.started
      health: test -e {config}.started
  publishers:
    count: 0
  subscribers:
    count: 0
  query_readers:
    count: 0
  object_readers:
    count: 0

workload:
  publish_rate_per_second: 0
YAML

my $tmp = tempdir(CLEANUP => 1);
my $scenario_path = File::Spec->catfile($tmp, 'external.yml');
_write($scenario_path, $scenario_yaml);
my $scenario = Overnet::Burner::Config->load_file($scenario_path);

sub _plan_run_dir {
  my ($run_id) = @_;
  my $ledger = Overnet::Burner::RunLedger->create(
    scenario      => $scenario,
    scenario_path => $scenario_path,
    runs_dir      => File::Spec->catdir($tmp, $run_id),
    run_id        => $run_id,
    now           => sub {'2026-07-09T14:00:00Z'},
    host_facts    => {hostname => 'builder', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  return ($ledger->{run_dir}, Overnet::Burner::RunLedger->load_plan($ledger->{run_dir}));
}

subtest 'planned mode is unchanged and remains the default' => sub {
  my ($run_dir, $plan) = _plan_run_dir('planned');
  Overnet::Burner::RexBundle->render(run_dir => $run_dir, plan => $plan);

  my $bundle_dir = File::Spec->catdir($run_dir, 'artifacts', 'rex');
  my $rexfile    = _read($bundle_dir, 'Rexfile');
  like $rexfile, qr/planned\ overnet-burner\ phase/mx, 'default render keeps the planned placeholder tasks';

  my $index = read_json_file(File::Spec->catfile($bundle_dir, 'bundle.json'));
  is $index->{execution}{remote_execution}, 'not_performed', 'default render is not performed';
};

subtest 'performed mode over ssh renders a real, executable Rexfile' => sub {
  my ($run_dir, $plan) = _plan_run_dir('performed-ssh');
  my $result = Overnet::Burner::RexBundle->render(
    run_dir   => $run_dir,
    plan      => $plan,
    execution => 'performed',
    inventory => {transport => 'ssh', host => 'relay.example', user => 'burner', key => '/keys/id_ed25519'},
  );

  is $result->{remote_execution}, 'remote', 'renderer reports remote execution for an ssh target';

  my $bundle_dir = File::Spec->catdir($run_dir, 'artifacts', 'rex');
  my $rexfile    = _read($bundle_dir, 'Rexfile');

  unlike $rexfile, qr/planned\ overnet-burner\ phase/mx, 'performed render drops the print placeholders';
  like $rexfile,   qr/use\ Rex/mx,                       'performed render is a real Rexfile';
  like $rexfile,   qr/private_key\ '\/keys\/id_ed25519'/mx, 'performed render configures key authentication';
  like $rexfile,   qr/key_auth/mx,                       'performed render forces key auth';
  like $rexfile,   qr/group\ 'relays'\ =>\ 'relay[.]example'/mx, 'performed render binds the relays group to the host';
  like $rexfile,   qr/task\ 'provider_command'/mx,       'performed render exposes a provider-command task';
  like $rexfile,   qr/run\ \$ENV\{OVERNET_BURNER_REX_COMMAND\}/mx, 'the task runs the command it is handed';

  my $index = read_json_file(File::Spec->catfile($bundle_dir, 'bundle.json'));
  is $index->{execution}{remote_execution}, 'remote', 'bundle index records remote execution';

  my $lifecycle = read_json_file(File::Spec->catfile($bundle_dir, 'lifecycle.json'));
  is [map { $_->{execution} } @{$lifecycle->{commands}}], [('performed') x 8], 'lifecycle commands are performed';

  my $topology = read_json_file(File::Spec->catfile($bundle_dir, 'topology-provider.json'));
  is $topology->{relays}[0]{lifecycle}{start}{execution}, 'performed', 'provider start is performed';
  is $topology->{relays}[0]{lifecycle}{stop}{execution},  'performed', 'provider stop is performed';
  is $topology->{relays}[0]{lifecycle}{health}{execution}, 'performed', 'provider health is performed';
};

subtest 'performed mode against the controller renders a local task and reports local execution' => sub {
  my ($run_dir, $plan) = _plan_run_dir('performed-local');
  my $result = Overnet::Burner::RexBundle->render(
    run_dir   => $run_dir,
    plan      => $plan,
    execution => 'performed',
    inventory => {transport => 'local'},
  );

  is $result->{remote_execution}, 'local', 'a controller-local target reports local execution';

  my $bundle_dir = File::Spec->catdir($run_dir, 'artifacts', 'rex');
  my $rexfile    = _read($bundle_dir, 'Rexfile');
  like $rexfile,   qr/task\ 'provider_command'/mx, 'local performed render still exposes the task';
  unlike $rexfile, qr/private_key/mx,              'local performed render needs no ssh key';

  my $index = read_json_file(File::Spec->catfile($bundle_dir, 'bundle.json'));
  is $index->{execution}{remote_execution}, 'local', 'bundle index records local execution';
};

subtest 'performed mode renders a Rex deploy task from the descriptor' => sub {
  my $deploy_scenario_path = File::Spec->catfile($tmp, 'deploy.yml');
  _write($deploy_scenario_path, _deploy_scenario_yaml());
  my $deploy_scenario = Overnet::Burner::Config->load_file($deploy_scenario_path);

  my $ledger = Overnet::Burner::RunLedger->create(
    scenario      => $deploy_scenario,
    scenario_path => $deploy_scenario_path,
    runs_dir      => File::Spec->catdir($tmp, 'deploy-run'),
    run_id        => 'deploy',
    now           => sub {'2026-07-09T14:00:00Z'},
    host_facts    => {hostname => 'builder', os => 'linux', arch => 'x86_64'},
    repo_sha      => 'abc123',
    rex_version   => undef,
  );
  my $run_dir = $ledger->{run_dir};
  my $plan    = Overnet::Burner::RunLedger->load_plan($run_dir);

  Overnet::Burner::RexBundle->render(
    run_dir   => $run_dir,
    plan      => $plan,
    execution => 'performed',
    inventory => {transport => 'ssh', host => 'relay.example', user => 'burner', key => '/keys/id'},
  );

  my $bundle_dir = File::Spec->catdir($run_dir, 'artifacts', 'rex');
  my $rexfile    = _read($bundle_dir, 'Rexfile');
  like $rexfile, qr/task\ 'deploy'/mx,                    'performed render exposes a deploy task';
  like $rexfile, qr/file\ '\/etc\/overnet\/relay[.]conf'/mx, 'the deploy task places the destination file';
  like $rexfile, qr/source\ =>/mx,                        'the deploy task copies from a source';

  my $topology = read_json_file(File::Spec->catfile($bundle_dir, 'topology-provider.json'));
  is $topology->{relays}[0]{deploy}{files}[0]{dest}, '/etc/overnet/relay.conf', 'topology provider records the deploy file';
  is $topology->{relays}[0]{deploy}{execution},      'performed',               'the deploy block is performed';
};

subtest 'a performed render without a deploy renders no deploy task' => sub {
  my ($run_dir, $plan) = _plan_run_dir('no-deploy');
  Overnet::Burner::RexBundle->render(
    run_dir   => $run_dir,
    plan      => $plan,
    execution => 'performed',
    inventory => {transport => 'local'},
  );
  my $rexfile = _read(File::Spec->catdir($run_dir, 'artifacts', 'rex'), 'Rexfile');
  unlike $rexfile, qr/task\ 'deploy'/mx, 'no deploy task when the descriptor has none';
};

done_testing;

sub _deploy_scenario_yaml {
  my $scenario = {
    run      => {name => 'performed-deploy', duration => 60, seed => 13579},
    topology => {
      relays => {
        count    => 1,
        provider => 'external-command',
        command  => {start => 'true', stop => 'true', health => 'true'},
        deploy   => {files => [{source => 'relay.conf', dest => '/etc/overnet/relay.conf'}]},
      },
      publishers     => {count => 0},
      subscribers    => {count => 0},
      query_readers  => {count => 0},
      object_readers => {count => 0},
    },
    workload => {publish_rate_per_second => 0},
  };
  return YAML::PP->new(boolean => 'perl', schema => ['Core'])->dump_string($scenario);
}

sub _write {
  my ($path, $content) = @_;
  open my $fh, '>', $path or die "open $path: $!";
  print {$fh} $content;
  close $fh or die "close $path: $!";
  return;
}

sub _read {
  my ($dir, $name) = @_;
  my $path = File::Spec->catfile($dir, $name);
  open my $fh, '<', $path or die "open $path: $!";
  local $/ = undef;
  my $content = <$fh>;
  close $fh or die "close $path: $!";
  return $content;
}
