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
- **Rex orchestrates; workers measure.** [Rex](https://www.rexify.org/) owns
  machine and process orchestration. Dedicated worker processes generate load
  and record measurements.

## Usage

```text
overnet-burner validate   --scenario scenarios/single-relay-baseline.yml
overnet-burner render-rex --scenario scenarios/single-relay-baseline.yml [--runs-dir runs] [--run-id ID]
overnet-burner report     --run-dir runs/RUN_ID
```

Scenarios are human-authored YAML; see
[scenarios/single-relay-baseline.yml](scenarios/single-relay-baseline.yml)
for the baseline shape (topology, workload, chaos schedule, thresholds).

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
  commands, judged as chaos experiments in the report
- workload phases (warmup / main / cooldown, thresholds judged on the main
  phase only)
- the observer reference worker (relay-side black-box evidence via
  relay_ping probes of every endpoint)

- the guest interface with the local exec transport and the connect (SSH),
  container (Docker and podman, one engine adapter), and virtual (direct
  QEMU with cloud-init and hardware requirements) provisioning methods for
  workers, with deterministic placement recorded in guests.json
- network chaos actions (net-delay, net-loss, partition, heal) on
  bridge-networked container guests, with post-action evidence recorded in
  the run ledger ([docs/chaos.md](docs/chaos.md))
- abuse simulation: the flooder, malformed publisher, replayer, and
  subscription abuser adversarial worker roles, judged as an abuse
  experiment that measures both relay defenses and their blast radius on
  honest traffic ([docs/abuse.md](docs/abuse.md))

In progress, in decided order:

- guest provisioning continued: connect/container/virtual for relay
  guests (design in [docs/provisioning.md](docs/provisioning.md) and
  [docs/distributed.md](docs/distributed.md))
- abuse simulation continued: the sybil, provenance forger, and connection
  flood roles (design in [docs/abuse.md](docs/abuse.md))

## Testing

```bash
prove -r t/
prove -r xt/author/
```

## License

See [LICENSE](LICENSE).
