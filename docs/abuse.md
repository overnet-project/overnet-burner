# overnet-burner Abuse Simulation

**Status: implemented.** The `flooder`, `malformed_publisher`,
`replayer`, `subscription_abuser`, `sybil`, `connection_flood`, and
`provenance_forger` abuse roles, the metric outcome members, the derived
defense ratios, and the `abuse` experiment verdict are implemented and
tested. This document is the language-neutral contract; where it conflicts
with a later implemented contract, the implemented contract wins.

Every worker overnet-burner has today is a cooperative, well-behaved
participant: it sends valid events at a configured rate and measures its own
latency and fanout. The chaos subsystem injures infrastructure (relay
lifecycle and the network), not participants. Abuse simulation adds the
missing axis: **adversarial participants** that deliberately violate or
exploit the protocol, so a run can measure how well a relay defends itself
and what that defense costs everyone else.

Like every other cross-process surface in overnet-burner, abuse is defined
here as a language-neutral contract. An abuse worker is any executable that
honors the worker contract in [workers.md](workers.md) and emits the metric
events in [METRICS.md](METRICS.md); the Perl abuse workers in this
distribution are reference implementations.

## Why Abuse Is A Distinct Measurement

Load testing asks one question: do the honest workers stay within their
thresholds? Abuse testing asks two, and both must be answered in the same
run:

1. **Does the defense fire, and fire correctly?** The Overnet core
   specification requires that anti-abuse controls be surfaced through
   defined outcome and error semantics "rather than by silent corruption of
   core behavior" (section 9.6 Abuse Prevention and Rate Limiting, section 13.6 Abuse,
   Spam, and Resource Exhaustion). A relay that silently drops an abusive
   event, silently accepts it, or rejects it as `internal failure` instead
   of `policy rejection` is non-conformant — and that is a testable claim.
2. **What is the blast radius?** Abuse that is correctly rejected but takes
   the relay down with it is still a successful denial of service. The
   load-bearing number is whether the honest publishers, subscribers, and
   readers still meet their thresholds *while the abuse is running*.

overnet-burner is well positioned for the second question because it already
runs honest workers and judges their thresholds; an abuse worker is another
actor in the same run, so the honest-worker metrics during the abuse window
come for free. The [observer](workers.md) worker's `relay_ping` probes are
the "did the relay stay up" signal for the same window.

## Threat Model Coverage

The abuse roles map to the Overnet core specification threat model (section 7.8):
forged external mappings, replayed operations, compromised identities,
misleading provenance, conflicting event ordering, and policy-sensitive
capability exposure.

| Threat (core section 7.8) | Abuse role | What the relay's defense is |
|---|---|---|
| Resource exhaustion by volume | `flooder` | rate limiting / quota (section 9.6) |
| Invalid, oversized, or unsigned events | `malformed_publisher` | publish validation (section 8.3) |
| Replayed operations | `replayer` | idempotency / dedup (section 8.8) |
| Subscription resource exhaustion | `subscription_abuser` | bounded subscription limits (relay policy) |
| Compromised / cheap identities | `sybil` | per-identity limits, admission policy |
| Forged external mappings, misleading provenance | `provenance_forger` | adapter provenance validation (adapter specs) |
| Connection-level exhaustion | `connection_flood` | connection admission (transport / guest layer) |

## Abuse Worker Roles

Each abuse role is a worker role in the plan (topology and workload), placed
onto guests and launched exactly like an honest worker. The implemented
roles are `flooder`, `malformed_publisher`, `replayer`,
`subscription_abuser`, `sybil`, and `connection_flood`: together they
exercise rate limiting, input validation, idempotency, subscription
bounding, per-identity limits, and connection bounding. The remaining role
is named now and built after.

- **`flooder`** — publishes structurally valid events far above any
  plausible rate limit. Measures the fraction the relay throttled or
  rejected and the observed effective limit.
- **`malformed_publisher`** — submits events that violate Nostr
  verification, core requirements, or size limits (broken signature,
  oversized payload, missing required fields). Measures the rejection rate
  and, critically, the **error category** the relay returns.
- **`replayer`** — captures events the relay accepted and resubmits them.
  Measures whether the relay treats the duplicate idempotently or as a
  distinct accepted event (section 8.8).
