# overnet-burner Guest Provisioning (Design)

**Status: implemented for the workers group and `connect` for relays.** The
guest interface, the `local` method, and the `connect`, `container`, and
`virtual` methods for the workers group are implemented and tested
(containers on both Docker and podman with the engine adapter and detection
rules below; virtual machines with direct QEMU per the decisions below).
The relays group supports `local` and `connect`: a relay placed on a
`connect` guest has its topology-provider lifecycle (start, health, stop)
run on that guest over the guest's transport, through the same one-shot
`run_command` guest primitive the runner uses for the controller host.
Relay endpoint reachability from the workers is the scenario author's
responsibility for `connect` relays — the burner runs the declared
lifecycle commands on the declared guest and does not rewrite endpoints. The
`container` and `virtual` methods for relays remain proposed design,
rejected by scenario validation as not implemented yet, because a relay the
burner constructs inside a container or VM needs an endpoint-routing story
(how workers reach a relay listening inside a constructed guest) that
`connect` sidesteps. One deliberate deviation while relays run on the
controller host: **worker containers default to host networking**, because
a bridge-networked worker cannot reach relay endpoints declared as
`ws://127.0.0.1`. Worker containers MAY opt into the per-run bridge
network with `network: bridge` — required by the network chaos actions in
[chaos.md](chaos.md) — in which case the scenario author must declare
relay endpoints that are reachable **from the run network** (a host
address the containers can route to, with the relay listening on it);
endpoint rewriting is deliberately not performed, and loopback relay
endpoints are rejected at scenario validation for bridge-networked and
virtual workers, because loopback inside such a guest is the guest
itself. Other worker network modes are rejected. Where this document conflicts with the implemented
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

### Virtual Decisions

- **Direct QEMU, no libvirt.** The `virtual` method drives
  `qemu-system-x86_64` directly: dependency-light, CI-verifiable, and the
  runner needs nothing a daemon would add. Images are plain paths (qcow2
  or raw, chosen by file extension); tmt's testcloud image conventions
  are deliberately not adopted.
- **A virtual machine is an SSH guest the run constructed.** Each guest
  boots from a cloud-init NoCloud seed ISO carrying a per-run generated
  ed25519 key and a `burner` user; SSH arrives over user-mode networking
  through a per-guest `hostfwd` port on 127.0.0.1. Once reachable, the
  guest is exactly the `connect` transport. VM host keys are ephemeral by
  construction, so they are not verified. The seed is attached as a
  **virtio disk, not a CDROM**: cloud kernels (Debian's `cloud-amd64`
  flavor, for one) ship no SATA/AHCI drivers, so a CDROM seed is
  invisible to exactly the images this method exists to boot.
- **The guest console is evidence.** Every VM's serial console is
  captured to `virtual/<guest>/console.log` in the run directory, so a
  guest that never becomes reachable leaves behind the boot log that
  explains why.
- **Ephemeral disks.** Guests run with `-snapshot`: the base image is
  never modified and teardown is terminating the QEMU process.
- **Honest acceleration.** KVM is used when `/dev/kvm` is usable and TCG
  otherwise; the accelerator actually used is recorded per guest in
  `guests.json` — a TCG run must never present itself as KVM-fast.
- **Host architecture only (v1).** `hardware.arch`, when declared for a
  virtual group, must match the controller's architecture; emulating a
  foreign architecture under TCG is rejected rather than silently slow.
- **Hardware honored by construction.** `hardware.memory` and
  `hardware.cpu.cores` minimums become `-m` and `-smp` (defaults 1024 MiB
  and 1 CPU); memory units convert upward so the constructed guest never
  has less than the requirement.
- **Guest-reachable endpoints stay explicit.** Under user-mode networking
  the host is reachable at `10.0.2.2`; as with bridge containers, the
  scenario author declares relay endpoints reachable from inside the
  guest, and endpoint rewriting is deliberately not performed.
- **Dependencies.** `qemu-system-x86_64`, `genisoimage`, and `ssh-keygen`
  must be on the controller; `OVERNET_BURNER_QEMU`,
  `OVERNET_BURNER_GENISOIMAGE`, and `OVERNET_BURNER_SSH_KEYGEN` override
  the binaries (test fakes, nonstandard installs).
  `OVERNET_BURNER_QEMU_ACCEL` forces the accelerator and
  `OVERNET_BURNER_VIRTUAL_BOOT_TIMEOUT` overrides the SSH readiness
  deadline (180 seconds by default).

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

**v1 implementation:** values are a plain number or a single `=` / `>=`
comparison; memory values require a unit (`MB`, `MiB`, `GB`, `GiB`) and
`cpu.cores` must be an integer. `and`/`or` groups and the remaining
comparison operators are recognized and rejected as not implemented yet —
reserved, never misread. Declared requirements are recorded in
`guests.json` as `hardware_requirements` for every method; only `virtual`
constructs guests to match today, and the other methods do not yet
discover facts to compare against.

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
  equivalent of the `OVERNET_BURNER_WORKER` override. Local exec guests
  preflight the command before launching a worker. Remote, container, and
  virtual guests resolve it inside their own filesystem at launch time, so
  use an installed command, an absolute path, or a baked-in image command
  there.
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

**Teardown guarantees.** A constructed guest never outlives its run under
any exit the burner can observe: guests are destroyed on success (after
collection), on a handled failure (`cleanup_after_lifecycle_failure`), and
when a running burner is interrupted by `SIGINT` (Ctrl-C) or `SIGTERM` — the
runner installs a signal handler that destroys every registered guest,
removes the per-run network, then re-raises the signal so the process still
exits with signal semantics. `destroy` is idempotent and best-effort, so an
interrupt during an already-orderly teardown is a quiet no-op, and a
constructed resource is always namespaced `burner-<run_id>[-<guest>]`. The
only case that can leak is an untrappable hard kill (`SIGKILL`, power loss),
which no in-process handler can cover; those are the operator's
manual-cleanup case, and the naming scheme makes the orphans greppable
(`docker ps -a --filter name=burner-`, `pkill -f 'qemu.*burner-'`).

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
