# overnet-burner Adversary Harness

**Status: proposal.** This document defines a language-neutral abstraction
for driving *interactive, adaptive* attacks against an Overnet system under
test (SUT) and judging them against an independent authorization oracle. It
builds on the existing worker contract ([workers.md](workers.md)), abuse
model ([abuse.md](abuse.md)), metric events ([METRICS.md](METRICS.md)), and
run ledger. Where it conflicts with an already-implemented contract, the
implemented contract wins.

## Motivation

The abuse workers in [abuse.md](abuse.md) are *batch* adversaries: a plan
fixes the roles and rates, the workers run for a window, and the run is
scored afterward. That model covers volumetric and hygiene attacks
(flooding, malformed events, replay, sybil, provenance forgery) well, and it
is judged by a real defense oracle — the relay must reject abuse with the
*correct outcome category*, not merely survive.

Two gaps remain:

1. **No adaptive loop.** A batch worker cannot observe the SUT's response and
   choose its next move accordingly. The interesting authorization attacks
   are multi-step: authenticate as a nobody, request a delegation, forge an
   authority reference, publish a control event, *observe whether the SUT
   applied it*, and escalate. That requires an online observe → act → observe
   loop, not a fixed rate.
2. **No authority oracle.** The current oracle judges *transport and hygiene*
   defenses (was abuse rejected with the right category). It does not judge
   the *authority model*: did an unauthorized identity gain a role, did a
   forged snapshot widen authority, did two instances diverge. Those are the
   defects most likely to matter and least likely to be volumetric.

The adversary harness closes both gaps while preserving the two invariants
that make overnet-burner trustworthy: **everything reduces to a deterministic,
replayable artifact**, and **the SUT is judged by observable behavior against
the spec, never by its own say-so**.

## Design Principles

- **Mechanism, policy, and judgment are three separate things.** The harness
  owns mechanism (stand up a topology, inject actions, observe) and judgment
  (the oracle). A *driver* owns policy (what to try next). The driver is a
  pluggable client; the AI red-teamer is one driver among several.
- **The API is typed and serializable, not freeform.** Every action a driver
  can take is a named, versioned struct. "Flexible" is achieved by a rich but
  closed vocabulary of typed actions, not by an escape hatch, because every
  action must serialize into a replayable log.
- **The session log is the durable asset.** An adversarial session is an
  append-only, seeded log of actions and observations. Frozen, it is a
  regression scenario that replays without the driver that produced it. The
  driver expands the corpus; the corpus is what ships.
- **The oracle's ground truth is independent of the SUT.** Burner knows which
  identities, grants, and events it injected, and which of those were
  legitimately authorized versus forged. It computes the *correct* authority
  state from that provenance and compares it to what the SUT exposes. The SUT
  is never asked whether it is behaving.
- **The arena is disposable and isolated.** An adversary harness is an
  autonomous offensive agent by construction; it may only ever act against a
  sandboxed, resettable topology, never a real deployment.

## The Five Abstractions

### 1. Arena — the sandbox

An **arena** is a disposable, isolated Overnet topology under test, provided
through the existing [topology provider contracts](docs/topology-providers.md)
(containers, virtual guests, remote). Its lifecycle:

- `provision(baseline)` — stand up the topology from a seeded baseline
  (relays, adapters, hosted channels, seeded authoritative state).
- `reset()` — return to the exact baseline. Cheap reset is what makes each
  attack episode deterministic; implementations may snapshot or rebuild.
- `teardown()` — destroy.

The arena exposes only its declared endpoints (relay URLs, IRC listeners) and
a health probe (the existing observer `relay_ping` is the "did it stay up"
signal). The arena baseline is itself seeded and reproducible, so
"the topology the attack ran against" is a fixed input.

### 2. Session — the interaction and the artifact

A **session** binds one driver to one arena for one attack episode. It is an
append-only, ordered log:

```
session := (session_id, seed, arena_baseline_ref, [ step... ])
step     := action ⊕ observation      # each action produces observations
```

The session log is the replay artifact. Given the same arena baseline and the
same ordered actions, replaying reproduces the same observations and the same
oracle verdict, up to the SUT's own nondeterminism — which the oracle absorbs
by checking *invariants*, not exact transcripts (see §5). Any nondeterminism
lives only in the *driver*; once an action sequence is recorded it is fixed.

### 3. Action — the typed adversary vocabulary

Actions are the closed, versioned API surface. They fall in five families;
each action is a typed struct that serializes into the session log. An
adversary is powerful because it may compose these freely and supply
deliberately wrong values (mismatched signers, forged references, spoofed
masks) — not because the API is open-ended.

