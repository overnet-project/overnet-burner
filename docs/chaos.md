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
| `at` | non-negative integer | yes | Seconds after the workload window opens; must be less than `run.duration` |
| `action` | string | yes | One of `stop`, `start`, `restart` |
| `target` | string | yes | `relay:<ordinal>` naming a configured relay (1-based) |

The v1 action vocabulary is closed: an unknown action is a scenario
validation error, not a silently skipped hook.

## Plan Expansion

Each hook becomes a plan `chaos_hooks` entry with a stable id
(`chaos-001`, ...), its ordinal, a deterministic per-hook seed, and
`at_seconds`.

## Execution

The `rex-local-workers` runner executes chaos hooks:

- The workload window opens once every launched worker has reported ready.
  Hook offsets are measured from that moment; the runner records the actual
  firing offset, which may lag the schedule by orchestration latency.
- Actions map onto the target relay's topology provider lifecycle commands:
  `stop` runs the provider stop command; `start` runs the provider start
  command and then its health command; `restart` is stop, then start, then
  health.
- Chaos therefore requires a topology provider with lifecycle commands
  (for example the `external-command` provider). A hook whose target has no
  lifecycle commands fails the run before any worker is launched.
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
