# overnet-burner Chaos Contract

Chaos hooks inject scheduled faults into the topology under test so that a
run can measure behavior under failure, not just under load. Like every
other cross-process surface in overnet-burner, chaos is defined here as an
implementation-neutral contract; the Perl runner is a reference
implementation.

## Scenario Configuration

`chaos` is a list of hooks:

```yaml
chaos:
  - at: 120
    action: restart
    target: relay:1
```

| Field | Type | Required | Description |
|---|---|---|---|
| `at` | non-negative integer | yes | Seconds after the workload window opens; must be less than the run's total duration (warmup + main + cooldown) |
| `action` | string | yes | A relay lifecycle action (`stop`, `start`, `restart`) or a network action (`net-delay`, `net-loss`, `partition`, `heal`) |
| `target` | string | yes | `relay:<ordinal>` for lifecycle actions; `worker-guest:<ordinal>` for network actions (both 1-based) |

The action vocabulary is closed: an unknown action is a scenario
validation error, not a silently skipped hook.

### Network Actions

Network actions injure the network of a **worker guest** — a network can
only be injured safely inside a namespace that belongs to the run, so they
require workers provisioned as containers on a per-run bridge network
(`provision.workers: {how: container, network: bridge}`, see
[provisioning.md](provisioning.md)); scenarios combining a network action
with any other provisioning are rejected at validation.

| Action | Parameters | Semantics |
|---|---|---|
| `net-delay` | `delay_ms` (required, positive integer), `jitter_ms` (optional, positive integer) | Add latency to the guest's default-route interface via `tc netem` |
| `net-loss` | `loss_percent` (required, number in (0, 100]) | Drop that percentage of the guest's packets via `tc netem` |
| `partition` | none | Disconnect the guest from the per-run network entirely |
| `heal` | none | Undo the guest's active faults: reconnect a partitioned guest, clear an active netem impairment; a no-op if nothing is active |

Rules and disclosed limitations:

- A guest holds **at most one netem impairment**: a second `net-delay` or
  `net-loss` on the same guest replaces the first rather than stacking.
- `partition` is a full disconnection of the guest, not a per-peer cut;
  partitioning selected peer pairs is future work. Disconnecting the
  interface also discards any netem impairment on it.
- A netem action on a partitioned guest fails the run: the guest has no
  default-route interface to shape, and an experiment that cannot execute
  as designed must not pretend it did.
- Every network action requires the `iproute2` tools (`ip`, `tc`)
  **inside the worker image**: netem actions shape traffic with `tc`, and
  every action captures its evidence with `ip`/`tc`. Only netem actions
  additionally require `CAP_NET_ADMIN`; the runner adds the capability to
  worker containers only when the scenario contains netem actions. Images
  without the tools fail the hook, and therefore the run, honestly.
- Faults left active at the end of the run are torn down with the guests
  and the per-run network; the runner does not auto-heal.

## Plan Expansion

Each hook becomes a plan `chaos_hooks` entry with a stable id
(`chaos-001`, ...), its ordinal, a deterministic per-hook seed, and
`at_seconds`.

## Execution

The `rex-local-workers` runner executes chaos hooks:

- The workload window opens once every launched worker has reported ready.
  Hook offsets are measured from that moment; the runner records the actual
  firing offset, which may lag the schedule by orchestration latency.
- Lifecycle actions map onto the target relay's topology provider lifecycle
  commands: `stop` runs the provider stop command; `start` runs the provider
  start command and then its health command; `restart` is stop, then start,
  then health.
- Lifecycle actions therefore require a topology provider with lifecycle
  commands (for example the `external-command` provider). A hook whose
  target has no lifecycle commands fails the run before any worker is
  launched.
- Network actions map onto the target guest's container: `net-delay` and
  `net-loss` run `tc qdisc replace ... netem` on the guest's default-route
  interface through the container engine; `partition` and `heal` disconnect
  and reconnect the container on the per-run network through the engine.
  After each network action the runner captures the resulting state (the
  interface's qdisc for netem actions, the guest's default route for
  partition and heal) and records it verbatim as `evidence` in the hook's
  completed ledger event — captured, not judged.
- A hook whose provider command fails is recorded as `failed` and fails the
  run: an experiment that did not execute as designed must not present its
  results as if it had.
- The runner keeps the workload window open until every scheduled hook has
  fired, even if all workers have already exited.
- Runners that do not execute chaos leave hooks untouched; the report shows
  them as `not_evaluated`.

## Run Ledger

Chaos execution is recorded as runner events with `event_kind: "chaos_hook"`
in `logs/runner.jsonl`: a `started` event when the hook fires and a
`completed` or `failed` event when it finishes, carrying `hook_id`,
`action`, `target`, `actor_id`, `at_seconds`, the actual `offset_seconds`,
`started_at`, `finished_at`, `duration_ms`, and `error` on failure.
Network action events carry `guest` (the target guest name) instead of
`actor_id`, and completed network actions carry `evidence`: the captured
post-action state of the guest's network, possibly empty (a partitioned
guest has no default route to show).

## Report

`chaos.hooks[]` in the report is filled from the ledger: executed hooks
carry their real timings, `hooks_executed` counts hooks that completed, and
hooks that never fired stay `not_evaluated`.

For a completed run with `hooks_executed > 0`, the verdict is judged as a
chaos experiment:

| Condition | Verdict | Result class |
|---|---|---|
| Any threshold `failed` | `chaos_failed` | `chaos` |
| No failure, but a configured threshold's metric is missing | `inconclusive_partial_run` | `chaos` |
| All configured thresholds evaluated and passed | `chaos_passed` | `chaos` |
| No thresholds evaluated | existing non-chaos rules apply | |

A run that fails because a hook could not execute is an orchestration
failure (`orchestration_failed`), never `chaos_failed`: `chaos_failed` is
reserved for the system under test missing its thresholds during a chaos
experiment that actually ran.

## Limitations

The reference publisher and subscriber reconnect after losing a relay
connection under the worker contract's Connection Loss rules, so a relay
restart shows up as error metrics during the outage followed by recovery,
not as worker death. Two honest gaps remain: operations in flight when the
connection drops are resolved by the worker's operation timeout, so a
single outage can stall a publisher for up to that timeout; and events
published while a subscriber was disconnected are replayed rather than
measured, so fanout coverage has a hole exactly the width of the outage.
