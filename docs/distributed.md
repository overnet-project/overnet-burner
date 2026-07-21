# overnet-burner Distributed Scale Mode

**Status: implemented through guest provisioning.** A distributed run is an
ordinary run whose actor groups are provisioned onto remote guests: the
`connect` method ([provisioning.md](provisioning.md)) places workers and
relays round-robin across many hosts, stages their inputs, launches them
remotely, polls readiness per host, runs relay lifecycle on the relay
guest, and collects every metric stream back to the controller before
reporting. This document's original `hosts:` inventory sketch was superseded
by that provisioning contract (see [Host Inventory](#host-inventory)); the
distinct distributed concern that provisioning did not cover — cross-host
clock discipline — is now implemented and described below. Where this
document conflicts with the implemented contracts
([workers.md](workers.md), [METRICS.md](METRICS.md), [chaos.md](chaos.md),
[provisioning.md](provisioning.md)), the implemented contracts win.

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

This section's original `hosts:` sketch was superseded by the tmt-style
provision contract in [provisioning.md](provisioning.md), which generalizes
a bare host list into per-group provision methods behind a uniform guest
interface. The distributed host inventory is expressed as `connect` guests:

```yaml
provision:
  workers:
    how: connect
    guests:
      - address: load-1.example.net
        user: burner
      - address: load-2.example.net
        user: burner
  relays:
    how: connect
    guests:
      - address: relay-1.example.net
        user: burner
```

Local mode remains the default: without a `provision` block, everything runs
on the controller host through an implicit local guest exactly as today.

## Placement

The plan's actor list is placed onto worker hosts round-robin by actor
ordinal within each role — the same deterministic rotation idiom used for
relay assignment. Placement lands in the existing
`artifacts/rex/actor-hosts.json` (which already models
actor-to-host assignments) and in the report's topology section.

## Remote Worker Launch

No separate distributed runner is needed: the `rex-local-workers` runner
already performs every step below through the guest interface, so pointing a
group at `connect` guests is what makes a run distributed.

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

`subscription_fanout` is a subscriber's receive time minus the publisher's
`sent_at` stamp, so once those two actors run on different hosts the
measurement crosses two clocks and a clock difference masquerades as fanout
latency. This is the one distributed concern the guest contract did not
already handle, and it is now implemented:

- **Capture.** At run start, after guests are provisioned, the runner probes
  each guest's clock over the guest transport (a single `date` round-trip)
  and records its offset relative to the controller, together with the
  round-trip time that bounds the estimate, in `clocks.json` in the run
  directory. A local guest shares the controller clock and is recorded at
  offset zero; a guest whose clock could not be read records a null offset.
- **Diagnosis.** When `subscription_fanout_p99_ms` is judged and the run
  used any remote guest, the report emits a diagnostic: a
  `cross_host_clock_unverified` warning when a remote guest's offset was not
  captured, and a `cross_host_clock_skew` warning when a remote guest's
  offset exceeds the fanout budget it is being judged against — the point at
  which a fanout number could be entirely clock skew.

The diagnostic is an honesty signal, not a hard failure: a run with skewed
clocks still reports its numbers, but it reports alongside them that those
cross-host numbers cannot be trusted, which is exactly what the fanout
timing convention in [workers.md](workers.md) anticipates.

## Failure Semantics

- A host that cannot be staged or reached before launch fails the run
  (orchestration failure) — the experiment did not run as designed.
- A worker that dies mid-run fails the run under the existing
  workers-runner rule.
- Partial evidence (missing streams after fetch) yields the existing
  inconclusive verdicts rather than silently shrinking the denominator.

## Resolved

- Worker and relay provisioning, placement, remote launch, readiness
  polling, and metric-stream collection are implemented through the
  tmt-style provision methods in [provisioning.md](provisioning.md); the
  `connect` method subsumes this document's original host inventory.
- Cross-host clock discipline is implemented (see
  [Clock Discipline](#clock-discipline)).
- The distributed path is verified end to end by
  `t/real-distributed-run.t`: real workers are placed across more than one
  guest over the ssh transport, run a real Overnet workload against a real
  relay, and their metric streams are pulled back from each guest and
  aggregated into one report -- with the aggregated latency percentiles
  checked against an independent recompute from the per-guest streams. The
  test substitutes local tools for `ssh`/`scp` that relocate every
  guest-side path under a per-guest shadow root, so each guest has its own
  filesystem exactly as a remote host would; the raw ssh shell-out itself
  is covered by `t/guest-ssh.t`. `t/real-distributed-run-ssh.t` runs the
  same orchestration over a **real** sshd (CI provisions localhost; the test
  skips unless `OVERNET_BURNER_TEST_SSH_HOST` is set), so the full worker
  placement, staging, launch, readiness, and collection path is exercised
  over the actual `ssh`/`scp` transport, not only the substitute.

## Open Questions

- Live progress: whether the controller should sample remote metric
  streams mid-run for operator feedback, and how to do that without
  perturbing the workload.
- Clock discipline uses a single `date` round-trip per guest, which bounds
  but does not minimize offset uncertainty; a multi-sample estimator or an
  explicit NTP query would tighten it for very tight fanout budgets.