- **`subscription_abuser`** — opens many concurrent or deliberately
  expensive subscriptions. Measures whether the relay bounds them.
- **`sybil`** — publishes from a fresh identity per event. Its per-event
  defense model is the flooder's; whether identity churn *evades* a limit
  is read comparatively, from the sybil worker's defended ratio against a
  flooder's under the same relay (a per-connection or per-IP limit resists
  churn, a per-identity limit does not).
- **`connection_flood`** — opens WebSocket connections and holds them open
  so they accumulate, measuring whether the relay bounds concurrent
  connections. It uses no persistent client and tears down every held
  connection at the end of the run; connection *rate* limiting (rapid
  open/drop) is a future variant.
- **`provenance_forger`** — publishes adapted events that claim an external
  origin the worker is not authoritative for: each event carries adapted
  provenance for a target origin but is signed by the worker's own identity
  rather than the adapter identity an authority record binds to that origin.
  Its defense does not live at the relay. A relay is a dumb carrier and
  accepts the forged event (Overnet core section 7.7); the forgery is caught
  at the consumer-side provenance verification boundary (section 7.9). The
  worker therefore measures the **verification outcome**, not the relay
  acknowledgement: it verifies each forged event with the reference oracle
  against the authority record a consumer would hold and records `forged` as
  the correct defense and `authoritative` as the forgery succeeding. See
  [Provenance Verification As The Defense Boundary](#provenance-verification-as-the-defense-boundary).

## The Outcome Model

An abuse worker MUST distinguish three outcomes, because collapsing them
makes the experiment lie about the relay's defenses:

1. **Defended** — the relay rejected or limited the abuse *and* did so
   through defined outcome and error semantics. This is the good case.
2. **Not defended** — the relay accepted the abuse. The defense failed.
3. **Degraded** — the relay accepted the connection but could not answer
   correctly, fell over, or stopped serving honest traffic. The abuse
   succeeded as a denial of service even if individual operations were
   rejected.

Outcomes are recorded against the Overnet core outcome and error
vocabularies so the experiment measures conformance, not just counts. Each
abuse operation records the relay's response using the core outcome
categories (section 8.6: accepted, rejected, unavailable, unauthorized,
unsupported, partial) and, for a rejection, the core error category (section 8.7:
invalid input, authentication failure, authorization failure, unsupported,
not found, policy rejection, internal failure). A `flooder` that is
throttled is **defended** with outcome `rejected` and category
`policy rejection`; a `malformed_publisher` whose event is refused is
**defended** with category `invalid input`; the same event accepted, or
rejected as `internal failure`, is a defense failure of a different kind and
MUST be recorded as such.

### Ground Truth

An abuse worker MUST record what it actually sent and what the relay
actually returned. A `flooder` that could not connect did not test rate
limiting; a `malformed_publisher` that failed to construct its malformed
event tested nothing. An abuse operation the worker could not perform as
designed is an orchestration failure, never a defense result — the same
rule chaos hooks follow ([chaos.md](chaos.md)).

## Provenance Verification As The Defense Boundary

Every abuse role except `provenance_forger` measures a defense the relay
performs: the relay rejects, limits, deduplicates, or refuses, and the
worker classifies that acknowledgement. Provenance forgery has no such
relay defense, and that is by design. Adapted provenance is self-asserted:
any identity can sign an event claiming any external origin and external
identity, and a relay that accepts it validates the Nostr signature and
structure but not whether the signer is authoritative for the origin
(Overnet core section 7.7). Making the relay reject forged provenance would
require it to know which identity is the legitimate adapter for every
external origin — which would break permissionless publication.

The Overnet core instead defines the defense at a **consumer-side
verification boundary** (section 7.9). An adapter authority record
(section 6.15) binds an external origin to the adapter pubkeys authoritative
for it, and a consumer that trusts that record as an anchor verifies each
adapted event against it, yielding one of `authoritative`, `forged`,
`unverified`, or `unresolvable`. A forged event — one signed by a pubkey the
anchored record does not list — resolves to `forged` and MUST NOT be
rendered as authoritative external attribution.

The `provenance_forger` role measures that boundary, not the relay:

1. it builds an adapted event for a target origin, signed by its own
   identity rather than the origin's authoritative adapter identity;
2. it publishes the event so the run exercises the relay carrying it — the
   relay accepts it, which is expected and not itself measured;
3. it verifies the event against the authority record a consumer would hold
   for that origin, using the reference oracle, and records the verification
   outcome.

The measured population is the forged events, exactly as `flooder` measures
floods. The forgery is **defended** when verification does not render it
authoritative (`forged`, `unverified`, or `unresolvable`) and **defended
with the correct mechanism** when verification resolves it to `forged` — a
positive detection given the anchor. Verification resolving a forged event
to `authoritative` is the forgery succeeding, the defense failure the
experiment exists to catch. A run that supplies the anchor and still sees
`unverified` or `unresolvable` is measuring a verifier that failed to apply
an authority record it was given.

The system under test for this role is therefore a provenance verifier — an
ordinary Overnet consumer, in any language, that implements the section 7.9
operation. The Perl `Overnet::Burner::Provenance` module is the reference
oracle the forger measures against, the same way the other roles are judged
against the reference relay's behavior.

## Scenario Configuration

Abuse roles appear in `topology` with a count, like any worker role, and are
paced through `workload`. Running honest workers in the same scenario, with
the abuse concentrated in the `main` phase, gives the blast-radius
measurement directly, because honest thresholds are judged on `main`
([workers.md](workers.md), workload phases):

```yaml
topology:
  publishers: { count: 4 }      # honest steady-state load
  subscribers: { count: 4 }
  observers:   { count: 1 }      # relay liveness during the abuse
  flooders:    { count: 2 }      # the abuse
workload:
  publish_rate_per_second: 10
  abuse:
    flooder:
      publish_rate_per_second: 5000   # far above any plausible limit
thresholds:
  # defense: the relay MUST reject or limit most of the flood
  flood_publish.defended_ratio: 0.99
  # collateral: honest publishers MUST still meet their latency target
  publish_p99_ms: 250
```

Abuse that must begin at a scheduled offset (a sudden flood, a connection
storm) MAY instead be expressed through the chaos `at:` schedule
([chaos.md](chaos.md)) rather than as a steady worker, reusing the existing
scheduled-fault machinery.

Abuse targets only the relays declared in the run's own topology. burner
never accepts an external target list: abuse simulation is red-teaming your
own deployment's defenses, confined to the relays a run provisioned or was
pointed at, deterministic and reproducible from the run seed like every
other worker.

## Metric Events

Abuse workers emit `metric-event-v1` events on their assigned stream. Each
abuse role uses distinct `operation` names (for example `flood_publish`,
`malformed_publish`, `replay_submit`, `abusive_subscribe`, `sybil_publish`,
`abusive_connect`, `forge_publish`) so their
summaries never mix with honest-worker operations. Beyond the core fields,
an abuse event carries:

| Member | Type | Description |
|---|---|---|
| `outcome` | string | Core outcome category (section 8.6) the relay returned; for `forge_publish` the provenance verification outcome (section 7.9: `authoritative`, `forged`, `unverified`, `unresolvable`) the verification boundary returned |
| `error_category` | string | Core error category (section 8.7) for a rejection; absent otherwise |
| `defended` | boolean | Whether this operation was correctly defended |

The `forge_publish` operation records the verification boundary's decision
rather than a relay acknowledgement: its `status` is `success` because the
forge-and-verify operation ran and the relay carried the event, and its
`outcome` is the verification verdict. A forged event resolved to `forged`
is `defended` and `defended_correct`; `unverified` or `unresolvable` is
`defended` but not a correct positive detection; `authoritative` is the
forgery succeeding and is neither.

`status` follows the worker contract: an operation the relay rejected is
`status: "error"` with the rejection reason, so an abuse operation's
error rate is naturally the fraction the relay refused. `defended` is
stricter than `status`: it is true only when the refusal used a correct
outcome and error category, so a rejection with the wrong category counts as
a defense gap even though the event was refused.

## Report And Verdict

An **abuse experiment** is a run that launched abuse workers, judged as a
distinct result class parallel to chaos. The report derives two derived
ratios per abuse operation from the members above:

| Metric | Meaning |
|---|---|
| `<op>.defended_ratio` | fraction of abuse operations the relay rejected or limited |
| `<op>.defended_correct_ratio` | fraction defended with a spec-correct outcome and error category |

Abuse thresholds are configured as raw metric paths naming the abuse
operation and the ratio ([REPORT.md](REPORT.md) threshold registry), for
example `flood_publish.defended_ratio` or
`malformed_publish.defended_correct_ratio`. A defense ratio is a floor, not
a ceiling: a threshold whose metric path leaf is `defended_ratio` or
`defended_correct_ratio` is judged with `>=` rather than the default `<=`,
so a higher observed defense passes.

Collateral damage reuses the existing honest-worker thresholds
(`publish_p99_ms`, `subscription_fanout_p99_ms`, `error_rate_max`, and the
observer's `relay_ping` errors): the abuse experiment fails if the abuse got
through **or** if honest traffic was harmed while it ran.

For a completed run that launched abuse workers, the threshold-driven rows
in [REPORT.md](REPORT.md) are judged as an abuse experiment, with result
class `abuse`:

| Condition | Verdict | Result class |
|---|---|---|
| Any abuse or collateral threshold `failed` | `abuse_failed` | `abuse` |
| No failure, but a configured threshold's metric is missing | `inconclusive_partial_run` | `abuse` |
| All configured thresholds evaluated and passed | `abuse_passed` | `abuse` |
| No thresholds configured | measurement only; existing non-abuse rules apply | |

A run that fails because an abuse worker could not execute its abuse as
designed is an orchestration failure (`orchestration_failed`), never
`abuse_failed`: `abuse_failed` is reserved for a relay that failed to defend
itself during an experiment that actually ran.

Whether an abuse experiment can fail a relay's CI is therefore a scenario
choice, not a fixed policy: configure abuse and collateral thresholds and
the run gates on them; omit them and the run reports the defended ratios as
measurement without a pass/fail verdict — the same optionality chaos
thresholds have.

## Limitations

- The abuse roles measure a relay's defenses; they do not themselves defend
  anything. A relay with no anti-abuse controls will report low defended
  ratios, which is a truthful measurement, not a burner failure.
- The three-way outcome depends on the relay surfacing defined outcome and
  error semantics. A relay that fails silently (accepts and drops, or
  rejects with no category) is recorded as a defense gap, because silence is
  exactly what section 9.6 and section 13.6 forbid.
- The `provenance_forger` role measures a consumer-side verifier, not the
  relay, and depends on the run supplying the authority record the verifier
  anchors. It does not measure how a verifier discovers or decides to trust
  an authority record — anchor selection is the consumer's policy (Overnet
  core section 7.9.1), out of scope for the forger, which supplies the
  anchor directly.

## Implementation Order

1. ~~The contract~~ (this document).
2. ~~Fixtures~~ — `scenarios/abuse-flood.yml` and
   `examples/abuse-metric-events-v1-sample.jsonl`.
3. ~~The v1 abuse roles~~ — `flooder`, `malformed_publisher`, `replayer`,
   with the `outcome` / `error_category` / `defended` / `defended_correct`
   metric members, each verified end to end against the reference relay's
   rate-limiting, signature-verification, and deduplication behavior.
4. ~~The abuse verdict~~ — the `abuse` result class, the derived ratios in
   [METRICS.md](METRICS.md), and the `>=` defense-ratio comparator in
   [REPORT.md](REPORT.md).
5. ~~`subscription_abuser`~~ — opens accumulating subscriptions and measures
   whether the relay bounds them, verified end to end against the reference
   relay's `max_subscriptions`.
6. ~~`sybil` and `connection_flood`~~ — identity churn (verified against a
   per-connection rate limit) and connection exhaustion (verified against
   the reference relay's `max_connections_per_ip`).
7. ~~`provenance_forger`~~ — publishes adapted events forging an external
   origin and measures whether the consumer-side provenance verification
   boundary (Overnet core section 7.9) resolves them to `forged` rather than
   `authoritative`, verified end to end against the reference oracle
   `Overnet::Burner::Provenance` with the reference relay carrying the
   forgeries.
