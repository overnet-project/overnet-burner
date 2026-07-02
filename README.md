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
- the worker contract and the reference publisher, subscriber, and query
  reader workers, including live fanout and query latency measurement
- the rex-local-workers runner: end-to-end local runs with real workers

In progress, in proposal order:

- the object reader reference worker
- chaos subsystem and distributed scale mode

## Testing

```bash
prove -r t/
prove -r xt/author/
```

## License

See [LICENSE](LICENSE).
