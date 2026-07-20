# overnet-burner Proposal

## Purpose

`overnet-burner` is a standalone Rex-based test system for large-scale
Overnet performance measurement and chaos testing.

Overnet must scale. This project exists to make scale behavior visible,
repeatable, measurable, and difficult to ignore.

The system must be general and configurable. It must not be tied to one
Overnet application, one deployment shape, or one reference implementation.
The first implementation target may be the Perl reference stack, but the
architecture must support arbitrary Overnet-compatible relays, workers,
adapters, and deployment environments.

## Primary Goals

### Scale And Performance Measurement

`overnet-burner` must measure the behavior of Overnet systems under realistic
and extreme load.

Core measurements include:

- publish throughput
- publish acceptance and rejection latency
- query latency
- subscription replay latency
- `EOSE` latency
- live subscription fanout latency
- subscriber lag
- negentropy sync cost and convergence
- object-read latency
- relay CPU, memory, disk, network, and store growth
- error rates and rejection reason distribution

Performance at large scale is not optional polish for Overnet. It is a core
success condition.

### Chaos Testing

`overnet-burner` must test whether Overnet systems recover correctly while
under load.

Core chaos cases include:

- relay kill and restart during active publish and subscription load
- relay sync interruption and reconvergence
- subscriber disconnect and reconnect storms
- publisher bursts and overload pressure
- network partition, latency, loss, and recovery
- backup and restore drills under real relay state
- resource pressure where it can be injected safely and cleaned up reliably

Chaos behavior must be measured, not just triggered. Each fault should have a
timestamped event record, observed impact, recovery signal, and recovery time.

## Non-Goals

`overnet-burner` is not:

- a replacement for protocol conformance tests
- an application-specific IRC test harness
- a relay implementation
- a spec authority
- a deployment product
- a thin pile of ad hoc shell commands

The Overnet specification remains authoritative. `overnet-burner` measures
behavior under load and failure; it must not redefine protocol correctness.

## Rex Role

