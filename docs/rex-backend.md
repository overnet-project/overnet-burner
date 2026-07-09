# Rex Execution Backend

`overnet-burner` is a guest-first harness: runners execute a plan through the
guest interface (local `exec`, `connect` SSH, `container`, `virtual`), and the
guest layer owns transport. Rex is the harness's **reference remote-execution
backend** — an opt-in path that a runner may select to deploy and lifecycle the
system under test on real hosts, where Rex's task model and module ecosystem
(`run`, `file`, `pkg`, `service`, and later cloud provisioners) pay off.

This document defines what "Rex genuinely performs" means, so a rendered Rex
bundle can be executed rather than only inspected. It is the contract; the Perl
runners follow it. Where this document conflicts with the implemented
contracts, the implemented contracts win.

## Two render modes

`render-rex` and the Rex runners render a bundle under `artifacts/rex/`. The
bundle has two modes:

- **`planned`** (default) — the historical render. Every lifecycle task is a
  local placeholder that only prints its phase, groups bind to `localhost`, and
  the bundle index is stamped `execution.remote_execution = "not_performed"`.
  This mode is a rendered artifact: it records *what would run* without running
  it, and is what `render-rex`, `rex-local`, and the guest-first
  `rex-local-workers` runner emit.
- **`performed`** — a real, executable bundle. Lifecycle tasks carry real Rex
  command bodies, hosts are declared with their transport and key
  authentication, and the bundle index is stamped `remote_execution = "remote"`
  (or `"local"` when every target is the controller host). This mode is what a
  Rex execution runner renders before it invokes `rex`.

The mode is additive: a `performed` bundle is a superset of the `planned` shape,
so existing consumers of the `planned` artifacts are unaffected.

## Host and authentication rendering (`performed`)

In `performed` mode the rendered `Rexfile` declares each target host from the
run's guest inventory rather than binding every group to `localhost`:

- A remote (`connect`) host renders a Rex `server` with its `address`, `user`,
  SSH `port` when non-default, `private_key` from the guest's key, and
  `auth_type => 'key'`. Rex connects over SSH with the same non-interactive,
  key-based semantics the `connect` guest transport already uses
  (`BatchMode=yes`, `StrictHostKeyChecking=accept-new`).
- A controller-local target renders a local connection so Rex runs the command
  on the controller host without an SSH round trip.

Credentials are never inlined as secrets in report output; the rendered
`Rexfile` references the key path, matching how the `connect` guest records
`key` in `guests.json`.

## What Rex performs

A Rex execution runner performs the **topology-provider lifecycle** — the
`start`, `health`, and `stop` command strings a provider descriptor supplies —
by running them as real Rex tasks on the relay's host, instead of through the
controller's `run_command` guest primitive. Each command's stdout and stderr
are captured under `logs/provider/`, each execution is recorded as a
`provider_command` runner event, and a `start` that completed is matched by a
best-effort `stop` on later failure, exactly as the guest-executed provider
runner already guarantees.

Rex task invocation goes through the same seam every Rex runner uses:
`rex -f <Rexfile> <task>`, with the executable overridable by
`OVERNET_BURNER_REX`. A non-zero Rex exit fails the run with the captured
output, and the failure is recorded before the exception propagates.

## Reported execution state

The run manifest and `report.json` carry `execution.remote_execution`, one of
`not_performed`, `local`, `remote`, or `mixed` (see `schemas/report-v1.schema.json`).
A Rex execution runner authors the truthful value:

- `remote` when it performed lifecycle commands against one or more remote
  hosts,
- `local` when every performed command ran on the controller host,
- `not_performed` remains the value for `planned`-mode renders and for runners
  that only render the bundle.

`rex_task` and `provider_command` phase events in `report.json` describe what
Rex actually ran.

## Selecting the backend

Rex execution is opt-in per run through a Rex execution runner
(`--runner rex-remote`). The guest-first runners remain the default and the
recommended path for local, container, and single-VM runs, where the guest
layer is simpler and faster than an SSH round trip. Rex is the recommended path
when the target is a fleet of real hosts and you want its deployment ecosystem.

## Deferred

This contract covers Rex performing the SUT lifecycle. Rex-driven worker
load-generation, `pkg`/`service`-based SUT installation, and cloud provisioners
(for example EC2, OpenStack, libvirt) are future extensions of this backend and
are not yet defined here.
