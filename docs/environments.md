# overnet-burner Environments

An environment is the high-level answer to where an Overnet experiment runs.
It keeps ordinary scenarios in Overnet terms: topology, workload, chaos, and
thresholds. Low-level container images, worker commands, relay lifecycle
commands, and endpoint wiring are derived by the environment when it can do so
without losing reproducibility.

`provision` remains the expert interface. Use it when testing a custom relay
image, attaching to existing hosts, or deliberately controlling guest details.
Use `environment` when the burner should construct a complete reference stack
for the scenario.

## local-containers

```yaml
environment:
  kind: local-containers
  engine: docker  # optional: auto (default), docker, or podman

run:
  name: local-containers-smoke
  duration: 30
  seed: 12345

topology:
  relays:
    count: 2
  publishers:
    count: 2
  subscribers:
    count: 1

workload:
  publish_rate_per_second: 5
  subscription_filters:
    - kinds: [7800]
```

`local-containers` builds the managed reference image from the active
Overnet checkouts, creates a per-run bridge network, starts one relay
container per configured relay, starts worker containers, runs the workload,
collects the report evidence, stops relays, removes containers, and removes
the network.

The environment synthesizes:

- `topology.relays.provider: external-command`
- relay endpoints as `ws://relay-001:7447`, `ws://relay-002:7447`, and so on
- relay lifecycle commands for the reference `overnet-relay.pl`
- `provision.relays.how: container`
- `provision.workers.how: container`
- `provision.*.managed_image: reference`
- `provision.workers.worker: overnet-burner worker`

The stable relay names are container-network aliases. Actual container names
still include the run id, so parallel runs do not collide.

The managed image tag defaults to `overnet-burner-reference:local`. The image
contains the active `core-perl`, `relay-perl`, and `overnet-burner` checkout
code plus their CPAN dependencies. Because the image is built from the
checkout, the run tests the code being developed, not a previously published
artifact.

## external-relays

```yaml
environment:
  kind: external-relays
  relays:
    - ws://127.0.0.1:7447   # a relay that is already deployed and running

run:
  name: external-relays-smoke
  duration: 60
  seed: 12345

topology:
  publishers:
    count: 1
  subscribers:
    count: 1

workload:
  publish_rate_per_second: 5
```

`external-relays` is the front door for driving load against a relay stack
that is **already deployed and running** — for example the podman-deployed
generic or authority relay published on the host. Unlike `local-containers`,
burner provisions and manages nothing about those relays: it does not build an
image, start a container, or run any relay lifecycle command. It only points
its workers at the endpoints you name.

The environment synthesizes:

- `topology.relays.provider: generic-relay` (the no-lifecycle provider, so
  burner never tries to start, health-check, or stop the deployed relays)
- `topology.relays.endpoints` from the `relays` list, in order
- `topology.relays.count` from the number of endpoints

An explicit `topology.relays.*` still wins, so an operator can override any
synthesized field. Workers are left at their default (`provision.workers.how:
local`); set `provision.workers` explicitly to run the load from containers or
remote guests instead. When workers run on a bridge network or in virtual
guests, loopback relay endpoints are rejected, because a guest cannot reach the
controller's loopback — name an address the guests can actually reach.

The example scenario ships as
[`scenarios/external-relays-smoke.yml`](../scenarios/external-relays-smoke.yml).
The command-line adversary replay
(`overnet-burner-adversary-replay --relay-url ...`) is the companion path for
pointing the adversary, rather than steady-state load, at the same deployment.

## Contract

The `environment` mapping currently supports:

| Field | Type | Description |
|---|---|---|
| `kind` | string | Required. One of `local-containers` or `external-relays`. |
| `engine` | string | `local-containers` only. Container engine: `auto`, `docker`, or `podman`. Defaults to `auto`. |
| `image` | string | `local-containers` only. Managed reference image tag. Defaults to `overnet-burner-reference:local`. |
| `relays` | list | `external-relays` only. Required. One or more `ws://` or `wss://` endpoints of the deployed relays. |

Unknown environment kinds and unknown fields are rejected, and each kind
accepts only its own fields. A `local-containers` scenario must use the managed
external-command relay provider, because burner owns relay startup and shutdown
for that run. An `external-relays` scenario must use the `generic-relay`
provider, because burner is only a client of the deployed relays and must not
manage their lifecycle.

## Running

From the top-level Overnet Perl checkout:

```bash
plx perl overnet-burner/bin/overnet-burner run \
  --scenario overnet-burner/scenarios/local-containers-smoke.yml \
  --runs-dir overnet-burner/runs \
  --runner rex-local-workers \
  --verbose
```

For a randomized managed topology:

```bash
plx perl overnet-burner/bin/overnet-burner run \
  --random-scenario \
  --scenario-seed 42 \
  --profile overnet-burner/profiles/local-containers-smoke.yml \
  --runs-dir overnet-burner/runs \
  --runner rex-local-workers \
  --verbose
```

Docker or podman must be available on the controller host. The first run may
take longer because it builds the reference image and installs CPAN
dependencies inside that image. `--verbose` streams lifecycle and provisioning
progress to standard error while leaving standard output as the completed run
and report paths.
