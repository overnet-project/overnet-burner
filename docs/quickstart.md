# Quickstart: your first real run

This walks through a real single-host run against a live Overnet relay and how to
read the result. It assumes `overnet-burner` and a relay implementation
(`relay-perl`, providing `bin/overnet-relay.pl`) are both available.

## 1. Wire the relay lifecycle

`overnet-burner` does not start relays itself; it drives whatever `start`,
`health`, and `stop` commands you give it (the `external-command` topology
provider). Point those at your relay. A minimal set of scripts for `relay-perl`:

```sh
# start.sh -- launch the relay in the background and record its pid
perl /path/to/relay-perl/bin/overnet-relay.pl \
  --host 127.0.0.1 --port 7777 \
  --health-file "$PWD/health.json" --log-file "$PWD/relay.log" &
echo $! > "$PWD/relay.pid"

# health.sh -- succeed once the relay reports ready
for i in $(seq 1 50); do
  grep -q '"status":"ready"' "$PWD/health.json" 2>/dev/null && exit 0
  sleep 0.2
done
exit 1

# stop.sh -- terminate the relay
[ -f "$PWD/relay.pid" ] && kill "$(cat "$PWD/relay.pid")" 2>/dev/null
exit 0
```

If `health` never succeeds the run fails fast with a clear message
(`provider command failed: relay-001 health ...`) rather than hanging.

## 2. Write a scenario

```yaml
run:
  name: first-run
  duration: 8
  seed: 4242
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: "sh start.sh"
      health: "sh health.sh"
      stop: "sh stop.sh"
    endpoints:
      - ws://127.0.0.1:7777
  publishers:
    count: 2
  subscribers:
    count: 2
workload:
  publish_rate_per_second: 25
  subscription_filters:
    - kinds: [7800]
provision:
  workers:
    how: local
thresholds:
  publish_p99_ms: 2000
  subscription_fanout_p99_ms: 3000
  error_rate_max: 0.1
```

Validate it before running:

```
overnet-burner validate --scenario first-run.yml
```

## 3. Run it

```
overnet-burner run --scenario first-run.yml --runs-dir runs --run-id first --runner rex-local-workers
```

This starts the relay, launches the publisher and subscriber workers as local
processes, drives the workload for the configured duration, collects per-event
metrics, stops the relay, and writes `runs/first/report.json`.

## 4. Read the report

The report's `run.verdict` is the one-line judgment:

- `performance_passed` / `performance_failed` -- metrics were collected and
  judged against the thresholds.
- `smoke_passed` -- orchestration worked but no real workload metrics were
  collected (a wiring check, not a performance result).
- `orchestration_failed` / `aborted` -- the run did not complete.

`metrics.operations.<op>.latency_ms` carries the `p50/p90/p95/p99/mean/max`
percentiles, and `thresholds[]` shows each threshold's `status` and
`observed_value`. `human_summary.headline` states the outcome in a sentence.

The raw per-event streams live under `runs/first/metrics/*.jsonl`, so the report
percentiles can always be recomputed and audited from source data.

## 5. Compare two runs

Once you have a baseline, gate future runs against it:

```
overnet-burner compare runs/baseline/report.json runs/first/report.json
```

`compare` exits non-zero on a regression (a threshold crossing to `failed`, or
the verdict falling to a failure), so it drops straight into CI. See
`docs/compare.md`.

## Notes

- The nominal workload window (`duration`) includes relay start and worker
  connect, so the steady-state measurement window is slightly shorter than
  `duration`. Size `duration` with a few seconds of headroom for meaningful
  percentiles.
- Random scenarios and profiles can be generated from a seed instead of authored
  by hand; see `docs/generate.md` and `docs/profile-generation.md`.
