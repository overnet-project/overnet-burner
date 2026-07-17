# Run Comparison

`overnet-burner compare` diffs two run reports and reports what changed between
a baseline run and a candidate run. It answers one question: *did the candidate
get worse?* — so it can gate CI on regressions.

## Usage

```
overnet-burner compare BASELINE_REPORT CANDIDATE_REPORT [--json] [--allow-regression]
```

`BASELINE_REPORT` and `CANDIDATE_REPORT` are `report.json` files produced by
`overnet-burner report` (or written automatically by `overnet-burner run`). The
baseline and candidate may also be given as `--baseline` and `--candidate`.

By default the command prints a human-readable summary. `--json` prints the full
comparison object instead.

## What it compares

The comparison is built from the authoritative report fields:

- **verdict** and **result class** — the run-level judgment (for example
  `performance_passed` → `performance_failed`).
- **thresholds** — matched by id. Each threshold's pass/fail transition is
  classified as `regressed` (`passed` → `failed`), `improved` (`failed` →
  `passed`), `unchanged`, `changed` (any other status transition), `added` (only
  in the candidate), or `removed` (only in the baseline). The observed-value
  delta is reported alongside.
- **operations** — matched by name. For each shared operation the error rate and
  the latency percentiles (`p50`, `p90`, `p95`, `p99`, `mean`, `max`) are
  compared. These are all "lower is better", so a rise is `regressed`, a fall is
  `improved`, an equal value is `unchanged`, and a value missing from either side
  is `incomparable`.

## What counts as a regression

A run **regresses** when an authoritative pass/fail signal gets worse:

- any threshold crosses from `passed` to `failed`, or
- the verdict falls to a failure (`*_failed` or `aborted`) when the baseline was
  not a failure.

A metric drifting slower without crossing a threshold is reported (with a
direction and delta) but does **not** by itself mark the run as regressed — this
matches how the report itself judges pass/fail through thresholds, not raw
metrics.

## Exit status

`compare` exits `1` when the candidate regressed and `0` otherwise, so it can be
used directly as a CI gate. Pass `--allow-regression` to always exit `0` while
still printing the comparison.

## JSON output

`--json` emits a versioned comparison object:

```
{
  "compare_version": 1,
  "baseline":  { "id": ..., "verdict": ..., "result_class": ... },
  "candidate": { "id": ..., "verdict": ..., "result_class": ... },
  "verdict":      { "baseline": ..., "candidate": ..., "changed": 0|1 },
  "result_class": { "baseline": ..., "candidate": ..., "changed": 0|1 },
  "thresholds": [ { "id", "metric", "baseline_status", "candidate_status",
                    "baseline_value", "candidate_value", "delta", "change" } ],
  "operations": [ { "operation", "metric", "baseline", "candidate",
                    "delta", "delta_ratio", "direction" } ],
  "summary": { "thresholds_regressed", "thresholds_improved",
               "metrics_regressed", "metrics_improved", "regressed" }
}
```

## Limitations

Only lower-is-better operation metrics (latency and error rate) carry a
direction today; throughput comparison is not yet modeled.
