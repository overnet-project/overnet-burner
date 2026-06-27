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
