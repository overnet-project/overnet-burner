# overnet-burner Guest Provisioning (Design)

**Status: proposed design.** Nothing in this document is normative until it
is implemented and tested; where it conflicts with the implemented
contracts, the implemented contracts win. This design deliberately borrows
from [tmt](https://github.com/teemtee/tmt), whose provision step solved the
same problem for test environments: one plan, interchangeable provisioning
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
| `container` | Podman/Docker containers | Cheap scale-out; shares the host kernel; the CI-testable path for everything distributed |
| `virtual` | QEMU/libvirt virtual machines | Real kernels and network stacks; honors hardware requirements by construction |

Groups are keyed by what they host (`relays`, `workers`); omitting the
`provision` section entirely means `how: local` for everything, which keeps
every existing scenario valid.

Constructing methods (`container`, `virtual`) take a `count`; attaching
methods (`connect`) take an explicit `guests` list. `local` is always a
single implicit guest.

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
   stream under the existing report rules.
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

## Open Questions

- Whether container guests should get one worker per container or many
  (tmt is one-guest-one-container; workers are lighter than test suites,
  so a density knob may be worth it).
- Whether relay guests provisioned as containers should publish ports to
  the host network or use a shared network namespace per run.
- How far to take the hardware specification in v1 — likely `memory`,
  `cpu.cores`, and `arch` only, with the grammar reserved for the rest.
