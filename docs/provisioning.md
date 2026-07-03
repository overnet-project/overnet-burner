# overnet-burner Guest Provisioning (Design)

**Status: partially implemented.** The guest interface, the `local` method,
and the `connect` and `container` methods for the workers group are
implemented and tested (both Docker and podman, with the engine adapter and
detection rules below); `virtual` — and every method other than `local` for
the relays group — remains proposed design, rejected by scenario validation
as not implemented yet. One deliberate deviation while relays run on the
controller host: **worker containers default to host networking**, because
a bridge-networked worker cannot reach relay endpoints declared as
`ws://127.0.0.1`. Worker containers MAY opt into the per-run bridge
network with `network: bridge` — required by the network chaos actions in
[chaos.md](chaos.md) — in which case the scenario author must declare
relay endpoints that are reachable **from the run network** (a host
address the containers can route to, with the relay listening on it);
endpoint rewriting is deliberately not performed. Other worker network
modes are rejected. Where this document conflicts with the implemented
contracts, the implemented contracts win. This design deliberately borrows from
[tmt](https://github.com/teemtee/tmt), whose provision step solved the same
problem for test environments: one plan, interchangeable provisioning
backends behind a single guest interface.

## The Problem

[distributed.md](distributed.md) left worker provisioning as an open
question. The real requirement is broader than SSH hosts: a developer
smoke-testing on a laptop, a CI job scaling out with containers, a
performance lab with VMs, and a production-like deployment on real machines
should all run the **same scenario** with only the provisioning
configuration changed.

## What We Take From tmt

1. **A provision step selected by `how`.** tmt plans say
   `provision: {how: local | container | virtual | connect | ...}` and the
   rest of the plan is oblivious to the choice. Burner scenarios get the
   same switch.
2. **A uniform guest contract.** Every tmt provisioner yields a "guest"
   with a name, role, and a way to execute commands and move files; all
   later steps go through that interface. Burner runners will talk to
   guests exclusively through the same kind of handle.
3. **Roles and placement.** tmt guests carry `role` keys and step phases
   select guests via `where`. Burner guests carry roles matching plan actor
   roles, and actor placement is a deterministic function of plan and
   guests.
4. **Declarative hardware requirements.** tmt's hardware specification
   (`and`/`or` groups, comparison operators, unit-aware values) lets
   constructing provisioners build a matching guest and inventory-based
   provisioners select one. Burner adopts the same shape.
5. **Guest reuse for iteration.** tmt's `--last` / `login` workflow keeps
   guests alive between runs during development. Burner should offer the
   same convenience, because provisioning is the slow part of the loop.

## The Guest Contract

A provisioned guest is a record the runner can act on without knowing how
it came to exist:

| Field | Description |
|---|---|
| `name` | Stable id within the run (for example `worker-guest-001`) |
| `role` | Guest group role: `relays` or `workers` |
| `transport` | `exec` (local process execution) or `ssh` |
| `address`, `port`, `user`, `key` | Connection details for `ssh` transport |
| `become` | Whether privileged commands are available |
| `facts` | Discovered host facts (recorded in the ledger, never assumed) |

The guest interface offers exactly what the runners already need, no more:
run a command, push a file, pull a file, and probe a path (readiness).
Today's local behavior becomes the `exec` transport — the first
implementation step is refactoring the workers runner onto the guest
interface with a single implicit local guest and **zero behavior change**.

## Provision Methods

```yaml
provision:
  workers:
    how: container
    image: ghcr.io/overnet-project/burner-worker:latest
    count: 4
  relays:
    how: connect
    guests:
      - address: relay-1.example.net
        user: burner
        key: ~/.ssh/burner
```

| `how` | Provisions | Notes |
|---|---|---|
| `local` | Nothing — the controller host itself | The default; exactly today's behavior |
| `connect` | Nothing — attaches to machines you already have | The `hosts` sketch in distributed.md collapses into this method |
| `container` | Docker or podman containers | Cheap scale-out; shares the host kernel; the CI-testable path for everything distributed |
| `virtual` | QEMU/libvirt virtual machines | Real kernels and network stacks; honors hardware requirements by construction |

Groups are keyed by what they host (`relays`, `workers`); omitting the
`provision` section entirely means `how: local` for everything, which keeps
every existing scenario valid.

Constructing methods (`container`, `virtual`) take a `count`; attaching
methods (`connect`) take an explicit `guests` list. `local` is always a
single implicit guest.

### Container Engines

Unlike tmt, which requires podman, the `container` method MUST support both
Docker and podman behind one engine adapter:

```yaml
provision:
  workers:
    how: container
    engine: auto   # auto (default) | docker | podman
```

- The adapter uses only the CLI surface the two engines share (`run`,
  `exec`, `cp`, `inspect`, `rm`, `network create` / `network rm`), and both
  engines are exercised by the same conformance tests — an engine that
  needs special-casing beyond flag spelling is a design failure.
- `engine: auto` probes for a working engine and prefers Docker when both
  are present; the chosen engine and its version are recorded in the run
  ledger, never assumed.
- Divergences are validated at provision time rather than discovered
  mid-run: container-name DNS on user-defined networks requires
  aardvark-dns under rootless podman, and a `docker` alias that actually
  invokes podman is detected and recorded as podman.

### Container Decisions

- **One worker per container.** A guest is a container is a worker —
  placement, readiness, logs, and failure attribution stay simple and the
  isolation the report implies is real. A density knob may come later if
  container overhead proves limiting at scale; it is deliberately not in
  v1.
- **A per-run bridge network.** Each run creates its own named network
  (`burner-<run-id>`); relays are addressed by container DNS name, nothing
  is published to the host by default, parallel runs cannot contend for
  ports, and teardown removes the network. Hosts where the controller
  cannot reach bridge networks directly (macOS engine VMs) will need a
  published-port fallback, which is explicitly a fallback, not the design.
  Implemented today for the workers group as `network: bridge`: the run
  creates `burner-<run-id>`, attaches every worker container to it,
  records the network in `guests.json`, and removes it at teardown. When
  the scenario contains netem chaos actions the containers are started
  with `CAP_NET_ADMIN` (recorded per guest in `guests.json`); otherwise no
  extra capability is granted.

## Hardware Requirements

Constructed guests MAY declare requirements using tmt's shape — implicit
`and` across keys, explicit `and`/`or` groups, comparison operators, and
unit-aware values:

```yaml
provision:
  relays:
    how: virtual
    count: 3
    hardware:
      memory: ">= 8 GB"
      cpu:
        cores: ">= 4"
```

`virtual` constructs guests to match; `container` and `local` record the
requirement and their actual facts in the ledger and warn when they cannot
honor it — a run must never silently pretend it got the hardware it asked
for. `connect` validates discovered facts against the requirement and
fails the run on mismatch.

**v1 scope (decided):** `arch`, `memory`, and `cpu.cores`, with the full
grammar (`and`/`or` groups, operators, units) parsed and reserved so
scenarios written today stay valid as coverage grows. A requirement key
outside the implemented set is a validation error, not a silent no-op.

## Placement

Plan actors are placed onto the guests of their group round-robin by actor
ordinal — the same deterministic rotation used for relay endpoint
assignment. Placement is recorded in `artifacts/rex/actor-hosts.json` and
in the report topology section. The same scenario, seed, and provision
configuration always produce the same placement.

## Worker Provisioning (the distributed.md question)

Both answers, per group:

- **Pre-provisioned** (preferred, and the only option for non-Perl
  workers): the group declares `worker: <command>`, the per-guest
  equivalent of today's `OVERNET_BURNER_WORKER` override. The prepare step
  verifies the command exists on every guest of the group and fails the
  run early if not.
- **Prepare scripts**: a group MAY declare `prepare` commands (mirroring
  tmt's shell prepare) that run on each guest before workers launch —
  installing a worker, pulling an image, warming caches. Prepare failures
  are orchestration failures.

Worker input documents are always pushed through the guest interface;
they are the topology exposure (the analogue of tmt's `TMT_TOPOLOGY_*`),
and the worker contract remains byte-for-byte unchanged.

## Run Lifecycle

Provisioning slots into the existing runner phases:

1. **provision** (new) — construct or attach guests, discover facts,
   record `guests.json` in the ledger, capture per-guest clock offsets
   (the fanout honesty mechanism from distributed.md).
2. **prepare** — run group prepare commands, verify worker commands, push
   worker inputs.
3. **start / observe / collect** — unchanged semantics, executed through
   the guest interface; metric streams are pulled back to the controller
   before aggregation, and a stream that cannot be pulled is a missing
   stream under the existing report rules. Worker stdout and stderr are
   also pulled back into the controller's run directory for non-local
   guests — including, best-effort, when the run fails — so guest
   teardown never destroys the evidence needed to diagnose a failure.
4. **finish** — orderly guest teardown, unless guests are kept.

**Guest reuse:** a `--keep-guests` run leaves guests provisioned and
records them; a later run can `--reuse-guests` to skip provisioning
entirely, and a `guest login <name>` convenience should exist for
debugging. Reused guests are recorded as reused in the ledger — a report
must never present a warm, dirty guest as a cold, clean one.

## Composition With Topology Providers

Provisioning and topology providers stay orthogonal: provisioning decides
**where** things run; the topology provider decides **how the relay under
test starts**. A relay actor placed on a guest runs its provider lifecycle
commands (start, health, stop — and chaos hooks) through that guest's
interface instead of the controller's local shell. Nothing in the provider
contract changes.

## Implementation Order

1. **Guest interface refactor** — introduce the guest abstraction with the
   `exec` transport under the existing workers runner; behavior identical,
   proven by the untouched test suite.
2. **`connect`** — SSH transport; testable in CI against `127.0.0.1` when
   sshd is available.
3. **`container`** — podman/docker; this is the milestone that makes
   distributed behavior testable in CI, and therefore the one that matters
   most.
4. **`virtual`** — QEMU/libvirt with hardware requirements; lab
   environments.

## Readiness At Scale

Readiness is probed per guest, not per worker: one aggregate command per
guest per poll cycle (list the ready-file directory through the guest
interface), so polling cost scales with the number of guests. This stays
agentless — no daemon is deployed to guests, and everything runs through
the same four-operation guest interface.

## Open Questions

- Whether the published-port network fallback should be automatic when the
  bridge network is unreachable from the controller, or always an explicit
  scenario choice.
- Whether `virtual` should reuse tmt's testcloud image conventions or take
  plain QCOW2 paths only.
