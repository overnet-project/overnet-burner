# overnet-burner Worker Contract

Workers are the load-generating and measuring processes of a run. Rex and the
runners orchestrate them; workers do the high-volume work and record metric
events. Like topology providers, workers are a language-neutral process
boundary: a worker is any executable that honors this contract, whatever it
is written in. The Perl workers in this distribution are reference
implementations.

## Files

The v1 input contract is defined by:

```text
schemas/worker-input-v1.schema.json
```

A representative input document is provided at:

```text
examples/worker-input-v1-sample.json
```

Workers emit metric events under the contract in [METRICS.md](METRICS.md).

## Launch

The runner starts one worker process per plan actor that requires a worker
role. The only required interface is a single environment variable:

```text
OVERNET_BURNER_WORKER_INPUT=/abs/path/to/runs/<run-id>/workers/<worker-id>/input.json
```

Workers MUST read their entire configuration from that JSON document. Workers
SHOULD ignore unrecognized command-line arguments and MUST NOT require any
other environment variables.

## Input Document

| Field | Type | Required | Description |
|---|---|---|---|
| `input_version` | integer `1` | yes | Contract version |
| `run_id` | non-empty string | yes | Run identifier |
| `run_dir` | non-empty string | yes | Absolute run directory |
| `worker_id` | non-empty string | yes | This actor's id (for example `publisher-001`) |
| `role` | non-empty string | yes | Worker role (for example `publisher`) |
| `seed` | integer | yes | Run seed; see Determinism |
| `duration_seconds` | non-negative number | yes | How long the workload phase runs |
| `metric_stream` | non-empty string | yes | Metric stream path, relative to `run_dir` |
| `ready_file` | non-empty string | yes | Readiness marker path, relative to `run_dir` |
| `endpoints` | object | yes | Service endpoints; `endpoints.relays` is an array of relay URLs |
| `workload` | object | yes | Role-specific workload parameters from the plan |

Unknown additional fields are compatible v1 extensions; workers MUST ignore
fields they do not understand.

## Determinism

All worker randomness MUST derive from `seed` and `worker_id` alone, so that
identical scenarios and seeds produce equivalent workloads. Workers MUST NOT
seed from wall-clock time, process ids, or host identity.

## Readiness

A worker MUST create `ready_file` (an empty file is sufficient) once it is
fully operational — connected, subscribed, and able to perform its role —
and before it begins its workload. Orchestration uses readiness to sequence
roles (for example, subscribers must be ready before publishers start, or
fanout measurements are lies).

## Metric Emission

Workers append metric events to `metric_stream` under the
[metric event contract](METRICS.md): one complete JSON object per line,
flushed per line. A truncated final line invalidates the stream.

Failures of the system under test are not worker failures: a rejected or
timed-out operation is a metric event with `status: "error"`, and the worker
continues.

## Exit Semantics

- Exit code `0`: orderly completion — the workload duration elapsed, or the
  worker shut down cleanly after `SIGTERM`.
- Non-zero exit: fatal worker failure (bad input document, unreachable
  endpoint before the workload started, internal error). The runner treats
  the run as orchestration-failed.
- On `SIGTERM`, a worker MUST stop starting new operations, finish or abandon
  the one in flight, flush its metric stream, and exit `0`.

Standard output and standard error are free-form diagnostics; the runner
captures them under `logs/`.

## Runner Integration

The `rex-local-workers` runner launches one worker process per plan actor
whose role has a reference worker, writes each actor's input document under
`workers/<worker-id>/input.json`, sequences readiness (subscribers and
readers before publishers), waits for orderly exits, and concatenates the
collected streams into the run's aggregated `metrics.jsonl`. The
`OVERNET_BURNER_WORKER` environment variable overrides the worker command
(default: the installed `overnet-burner-worker`), so any contract-compliant
executable in any language can serve as the worker. Actor roles without a
worker are recorded as explicitly skipped.

## Fanout Timing

Fanout latency spans two processes, so it needs a shared convention:

- A publisher SHOULD stamp each published event's body with `sent_at`, the
  publish wall-clock time in **milliseconds** since the Unix epoch
  (fractional milliseconds allowed), taken immediately before handing the
  event to the relay connection.
- A subscriber measures `subscription_fanout` as its receive time minus the
  event's `sent_at` stamp, clamped to zero. The metric event SHOULD carry
  `event_id`, `subscription_id`, and `relay_url`.