| Family | Representative actions | Adversary intent |
|---|---|---|
| Identity | `new_identity`, `authenticate` (OVERNETAUTH/SASL), `request_delegation`, `forge_delegation(actor, delegate, …)` | be a nobody; obtain, forge, or replay authority |
| Publish | `publish_event(raw)`, `publish_control(kind, h, tags, signer)`, `publish_snapshot(kind, signer)` | craft control/snapshot events with any signer, actor, or authority reference |
| IRC surface | `irc_connect`, `irc_line(raw)`, `join`, `mode`, `kick`, `overnetchannel(...)` | drive the presentation and moderation surface directly |
| Transport | `open_connections(n)`, `flood(rate, shape)`, `hold_open` | exhaust connection, rate, and subscription budgets |
| Observe | `read_relay_outcome(publish_ref)`, `read_derived_state(channel)`, `who`, `whois`, `read_instance_state(instance)` | learn what the SUT accepted and how it now behaves |

Observe actions are first-class: the loop is only adaptive if the driver can
read the SUT's response. Observe actions return **observations** (§4) and are
the explicit synchronization points that make replay deterministic.

The existing abuse workers are re-expressible as pre-composed action
sequences: `flooder` is `flood(rate)` plus outcome observation, and
`provenance_forger` is `publish_event` with a forged provenance plus a
derived-state read. The harness subsumes them rather than replacing them.

### 4. Observation — the typed SUT response

An **observation** is a typed record of what the SUT did in response to an
action, drawn only from its externally observable surface:

- relay outcome codes (`OK` accepted/rejected with category, `CLOSED`, error)
- IRC numerics and lines (`311`, `352`, `474`, `MODE`, `KICK`, …)
- derived-state reads (current membership, roles, bans, channel flags) as the
  SUT exposes them, per instance
- arena health (did the honest-baseline probes stay within thresholds during
  the attack — the blast-radius signal from [abuse.md](abuse.md))

Observations never include burner's private ground truth; they are only what
a real peer could see. That separation is what lets the oracle compare
independent truth against observed behavior.

### 5. Oracle — independent judgment

The **oracle** is the crux, and it is independent of both the driver and the
SUT. It maintains a **ground-truth authority model** computed from the
*provenance of the actions burner injected* — burner knows which grants were
legitimately signed versus forged, which snapshots came from a configured
authoritative identity versus a foreign key, which joins carried a valid
observed mask. From that it computes the authority state that a
spec-conformant SUT *must* hold, and evaluates a set of machine-checkable
**invariants** against the observations:

- **Authorization.** No identity holds a role, membership, or capability
  unless burner's ground truth contains a valid authority chain granting it.
  Observing the attacker as operator without a legitimate grant is a
  violation. (This is the class of C1/C2 — forged-grant escalation and
  forged-snapshot self-grant.)
- **Admission.** A join that burner knows should be refused (banned mask,
  closed channel without invite, tombstoned channel) must be refused, and one
  that should be admitted must be admitted. Omitting a mask under active bans
  must fail closed.
- **Integrity / convergence.** Two instances fed the same accepted events
  must expose the same authority state; divergence is a violation (the §8.3 /
  same-second-ordering class).
- **Defense category.** The existing abuse oracle: abusive input is rejected
  with the correct outcome category, never silently accepted or mis-typed as
  internal failure.
- **Availability / blast radius.** Honest-baseline probes stay within
  thresholds while the attack runs; a correctly-refused attack that still
  takes the relay down is still a finding.

Each invariant evaluates to `upheld`, `violated`, or `inconclusive`. A
violated invariant is a **finding**.

## Finding and Regression Corpus

A session yields a **verdict** (the invariant results) and, for each
violation, a **finding**: the minimal action trace that reproduces it,
extracted from the session log. Findings reduce to the existing `report.json`
verdict shape (extended with per-invariant results) and, crucially, are
frozen as **regression scenarios**: a fixed action log plus arena baseline
plus expected verdict, replayable forever by the `replay` driver with no AI
in the loop.

This is the ratchet. Every attack that ever succeeds becomes a permanent,
deterministic test. The corpus only grows, and CI replays all of it on every
change across every implementation — the attack that found C1 would fail the
build the moment a regression reopened it.

### Implementation: `Overnet::Burner::Adversary::Corpus`

The corpus is implemented as a module backed by a directory of JSON entries
(`corpus/adversary/*.json` by default). It is the concrete form of the ratchet
above — the durable, self-growing memory of the harness.

