# overnet-burner — Project Instructions

This repository contains `overnet-burner`, the Rex-based system-test harness
for large-scale Overnet performance measurement and chaos testing. The design
document is [docs/PROPOSAL.md](docs/PROPOSAL.md); read it before making
architectural changes.

The [Overnet specification](https://github.com/overnet-project/spec) remains
authoritative for protocol correctness. `overnet-burner` measures behavior
under load and failure; it must not redefine protocol correctness or treat
its findings as normative spec text.

## Priorities

When rules conflict, follow this order:

1. Correctness of measurement — a wrong number is worse than no number
2. Implementation-neutrality — see below; this is never traded away
3. Stability of published contracts (report, metric events, provider and
   worker interfaces)
4. Reproducibility — every run must be reproducible from its recorded ledger
5. Flexibility and generality of scenarios, topologies, and workloads
6. Test coverage and documentation completeness
7. Local style rules

## Implementation-Neutrality

`overnet-burner` is the fundamental Overnet testing tool above the unit-test
layer, for every Overnet developer and deployment. Overnet applications can
be written in any language.

Rules:

- The system under test plugs in through the topology provider contracts and
  is judged only by observable Overnet behavior against the specification —
  never by language, runtime, framework, or repository layout.
- Every interface that crosses a process boundary (metric events, provider
  descriptors, worker contracts, report output) MUST be defined as a
  language-neutral contract: a schema plus a document in `docs/`, with
  JSON/JSONL/YAML on the wire.
- The Perl modules in `lib/` are a reference implementation of those
  contracts. The contract documents and schemas are the normative home; the
  Perl code follows them, never the reverse.
- Nothing in a scenario, plan, run ledger, or report may assume the tested
  system is relay-perl, is written in Perl, or is an IRC deployment.

## Contract-First Workflow

For changes that affect any published contract:

1. Update or add the contract document in `docs/` and the schema in
   `schemas/`.
2. Update or add example artifacts in `examples/` and validate them against
   the schema.
3. Add or update tests, and confirm new cases fail for the expected reason.
4. Implement until tests pass.
5. Re-run the relevant tests before considering the work done.

Report compatibility rules are defined in [docs/REPORT.md](docs/REPORT.md).
In short: compatible v1 changes may add optional fields and extensions;
anything that removes, renames, re-types, or changes the meaning or units of
an existing field requires a new report version. The same discipline applies
to every versioned contract in `schemas/`.

## Architecture Boundaries

- Runners choose an execution backend. The guest interface (local `exec`,
  `connect` SSH, `container`, `virtual`) is the default substrate and owns
  transport: provisioning, process control, chaos execution, artifact
  collection, and cleanup run through it. Rex is the reference remote-execution
  backend — an opt-in path (see [docs/rex-backend.md](docs/rex-backend.md)) that
  a runner selects to deploy and lifecycle the system under test on real hosts,
  and it genuinely performs when selected. Neither backend is the load
  generator.
- Workers are dedicated processes that generate load and record measurements.
  Workers must emit structured metrics continuously and avoid controller
  round trips on hot paths.
- Runners decide how a plan is executed; topology providers describe what to
  run and observe.
- Every run creates an immutable run directory. Nothing may mutate a
  completed run directory.
- `report.json` is the automation contract; everything else in the run
  directory is evidence.

## Testing

Follow TDD strictly: write or update the contract, examples, and tests
first, confirm they fail, then implement until they pass.

Cover:

- valid and invalid cases, one rule at a time for rejections
- boundary conditions and empty inputs
- schema validation of every example artifact this repo publishes
- determinism: identical scenario and seed must produce identical plans and
  canonical artifacts

Run tests with:

```bash
prove -r t/
prove -r xt/author/
```

## Output Requirements

At the end of every task, report:

- files changed
- behavior changes
- contract changes (documents, schemas, examples)
- tests run
- anything not verified
- follow-up risks or edge cases still worth checking

Do not claim completion if the relevant tests were not run or if
contract/example/schema alignment was not checked.