- Events without a numeric `sent_at` stamp are observed but MUST NOT be
  measured — a fanout latency that guesses its own start time is a lie.
- Stored-event replay delivered before the subscription's replay boundary
  (`EOSE` on Nostr relays) is `subscription_replay`, never
  `subscription_fanout`; a subscriber MUST NOT count replayed events as
  live fanout.

The measurement compares clocks across processes. On a single host it is
trustworthy; in distributed mode it is only as good as the clock
synchronization between the publishing and subscribing hosts, and reports
over distributed runs should treat small fanout latencies accordingly.

## Query Timing

A `query` is one filter-query round trip measured on a single clock, so it
needs no cross-process convention:

- A query reader issues the workload's `query_filters` as one request and
  measures from sending the request to receiving the stored-result boundary
  (`EOSE` on Nostr relays).
- `result_count` on the metric event is the number of stored events
  delivered before the boundary.
- Deliveries after the boundary are live subscription traffic, not query
  results; the reader MUST end the query at the boundary (close the
  subscription) rather than let live events stretch its duration.
- A request that never reaches the boundary within the reader's timeout is
  a metric event with `status: "error"`, and the reader continues.

Query readers pace themselves with `workload.query_rate_per_second`
(default `1`), analogous to `workload.publish_rate_per_second`.

## Object Reads

An `object_read` is one request against the relay's derived-object read
surface — for Overnet relays, the HTTP endpoint defined by the relay
specification's Derived Object Reads section — measured as a request round
trip on a single clock:

- The read origin is derived from the relay endpoint by replacing the `ws`
  scheme with `http` (`wss` with `https`), because the relay specification
  places the object read endpoint on the same relay origin.
- `workload.object_reads.objects` lists the object references to read, each
  a mapping with non-empty `type` and `id` strings; readers cycle through
  them in order. `workload.object_reads.rate_per_second` (default `1`)
  paces the reads.
- A fulfilled read (HTTP `200`) is a metric event with `status: "success"`.
  A structured relay refusal (the relay specification's object read error
  table: `invalid`, `unauthorized`, `payment_required`, `policy_denied`,
  `not_found`, `unsupported`, `unavailable`) is a metric event with
  `status: "error"` carrying the relay's `error.code`, and the reader
  continues — refusals are behavior of the system under test, not worker
  failures.
- Object read metric events SHOULD carry `object_type`, `object_id`, and,
  for responses the relay actually produced, `http_status`.
- An endpoint that is unreachable before the workload starts is a fatal
  worker failure per Exit Semantics, not a metric.

## Reference Workers

| Role | Implementation |
|---|---|
| `publisher` | `bin/overnet-burner-worker` with `Overnet::Burner::Worker::Publisher` |
| `subscriber` | `bin/overnet-burner-worker` with `Overnet::Burner::Worker::Subscriber` |
| `query_reader` | `bin/overnet-burner-worker` with `Overnet::Burner::Worker::QueryReader` |
| `object_reader` | `bin/overnet-burner-worker` with `Overnet::Burner::Worker::ObjectReader` |

The reference publisher derives a stable Nostr identity from
`seed`/`worker_id`, publishes valid native Overnet events (kind 7800 with the
required core tags, body stamped with `sent_at`) at
`workload.publish_rate_per_second`, waits for each relay acknowledgment, and
emits one `publish` metric event per attempt — `success` on acceptance,
`error` with the relay's reason on rejection or timeout.

The reference subscriber subscribes to the first relay endpoint with
`workload.subscription_filters`, writes its readiness marker only after the
stored-event replay boundary (`EOSE`), and emits one `subscription_fanout`
metric event per stamped live event under the fanout timing convention
above.

The reference query reader issues `workload.query_filters` against the first
relay endpoint at `workload.query_rate_per_second` and emits one `query`
metric event per request under the query timing convention above — `success`
with `result_count` at the stored-result boundary, `error` on timeout.

The reference object reader cycles through `workload.object_reads.objects`
against the first relay endpoint's derived origin at
`workload.object_reads.rate_per_second` and emits one `object_read` metric
event per request under the object read convention above. It requires a
relay that implements the Overnet derived-object read endpoint; a plain
Nostr relay does not provide one.
