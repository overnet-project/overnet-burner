# overnet-burner Report Contract

`report.json` is the stable automation contract for an `overnet-burner` run.
In plain terms: report.json is the stable automation contract.

The report answers the questions automation needs to answer without parsing
the full run directory:

- what scenario ran
- what runner executed it
- what topology was planned
- what phases ran
- whether the run machinery completed
- what verdict should be assigned
- whether metrics were collected
- which thresholds passed, failed, or were not evaluated
- what chaos hooks were configured and executed
- which evidence artifacts support the report

`manifest.json`, `plan.json`, `runner.jsonl`, and `metrics.jsonl` are evidence.
In plain terms: manifest.json, plan.json, runner.jsonl, and metrics.jsonl are evidence.
They remain useful for debugging, reproduction, and audit, but normal
automation should consume `report.json` first and only drill into evidence when
it needs more detail.

## Files

The v1 contract is defined by:

```text
schemas/report-v1.schema.json
```

A representative smoke report is provided at:

```text
examples/report-v1-smoke.json
```

Generated runs should eventually write:

```text
runs/<run-id>/report.json
```

## Versioning

Every report has:

```json
{
  "report_version": 1,
  "schema": "https://overnet-project.org/schemas/overnet-burner/report-v1.schema.json"
}
```

Breaking changes require a new report_version.

Compatible v1 changes may:

- add new members under `extensions`
- add new optional artifacts
- add new optional diagnostics

Compatible v1 changes must not:

- remove required top-level sections
- rename fields
- add enum values for existing fields
- change the meaning of `run.status`, `run.verdict`, or `run.result_class`
- change units for an existing metric or threshold
- require automation to parse human summary text

## Status Versus Verdict

`run.status` describes whether the runner machinery completed.

`run.verdict` describes what a consumer should conclude.

Examples:

```json
{
  "status": "completed",
  "verdict": "smoke_passed",
  "result_class": "orchestration"
}
```

```json
{
  "status": "completed",
  "verdict": "performance_failed",
  "result_class": "performance"
}
```

```json
{
  "status": "failed",
  "verdict": "orchestration_failed",
  "result_class": "orchestration"
}
```

A smoke run can pass orchestration while collecting no performance metrics. That
must be represented explicitly instead of hidden behind a generic success flag.

## Metrics And Thresholds

`metrics` summarizes raw metric streams. It must not embed every sample.

Raw metric streams follow the language-neutral contract in
[METRICS.md](METRICS.md), which also defines the normative summarization
rules (grouping by operation, error accounting, nearest-rank percentiles,
and latency computed over successful operations only). `metrics.collected`
is true only when every stream declared by the plan exists, is non-empty,
and parses cleanly; a present-but-invalid stream is reported as
`reason: "configuration_error"` and no summaries are produced from it.

Thresholds are independent structured records. Each threshold has a stable id,
machine-readable status, configured value, observed value, unit, and reason.

When no metrics exist, thresholds should use:

```json
{
  "status": "not_evaluated",
  "observed_value": null,
  "reason": "no_metrics"
}
```

### Threshold Registry

Scenario threshold ids map to summarized metrics as follows:

| Threshold id | Metric | Comparator | Unit |
|---|---|---|---|
| `publish_p99_ms` | `publish.latency_ms.p99` | `<=` | `ms` |
| `subscription_fanout_p99_ms` | `subscription_fanout.latency_ms.p99` | `<=` | `ms` |
| `query_p99_ms` | `query.latency_ms.p99` | `<=` | `ms` |
| `object_read_p99_ms` | `object_read.latency_ms.p99` | `<=` | `ms` |
| `error_rate_max` | `overall.error_rate` | `<=` | `ratio` |

A threshold id that is not in the registry is itself resolved as a raw
metric path with the `<=` comparator and no unit, so any summarized value
can be judged — for example `query.latency_ms.p50: 60` or
`custom_op.latency_ms.max: 250` for a custom operation's stream.

Metric paths resolve into the summarized metrics: `overall.*` resolves into
the run-wide counters, and any other first segment names an operation
summary. A configured threshold whose metric is absent from the collected
summaries is reported as `status: "not_evaluated"` with
`reason: "metric_missing"`.

### Verdict Derivation

For a run whose machinery completed (`run.status` is `completed`), the
verdict follows from metrics and thresholds:

| Condition | Verdict | Result class |
|---|---|---|
| Metrics not collected (smoke) | `smoke_passed` | `orchestration` |
| Metric streams present but invalid | `inconclusive_no_metrics` | `performance` |
| Any threshold `failed` | `performance_failed` | `performance` |
| No failure, but a configured threshold's metric is missing | `inconclusive_partial_run` | `performance` |
| All configured thresholds evaluated and passed | `performance_passed` | `performance` |
| Metrics collected, no thresholds configured | `smoke_passed` | `orchestration` |

When the run executed chaos hooks (`chaos.hooks_executed > 0`), the
threshold-driven rows above are judged as a chaos experiment instead:
`chaos_failed`, `inconclusive_partial_run`, or `chaos_passed`, with result
class `chaos`. See [chaos.md](chaos.md).

## Artifacts

Every artifact reference includes:

- `id`
- `path`
- `media_type`
- `role`
- `required`
- `sha256`
- `size_bytes`

Automation can use those fields to verify the evidence it consumes. Artifact
paths are relative to the run directory.

## Human Summary

`human_summary` is non-authoritative. Automation must use structured fields
instead of parsing prose.