`overnet-burner` will heavily rely on [Rex](https://www.rexify.org/).

Rex should own orchestration:

- host inventory
- remote setup
- process deployment
- process start and stop
- chaos action execution
- artifact collection
- cleanup

Rex should not be the high-volume load generator.

The benchmark engine needs dedicated worker processes for high-volume
WebSocket traffic, subscriptions, sync cycles, object reads, and metrics.
Creating one Rex task per simulated client will not scale and would make Rex
itself the bottleneck.

The correct split is:

- Rex coordinates machines and processes.
- Burner workers generate load and record measurements.
- Burner reporting code analyzes and summarizes the run.

## Hard Boundaries

- The system must be general and configurable.
- The system must not be tied to IRC, relay-perl, or a specific deployment.
- The Perl reference relay may be an early topology target, not the architecture.
- The guest interface is the default execution substrate; Rex is the opt-in
  reference remote-execution backend for real-host deployment (see
  [rex-backend.md](rex-backend.md)). Runners choose the backend a plan uses.
- Scenario definitions must be portable across environments.
- Every run must be reproducible from its recorded manifest.
- Every run must produce machine-readable artifacts.
- Large-scale behavior must be treated as a first-class result, not an
  informal observation.

## Relevant Overnet Surfaces

The first relay-oriented scenarios should focus on the generic relay behavior
defined by the [Overnet relay specification](https://github.com/overnet-project/spec/blob/main/docs/relay.md).

Important surfaces include:

- Overnet event publication
- structured acceptance and rejection
- baseline event query filters
- replay plus live subscriptions
- NIP-77 negentropy reconciliation
- derived object reads
- relay metadata, capabilities, limits, and policy

The relay specification currently leaves relay peering policy, topology,
scheduling, and filter selection strategy open. `overnet-burner` should be able
to explore those areas without treating its findings as normative spec text.

## Topology Providers

Topology providers are the implementation-under-test boundary. A topology
provider may be the Perl reference relay, a Python implementation, a container
image, an external command, a remote service, or another Overnet-compatible
system.

`overnet-burner` must judge topology providers by observable Overnet behavior,
performance, and recovery against the Overnet specification, not by language,
runtime, framework, or repository layout.

Topology providers should supply the information needed to place them into a
Rex execution bundle:

- process or container start commands
- stop and cleanup commands
- configuration and environment inputs
- readiness and health checks
- network endpoints
- logs, metrics, state, and artifact locations
- implementation version metadata

The guest interface is the default execution substrate, and Rex is the opt-in
reference remote-execution backend for real-host deployment. Topology providers
describe what should be run and observed; burner runners decide which backend
orchestrates that work across machines.

The initial provider descriptor contracts are documented in
[`topology-providers.md`](topology-providers.md).

## Architecture

### Top-Level Shape

The project should have this shape:

```text
Rexfile
bin/overnet-burner
docs/
examples/
lib/Overnet/Burner/
scenarios/
t/
```

### Rexfile

The `Rexfile` should stay thin.

Expected Rex task groups:

- `bootstrap`
- `deploy`
- `start`
- `warmup`
- `run`
- `chaos`
- `collect`
- `cleanup`

Rex tasks should call into burner libraries or command-line tools instead of
embedding benchmark logic directly in the Rexfile.

### Command-Line Interface

`bin/overnet-burner` should be the main user entry point.

Expected commands:

```text
overnet-burner validate --scenario scenarios/example.yml
overnet-burner render-rex --scenario scenarios/example.yml
overnet-burner run --scenario scenarios/example.yml
overnet-burner summarize --run runs/<run-id>
overnet-burner compare --baseline runs/<run-a> --candidate runs/<run-b>
```

### Perl Modules

Initial module boundaries:

- `Overnet::Burner::Config`
- `Overnet::Burner::Topology`
- `Overnet::Burner::Scenario`
- `Overnet::Burner::Runner`
- `Overnet::Burner::Worker`
- `Overnet::Burner::Metrics`
- `Overnet::Burner::Chaos`
- `Overnet::Burner::Report`
- `Overnet::Burner::RunLedger`

These names are provisional, but the boundaries are important.

## Worker Roles

Workers should be long-running processes controlled by Rex and the burner
controller.

Initial worker roles:

- relay process
- publisher
- subscriber
- query reader
- object reader
- syncer
- observer
- chaos agent

Workers must emit structured metrics continuously. They should avoid
controller round trips on hot paths.

## Scenario Configuration

Scenario files should be human-authored YAML. Run outputs should be JSON,
JSONL, and Markdown.

Example scenario shape:

```yaml
run:
  name: relay-fanout-smoke
  duration: 300
  seed: 12345

topology:
  relays:
    count: 3
    provider: generic-relay
  publishers:
    count: 100
  subscribers:
    count: 1000

workload:
  publish_rate_per_second: 500
  subscription_filters:
    - kinds: [37800]
      "#overnet_ot": ["chat.channel"]

chaos:
  - at: 120
    action: restart
    target: relay:1

thresholds:
  publish_p99_ms: 250
  subscription_fanout_p99_ms: 1000
  error_rate_max: 0.01
```

The config model must eventually support:

- single-host local smoke runs
- multi-host distributed runs
- multiple relay implementations
- multiple topology shapes
- load phases
- warmup and cooldown periods
- deterministic data generation
- chaos schedules
- pass/fail thresholds
- artifact retention policy

## Run Ledger And Reproducibility

Every run must create an immutable run directory.

Each run directory should include:

- scenario file snapshot
- normalized resolved config
- run ID
- wall-clock start and stop timestamps
- random seed
- controller host facts
- worker host facts
- git SHAs for involved repositories when available
- relevant tool and Perl versions
- Rex version
- topology provider and runner versions
- worker logs
- raw JSONL metrics
- summarized metrics
- final pass/fail result

Without this ledger, performance numbers will not be trustworthy.

## Metrics Model

Raw metrics should be newline-delimited JSON, one event or sample per line.

Metric events should include:

- `run_id`
- `worker_id`
- `host`
- `role`
- `operation`
- `started_at`
- `finished_at`
- `duration_ms`
- `status`
- operation-specific fields

Operation-specific fields should cover:

- published event ID
- relay URL
- subscription ID
- filter shape or filter hash
- query result count
- `EOSE` time
- live fanout receive time
- object type and object ID
- HTTP status
- negentropy round count
- negentropy bytes where available
- needed, fetched, and stored event counts
- rejection reason prefix

System samples should include:

- CPU
- RSS
- file descriptor count
- disk usage
- store size
- network counters where available

## Reports

Each run should produce:

- raw JSONL metrics
- summary JSON
- Markdown report
- threshold pass/fail result

Reports should show:

- throughput
- p50, p95, p99, and max latency
- error rates
- fanout lag
- sync convergence time
- chaos timeline
- recovery time
- resource growth
- threshold failures

Comparison reports should make regressions obvious.

## Initial Scenario Set

### `single-relay-baseline`

One relay, publishers, subscribers, queries, and object reads.

Purpose:

- prove the end-to-end measurement loop
- establish baseline relay costs
- validate result artifacts

### `fanout-pressure`

Many subscribers watch overlapping filters while publishers generate matching
events.

Purpose:

- measure live subscription fanout
- detect subscriber lag
- expose per-subscription memory or CPU growth

### `store-growth-query`

A relay accumulates a large visible event store, then serves repeated queries
and object reads.

Purpose:

- measure query degradation as store size grows
- measure object-read behavior at scale
- identify indexing and persistence bottlenecks

### `sync-pair`

Two relays receive asymmetric writes (one publisher per relay) and a
`sync_bridge` worker reconciles them to the union of their event sets through
negentropy fetch-and-push. Implemented; see the `sync_bridge` worker in
[workers.md](workers.md) and `scenarios/sync-pair.yml`.

Purpose:

- measure sync rounds (`sync_converge` `rounds`)
- measure missing/fetched/stored event counts (`fetched_count`, `pushed_count`)
- verify convergence after asymmetric writes

### `sync-mesh`

Multiple relays receive staggered writes and sync over a configurable topology.

Purpose:

- measure convergence across larger relay graphs
- expose topology and scheduling bottlenecks

### `chaos-restart-under-load`

A relay is killed and restarted while publishers and subscribers continue.

Purpose:

- measure downtime
- measure reconnect behavior
- measure replay and recovery impact

### `partition-and-recover`

Connectivity between parts of the topology is interrupted and later restored.
Implemented as a composition of managed container provisioning, the network
chaos hooks ([chaos.md](chaos.md)), and the `sync_bridge` worker: a `partition`
hook cuts a worker guest off the per-run bridge network mid-run and a later
`heal` reconnects it, while a `sync_bridge` runs throughout as the convergence
verifier. Writes on the cut-off guest fail for the outage; after the heal the
relays reconverge, which the bridge's `sync_converge` metrics confirm. Network
chaos requires container-provisioned workers on a bridge network, so this runs
under the managed local-containers path; see `scenarios/partition-and-recover.yml`.

Purpose:

- measure behavior during partition (failed operations on the cut-off guest)
- measure post-partition sync convergence (the bridge's `fetched_count` /
  `pushed_count` catching the lagging relay up after the heal)
- detect stale or missing visible state

Relay-to-relay partition (cutting selected relay pairs rather than a whole
guest) remains future work, as noted in [chaos.md](chaos.md).

## Implementation Plan

### Phase 1: Project Skeleton

Create:

- `AGENTS.md`
- `README.md`
- `Makefile.PL`
- `Rexfile`
- `bin/overnet-burner`
- `lib/Overnet/Burner/*`
- `scenarios/*.yml`
- `t/*`

The first test coverage should focus on config parsing, validation, and run
ledger creation.

### Phase 2: Local Single-Host Smoke Run

Build the smallest useful run:

- start one relay
- start one publisher worker
- start one subscriber worker
- publish valid Overnet events
- observe replay plus live delivery
- collect JSONL metrics
- produce summary JSON

This phase proves whether the measurement loop is truthful.

### Phase 3: Config Validation And Run Ledger

Add:

- strict scenario validation
- normalized config output
- immutable run directory creation
- tool and version capture
- scenario snapshotting
- seed handling

### Phase 4: Worker Framework

Add worker infrastructure:

- async WebSocket clients
- deterministic event generation
- publisher role
- subscriber role
- query reader role
- object reader role
- syncer role
- structured metrics writer

Workers must be able to run locally or remotely without changing scenario
semantics.

### Phase 5: Rex Orchestration

Add Rex tasks for:

- host inventory
- remote dependency checks
- artifact directory setup
- worker deployment
- process start
- process stop
- chaos execution
- artifact collection
- cleanup

The Rexfile should remain orchestration glue, not benchmark logic.

### Phase 6: Reporting

Add:

- summary JSON
- Markdown report
- threshold evaluation
- run comparison
- regression highlighting

### Phase 7: Chaos Subsystem

Start with safe process-level chaos:

- kill worker
- restart worker
- stop relay
- restart relay
- pause sync worker
- resume sync worker

Network chaos should be added later and must be explicit opt-in because it may
require elevated host privileges and can disrupt shared systems.

### Phase 8: Distributed Scale Mode

Add support for:

- remote worker placement
- multi-host artifact collection
- high-volume metric buffering
- controller bottleneck avoidance
- large run cleanup

Distributed mode should not be started until local mode produces trustworthy
measurements.

## Open Design Questions

- Should the first topology provider interface target relay command lines,
  service managers, or containers?
- What is the minimum common relay control API needed across implementations?
- How should large raw metric files be compacted for long runs?
- Should comparison reports enforce hard regression budgets in CI?
- Which chaos actions are safe enough to include by default?
- What scale target defines the first meaningful success milestone?

## Initial Recommendation

Start with the single-host smoke run and make the run ledger, metrics, and
summary report correct before adding distributed orchestration.

Scale systems fail when measurement is vague. `overnet-burner` should first
make one small run impossible to misinterpret, then grow from there.

## References

- [Rex](https://www.rexify.org/)
- [Overnet specification](https://github.com/overnet-project/spec)
- [Overnet relay specification](https://github.com/overnet-project/spec/blob/main/docs/relay.md)
- [relay-perl](https://github.com/overnet-project/relay-perl)
