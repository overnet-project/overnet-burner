# overnet-burner

Rex-based scalable Overnet system-test harness.

GitHub: <https://github.com/overnet-project/overnet-burner>

`overnet-burner` measures the behavior of Overnet systems under realistic and
extreme load, and tests whether they recover correctly from failure while
under load. It is the fundamental Overnet testing tool above the unit-test
layer: scale behavior must be visible, repeatable, measurable, and difficult
to ignore.

The design is documented in [docs/PROPOSAL.md](docs/PROPOSAL.md).

## Key Properties

- **Implementation-neutral.** Overnet applications can be written in any
  language. The system under test plugs in through
  [topology provider contracts](docs/topology-providers.md) and is judged by
  observable Overnet behavior against the
  [Overnet specification](https://github.com/overnet-project/spec) — never by
  language, runtime, or repository layout. The Perl modules in this
  distribution are a reference implementation of the burner's contracts, not
  the contracts themselves.
- **Correct above all.** Every run produces an immutable, reproducible run
  ledger with machine-readable artifacts. A wrong measurement is worse than
  no measurement.
- **Stable automation contract.** `report.json` is the stable machine-readable
  result of a run, defined by [docs/REPORT.md](docs/REPORT.md) and
  [schemas/report-v1.schema.json](schemas/report-v1.schema.json).
- **Guests execute; workers measure.** Runners execute a plan through the guest
  interface (local `exec`, `connect` SSH, `container`, `virtual`);
  [Rex](https://www.rexify.org/) is the opt-in reference remote-execution
  backend for deploying and lifecycling the system under test on real hosts (see
  [docs/rex-backend.md](docs/rex-backend.md)). Dedicated worker processes
  generate load and record measurements.

## Usage

```text
overnet-burner validate   --scenario scenarios/single-relay-baseline.yml
overnet-burner generate   --scenario-seed 42 [--profile profiles/local-smoke.yml] [--out scenario.yml]
overnet-burner generate-profile --profile-seed 1001 --profile-template profile-templates/local-containers.yml [--out profile.yml]
overnet-burner render-rex --scenario scenarios/single-relay-baseline.yml [--runs-dir runs] [--run-id ID]
overnet-burner run        --scenario scenarios/local-containers-smoke.yml --runner rex-local-workers [--verbose]
overnet-burner run        --random-scenario --scenario-seed 42 --profile profiles/local-smoke.yml --runner rex-local-workers [--verbose]
overnet-burner run        --random-profile --profile-seed 1001 --profile-template profile-templates/local-containers.yml --random-scenario --scenario-seed 42 --runner rex-local-workers [--verbose]
overnet-burner report     --run-dir runs/RUN_ID  # regenerate report.json
```

Scenarios are human-authored YAML; see
[scenarios/single-relay-baseline.yml](scenarios/single-relay-baseline.yml)
for the baseline shape (topology, workload, chaos schedule, thresholds).

Scenarios can also be generated: `generate` (and `run --random-scenario`)
produce a random-but-reproducible scenario within a profile envelope, judged
on invariants rather than fixed thresholds. `generate-profile` adds a layer
above that: it produces the profile envelope from a versioned template before
scenario generation. Endpoint-based profiles carry the relay endpoints and
lifecycle commands for the system under test; managed `local-containers`
profiles describe topology and let burner reify relay wiring. Same seeds,
same generated profile and scenario, forever. See
[docs/generate.md](docs/generate.md) and
[docs/profile-generation.md](docs/profile-generation.md).

Every `run` writes `report.json` before it exits. The separate `report`
command exists for regenerating that artifact from an existing run directory.
Pass `--verbose` to `run` to stream runner lifecycle, Rex, provider, worker,
chaos, and provisioning progress to standard error while keeping standard
output limited to the completed run and report paths.

For a self-contained local run, use
[scenarios/local-containers-smoke.yml](scenarios/local-containers-smoke.yml).
Its `environment.kind: local-containers` asks burner to build the reference
Overnet image, start relay and worker containers on a per-run network,
synthesize relay endpoints, run the workload, collect evidence, and tear
everything down. The lower-level `provision` block remains available for
expert scenarios that intentionally bring their own images, commands, or
remote guests. See [docs/environments.md](docs/environments.md).

## Status

Implemented so far:

- scenario loading, normalization, and validation
- deterministic run plans, including per-actor metric stream declarations
- immutable run ledger creation
- topology provider descriptors and the external-command provider
- Rex bundle rendering and the noop / rex-local runners
- report v1 generation with schema, artifacts, and threshold records
- the metric event contract with summarization and real threshold evaluation
- the worker contract and the reference publisher, subscriber, query reader,
  and object reader workers, covering publish, live fanout, query, and
  derived object read measurement
- the rex-local-workers runner: end-to-end local runs with real workers
- scheduled chaos hooks executed through topology provider lifecycle
  commands, judged as one mechanism of a resilience experiment in the report
- workload phases (warmup / main / cooldown, thresholds judged on the main
  phase only)
- the observer reference worker (relay-side black-box evidence via
  relay_ping probes of every endpoint)

- the guest interface with the local exec transport and the connect (SSH),
  container (Docker and podman, one engine adapter), and virtual (direct
  QEMU with cloud-init and hardware requirements) provisioning methods for
  workers, with deterministic placement recorded in guests.json
- relay-guest provisioning over `connect`: relays can run on their own SSH
  guests, with their topology-provider lifecycle (start / health / stop) run
  on the relay guest through the one-shot `run_command` guest primitive and
  placement recorded in relay-guests.json
  ([docs/provisioning.md](docs/provisioning.md))
- managed local-container environments: a scenario can declare
  `environment.kind: local-containers` and let burner build the reference
  image, provision relay and worker containers, wire relay endpoints through
  stable network aliases, and clean up the run network
  ([docs/environments.md](docs/environments.md))
- network chaos actions (net-delay, net-loss, partition, heal) on
  bridge-networked container guests, with post-action evidence recorded in
  the run ledger ([docs/chaos.md](docs/chaos.md))
- abuse simulation: the flooder, malformed publisher, replayer,
  subscription abuser, sybil, connection flood, and provenance forger
  adversarial worker roles. Abuse and chaos are the two mechanisms of a
  single **resilience experiment**, judged together against defense and
  collateral (blast-radius) thresholds; the report records which mechanisms
  ran in `run.perturbations`. The provenance forger measures a consumer-side
  provenance verification boundary (Overnet core section 7.9) rather than a
  relay defense, using the `Overnet::Burner::Provenance` reference oracle
  ([docs/abuse.md](docs/abuse.md))
- distributed scale-out: a run is distributed by provisioning its worker and
  relay groups onto `connect` guests, which places actors across many hosts,
  launches and collects them remotely, and runs relay lifecycle on the relay
  guest. Cross-host clock discipline records each guest's clock offset in
  `clocks.json` and the report flags `subscription_fanout` numbers whose
  hosts' clocks were unverified or skewed beyond the fanout budget
  ([docs/distributed.md](docs/distributed.md))
- deterministic scenario and profile generation: `generate` and
  `run --random-scenario` produce a random-but-reproducible scenario within a
  profile envelope (managed environment, relay wiring, roles, rates,
  duration, lifecycle chaos when provider commands are supplied, abuse mix).
  `generate-profile` and `run --random-profile` produce that envelope from a
  versioned template first. Generated runs record the template, generated
  profile, and generated scenario needed for an immediate repro
  ([docs/generate.md](docs/generate.md),
  [docs/profile-generation.md](docs/profile-generation.md))

In progress, in decided order:

- guest provisioning continued: virtual relay guests, non-reference images,
  and broader reuse flows beyond the managed local-container reference stack
  (design in [docs/provisioning.md](docs/provisioning.md) and
  [docs/distributed.md](docs/distributed.md))

## Testing

```bash
prove -r t/
prove -r xt/author/
```

## AI Usage

This code was developed in part with AI tooling such as Claude Code and Codex. We want to be upfront about that.

## License

See [LICENSE](LICENSE).
