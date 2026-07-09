# Adversary session API

The adversary server exposes the harness as a small HTTP API so an external
driver — including an autonomous, continuously looping one — can create a
session, submit actions, read the observations the arena produced, and ask the
oracle for a verdict.

The API is transport-neutral. All behavior lives in
`Overnet::Burner::Adversary::Server`, whose `dispatch` method takes a decomposed
request (method, path, decoded body) and returns a decomposed response (status,
body) as plain Perl data. `bin/overnet-burner-adversary-server` is the only part
that touches a socket: it JSON-decodes the request body, calls `dispatch`, and
JSON-encodes the response.

Each `POST /actions` is one incremental turn of the same loop
`Overnet::Burner::Adversary::Runner` runs internally (it calls `$runner->step`
per action), so a session built over the API is the same durable, replayable
artifact as one built by the batch runner.

## Running

```
overnet-burner-adversary-server --host 127.0.0.1 --port 7480
```

## The loop a driver runs

1. `POST /sessions` to open a session, choosing an arena.
2. `POST /sessions/{id}/actions` with the next action(s); read back the
   observations the arena produced.
3. Decide the next action from those observations, and repeat step 2. This is
   where an adaptive or AI driver closes the loop.
4. `GET /sessions/{id}/verdict` at any point to have the oracle judge the
   session so far.
5. `DELETE /sessions/{id}` when done; `GET /sessions/{id}/log` for the
   replayable JSONL.

## Routes

| Method | Path | Body | Result |
| --- | --- | --- | --- |
| `GET` | `/health` | — | `{ "status": "ok" }` |
| `POST` | `/sessions` | `{ session_id, seed?, arena?, ground_truth? }` | `201 { session_id, baseline_ref, step_count }` |
| `GET` | `/sessions/{id}` | — | `{ session_id, baseline_ref, closed, step_count }` |
| `POST` | `/sessions/{id}/actions` | `{ actions: [...] }` or `{ action: {...} }` | `{ observations: [...], step_count }` |
| `GET` | `/sessions/{id}/verdict` | — | `{ verdict: { violated, invariants, findings } }` |
| `GET` | `/sessions/{id}/log` | — | `{ jsonl }` |
| `DELETE` | `/sessions/{id}` | — | `{ session_id, closed }` |

### Arena spec

The `arena` field of a create request is `{ "type": "recorded" | "live", ...params }`:

- `recorded` — a deterministic replay double (`Arena::Recorded`); `params` is
  `{ responses: [[obs, ...], ...] }`, one observation batch per action. Needs no
  live system; ideal for exercising a driver's control flow.
- `live` — drives the real authoritative relay in process (`Arena::Live`);
  `params` are the arena's constructor options (`snapshot_signers`, `seed`,
  `group_id`, ...). Requires the relay dist on `@INC`; if it is unavailable the
  create request returns a 4xx rather than crashing the server.

### Actions and observations

The action and observation vocabularies are the arena's. For the live arena see
`Overnet::Burner::Adversary::Arena::Live` — actions such as `publish_grant`,
`publish_control`, `publish_snapshot`, `join`, and `observe_capability`, and
observations such as `relay_outcome`, `observed_capability`, and
`observed_admission`. Each returned observation carries its session `seq`,
`type`, and `payload`.

### Ground truth

`ground_truth` is the oracle's independent truth for the session (for example
`authorized_capabilities` or `expected_admissions`). It is supplied at create
time by the harness, never read back from the system under test, and is what the
`verdict` is judged against.

## Errors

Client errors are returned as `{ "error": "..." }` bodies with a 4xx status
(`400` malformed, `404` unknown route or session, `409` duplicate or closed
session, `429` per-session step limit reached), not thrown.