Each entry is a frozen attack: a `name`, the `target_invariant` it guards, an
optional `seed` and `snapshot_signers` (the arena baseline), the `actions`
(the typed adversary vocabulary of §3), and the harness's independent
`ground_truth`. The entry format is exactly the `scripted`/`replay` driver
contract — an entry replays with no AI in the loop.

The module exposes three operations:

- **`entries`** loads and validates every entry from the corpus directory,
  ordered by name so a run is reproducible.
- **`replay($entry)`** runs one entry against the live relay through the same
  arena, runner, and oracle the rest of the harness uses, and returns the
  oracle verdict. An entry *passes* when the verdict is **not** violated: the
  attack it encodes is still defended. A regression that reopens the hole flips
  the verdict and fails the run.
- **`add($entry)`** validates and persists a new entry as `<name>.json`, so a
  newly discovered attack — from the fuzzer, the adaptive driver, or by hand —
  becomes a permanent regression guard. This is the "corpus only grows" step.

The seed corpus captures the core authority and admission defenses:
forged-grant escalation and forged-snapshot self-grant (the authorization
class C1/C2) and ban-mask evasion (the admission class). CI replays the whole
corpus against the real relay in the adversary-regression job on every change,
so any regression that reopens a sealed hole fails the build.

## Driver — pluggable policy

A **driver** is any process that speaks the session API. Its interface is one
function:

```
next_actions(recent_observations, session_history, oracle_status) -> [action...]
```

Drivers are interchangeable:

- **`scripted`** — a fixed attack from a library (the authorization-adversary
  roles: forged-grant escalation, snapshot self-grant, ban evasion,
  ordering-divergence). Deterministic; the seed attacks.
- **`replay`** — re-applies a recorded session log. This is how the regression
  corpus runs in CI. Fully deterministic, no policy.
- **`coverage-guided`** — mutates valid control events along authority-relevant
  axes (swap signer, drop a required tag, shift `created_at`, reorder
  sequences), steered by which invariants and protocol surfaces are
  unexplored.
- **`ai`** — an LLM in a loop, prompted with the observed state and the
  untried surface, generating novel multi-step attack hypotheses. It is the
  most powerful and the most easily replaced; its *output* (session logs) is
  what has lasting value, and reduces to the same replayable artifact as every
  other driver.

The harness does not know or care which driver is connected. An AI driver is
guided by `oracle_status` and a coverage summary so it escalates from
transport to identity to authority rather than rediscovering flooding.

## Control API

Session-oriented, local-only, authenticated, and refusing any endpoint that
is not part of a provisioned arena. The surface is small:

```
POST   /arena                     provision a seeded baseline topology  -> arena_id
POST   /arena/{id}/reset          return to baseline
DELETE /arena/{id}                teardown
POST   /session                   open a session against an arena (seed) -> session_id
POST   /session/{id}/act          submit [action...]                    -> [observation...]
GET    /session/{id}/oracle       current per-invariant verdict
POST   /session/{id}/finalize     produce report.json; freeze regressions on violation
GET    /session/{id}/log          the replayable action/observation trace
```

The API is the durable contract. Drivers, including the AI, are clients of it;
swapping the driver never touches the harness, the oracle, or the corpus.

## Safety Requirements

Because the harness is, mechanically, an autonomous offensive agent:

- it MUST only act against a provisioned arena; the `act` endpoint MUST reject
  any target that is not an arena endpoint
- arenas MUST be disposable and isolated (the existing container/virtual guest
  layers); no arena may share state with a real deployment
- the control API MUST bind to a local, authenticated surface and MUST NOT be
  shippable enabled in a production image
- every session MUST enforce hard caps (identities, connections, duration,
  total actions) so a runaway driver cannot exhaust the host

## How It Maps to Existing Contracts

| Existing | Reused as |
|---|---|
| topology providers / guests | arena provisioning and reset |
| worker contract + metric events | actions and observations still emit metrics; the harness is a superset |
| abuse defense model | the *defense-category* invariant of the oracle |
| observer `relay_ping` | the *availability / blast-radius* invariant |
| run ledger + `report.json` | session artifact and verdict, extended with per-invariant results |
| seeded scenario reproducibility | the session log *is* the seed-equivalent; a frozen session is a deterministic scenario runnable by the `replay` driver |

The net addition is three things the current model lacks: an **online
action/observation loop**, an **independent authority oracle**, and a
**driver-agnostic server API** — with everything still collapsing to the same
deterministic, replayable, spec-judged artifacts overnet-burner already
guarantees.
