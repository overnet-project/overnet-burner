# overnet-burner Metric Event Contract

Metric events are the language-neutral measurement records of a run. Any
worker, in any language, can participate in a run by appending metric events
to its assigned stream file. The burner never requires workers to link
against burner code; this document and the schema are the contract.

## Files

The v1 contract is defined by:

```text
schemas/metric-event-v1.schema.json
```

A representative sample stream is provided at:

```text
examples/metric-events-v1-sample.jsonl
```

Run plans assign each worker actor one stream file under the run directory,
declared in `plan.json` as `metric_streams` (for example
`metrics/publisher-001.jsonl`). Relay actors declare no stream: they are
managed by topology providers and nothing produces relay-side metrics yet,
and a plan must not promise evidence that nothing emits — `collected` in the
report is only true when every declared stream exists. Relay-side streams
will be declared once relay observation exists. The run-root `metrics.jsonl`
artifact is the concatenation of all streams, produced during collection.

## Encoding

- UTF-8, no byte-order mark.
- One JSON object per line, `\n` line endings (JSONL).
- Writers append complete lines only; a truncated final line invalidates the
  stream.

## Versioning

Every event carries:

```json
{ "metric_version": 1 }
```

Compatible v1 changes may add new optional core fields and new
operation-specific fields. Changes that remove, rename, or re-type a core
field, change the meaning or units of an existing field, or change
summarization semantics require a new metric version.

## Core Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `metric_version` | integer `1` | yes | Contract version |
| `run_id` | non-empty string | yes | Run this event belongs to |
| `worker_id` | non-empty string | yes | Emitting actor id (for example `publisher-001`) |
| `host` | non-empty string | yes | Host the worker ran on |
| `role` | non-empty string | yes | Worker role (for example `publisher`) |
| `operation` | non-empty string | yes | Measured operation name |
| `started_at` | RFC 3339 UTC string | yes | Operation start |
| `finished_at` | RFC 3339 UTC string | yes | Operation end |
| `duration_ms` | non-negative number | yes | Authoritative operation duration |
| `status` | `"success"` or `"error"` | yes | Operation outcome |
| `error` | non-empty string | no | Failure reason; only meaningful with `status: "error"` |

Timestamps MUST use the UTC `Z` form (`2026-07-02T18:00:00Z`, fractional
seconds allowed). `duration_ms` is authoritative for latency analysis;
consumers MUST NOT derive durations by subtracting timestamps.

Events MAY carry additional operation-specific members (for example
`event_id`, `relay_url`, `subscription_id`, `filter_hash`, `result_count`,
`http_status`, `rejection_reason`). Operation-specific members MUST NOT
redefine core field names and SHOULD use `snake_case`.

Events MAY carry a `phase` member naming the workload phase the operation
ran in (`warmup`, `main`, `cooldown`). In a **multi-phase run** the `phase`
member is REQUIRED on every event: an event that cannot say which phase it
belongs to cannot be judged honestly.

## Well-Known Operations

The `operation` vocabulary is open, but summaries and thresholds reference
these well-known names:

- `publish` — event publication round trip
- `subscription_replay` — stored-event replay delivery
- `subscription_fanout` — live delivery to an existing subscription;
  `duration_ms` follows the fanout timing convention in
  [workers.md](workers.md)
- `query` — filter query round trip; `duration_ms` follows the query timing
  convention in [workers.md](workers.md)
- `object_read` — derived object read; `duration_ms` follows the object
  read convention in [workers.md](workers.md)
- `sync_round` — one negentropy reconciliation round
- `relay_ping` — relay liveness round trip measured from opening a fresh
  connection to the stored-result boundary of an empty subscription; one
  event per probed relay endpoint, carrying `relay_url`
- `flood_publish`, `malformed_publish`, `replay_submit` — abuse operations
  emitted by adversarial workers, carrying the abuse members below; see
  [abuse.md](abuse.md)

New operation names are compatible additions; they appear in summaries
automatically.

### Abuse Members

Abuse operations ([abuse.md](abuse.md)) carry four operation-specific
members recording how the relay responded, against the Overnet core outcome
and error vocabularies:

| Member | Type | Description |
|---|---|---|
| `outcome` | string | Core outcome category (accepted, rejected, unauthorized, unavailable, unsupported, partial) |
| `error_category` | string | Core error category for a rejection (invalid input, policy rejection, authentication failure, authorization failure, unsupported, not found, internal failure); absent when accepted |
| `defended` | boolean | Whether the relay stopped this abuse |
| `defended_correct` | boolean | Whether it stopped the abuse with the spec-correct semantics for the role; implies `defended` |

## Summarization

Report generation summarizes metric events with these normative rules:

- In a multi-phase run, only events with `phase: "main"` are summarized:
  warmup and cooldown events remain in the streams as evidence but never
  feed summaries or thresholds, because cold-start and drain noise are not
  the system's steady-state behavior. An event without a `phase` member in
  a multi-phase run makes the run's metrics untrustworthy (a configuration
  error), exactly like a malformed stream.
- Events from all streams of a run are grouped by `operation`.
- `count`, `success_count`, and `error_count` count events by `status`;
  `error_rate` is `error_count / count`.
- `latency_ms` summaries (`min`, `p50`, `p90`, `p95`, `p99`, `max`, `mean`)
  are computed over the `duration_ms` of **successful** events only. Error
  frequency is reported by `error_rate`, not blended into latency. When an
  operation has no successful events every latency member is `null`.
- Percentiles use the nearest-rank method: for percentile `p` over `n`
  ascending-sorted samples, the value at 1-based index `ceil(p / 100 * n)`.
- `overall.error_rate` is total `error_count` over total `count` across all
  operations.
- An operation whose events carry the `defended` member (an abuse
  operation) additionally summarizes `defended_count`, `defended_ratio`,
  `defended_correct_count`, and `defended_correct_ratio`, each a fraction of
  the operation's total `count`. Operations without `defended` events carry
  no defense fields, so honest-worker summaries are unchanged.
- Summarization is deterministic: identical streams produce identical
  summaries.

A malformed stream (invalid JSON line or an event that fails schema
validation) makes the run's metrics untrustworthy; report generation must
surface that instead of summarizing around it.

## Out Of Scope For v1

Host resource samples (CPU, RSS, file descriptors, disk, network) are not
part of the v1 operation-event contract and will be specified separately.
