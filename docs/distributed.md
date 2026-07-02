# overnet-burner Distributed Scale Mode (Design)

**Status: proposed design.** Nothing in this document is normative until it
is implemented and tested; where it conflicts with the implemented
contracts ([workers.md](workers.md), [METRICS.md](METRICS.md),
[chaos.md](chaos.md), [topology-providers.md](topology-providers.md)),
the implemented contracts win.

## Goal

Run the same scenarios that work locally across many hosts — thousands of
workers against relay clusters — without changing any contract a worker or
topology provider already honors. A distributed run must remain
reproducible, judged by the same report rules, and honest about the new
failure modes distribution introduces.

## Design Principles

1. **The worker contract does not change.** A worker still reads one input
   document named by `OVERNET_BURNER_WORKER_INPUT`, writes a ready file,
   appends to its metric stream, and honors the existing exit and
   connection-loss semantics. Distribution is entirely the runner's
   problem. Any contract-compliant worker binary, in any language, works
   unmodified on a remote host.
2. **Rex owns machine orchestration.** Host access, file transfer, and
   remote process control go through Rex tasks rendered into the existing
   Rex bundle; the burner controller never shells into hosts ad hoc.
3. **Determinism survives distribution.** Actor placement is a pure
   function of the plan and the host inventory, recorded in the run
   ledger. The same scenario, seed, and inventory place the same actors on
   the same hosts.
4. **Evidence is collected, never trusted blindly.** Remote metric streams
   are fetched to the run directory before reporting; a stream that cannot
   be fetched is a missing stream, and the report's existing rules
   (`collected`, `inconclusive_partial_run`) apply unchanged.

## Host Inventory

The scenario gains an optional `hosts` section (exact shape to be settled
during implementation):

```yaml
hosts:
  workers:
    - ssh://load-1.example.net
    - ssh://load-2.example.net
  relays:
    - ssh://relay-1.example.net
```

Local mode remains the default: without `hosts`, everything runs on the
controller host exactly as today. The rendered Rex inventory
(`artifacts/rex/inventory/hosts.json`) stops being the static single-host
placeholder and reflects the declared hosts.

## Placement

The plan's actor list is placed onto worker hosts round-robin by actor
ordinal within each role — the same deterministic rotation idiom used for
relay assignment. Placement lands in the existing
`artifacts/rex/actor-hosts.json` (which already models
actor-to-host assignments) and in the report's topology section.

## Remote Worker Launch

A new `rex-distributed` runner extends the workers runner:

- **Stage**: push each actor's `workers/<actor-id>/input.json` and the
  worker executable (or a named, pre-provisioned binary) to its host.
- **Launch**: start workers remotely with `OVERNET_BURNER_WORKER_INPUT`
  set, capturing stdout/stderr to host-local files.
- **Readiness**: poll ready files remotely with the same two-wave
  sequencing (subscribers and readers before publishers) across all hosts.
  The workload window opens when every worker on every host is ready.
- **Exit**: wait for orderly exits within duration plus grace, with the
  same TERM/KILL escalation, executed remotely.

Paths inside the worker input document (`run_dir`, `metric_stream`,
`ready_file`) refer to the host-local staging directory on the worker's
host; the contract already makes them opaque to workers.

## Collection

After the workload window closes, the runner fetches each actor's metric
stream and logs back into the controller's run directory, then aggregates
`metrics.jsonl` exactly as local runs do. Fetch failures leave the stream
missing and the run is judged accordingly — a distributed run that lost
its evidence must not report as if it had it.

## Chaos

Chaos hooks execute on the controller against topology provider lifecycle
commands, which may themselves address remote relays (the
external-command provider already runs arbitrary commands). Hook timing
and failure semantics are unchanged from [chaos.md](chaos.md).

## Clock Discipline

`subscription_fanout` compares clocks across hosts. A distributed run
SHOULD record each host's clock offset (for example an NTP query at run
start) in the run ledger, and the report SHOULD surface a diagnostic when
fanout thresholds are configured but clock offsets were not captured or
exceed a sanity bound. This is the honesty mechanism the fanout timing
convention in [workers.md](workers.md) already anticipates.

## Failure Semantics

- A host that cannot be staged or reached before launch fails the run
  (orchestration failure) — the experiment did not run as designed.
- A worker that dies mid-run fails the run under the existing
  workers-runner rule.
- Partial evidence (missing streams after fetch) yields the existing
  inconclusive verdicts rather than silently shrinking the denominator.

## Open Questions

- Worker provisioning: push the Perl reference workers, or require a
  pre-provisioned `overnet-burner-worker` on each host (likely both, with
  the pre-provisioned path preferred for non-Perl workers)?
- Live progress: whether the controller should sample remote metric
  streams mid-run for operator feedback, and how to do that without
  perturbing the workload.
- Scale of readiness polling: per-file SSH polling will not survive
  thousands of workers; a per-host readiness aggregator command is the
  probable answer.
