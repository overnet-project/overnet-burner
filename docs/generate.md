# overnet-burner Scenario Generation

Scenario generation produces a random-but-reproducible scenario within a
declared envelope. It exists so a run can exercise combinations of roles,
rates, chaos, and abuse that no one hand-wrote — the property-based testing
counterpart to the curated scenarios under `scenarios/`.

Like every other surface in overnet-burner, generation is defined here as a
language-neutral contract. The Perl `Overnet::Burner::Generator` is a
reference implementation; the **profile document** and the **generated
scenario** are the interfaces, and the generated scenario is an ordinary
scenario document that flows through the same validation, planning, and
running path as any hand-written one.

## Why Generate

A generated scenario is a normal scenario. `overnet-burner generate` writes
one to standard output (or a file); `overnet-burner run --random-scenario`
generates one and runs it, copying the exact document into the run ledger as
`scenario.yml`. A generated failure is therefore an immediate, committable
repro case: the same scenario seed and profile reproduce the same scenario
forever, and the scenario in the ledger can be hand-edited into a minimal
case.

## Determinism

Generation derives every choice from the scenario seed alone, using the same
construction as the rest of overnet-burner: a SHA-256 of the seed and a
stable label, reduced into the relevant bound. The same scenario seed and
profile always produce the identical scenario, byte for byte, on any host.
Nothing is drawn from wall-clock time, the process, or the host.

The seed is an ordinary scenario seed: the generated scenario carries
`run.seed`, so the run it drives is itself reproducible in the usual way.

## Always Valid

The generator's contract is that its output always passes
`overnet-burner validate`. In particular it:

- emits `topology.relays` with a count of at least one and either a provider
  or a managed environment that supplies one;
- emits relay endpoints from the profile whenever generated worker roles can
  launch, or emits a managed `environment` that synthesizes those endpoints
  during ordinary scenario normalization;
- honors the reader-workload coupling — whenever it includes `subscribers`,
  `query_readers`, or `object_readers`, it also emits the
  `subscription_filters`, `query_filters`, or `object_reads.objects` those
  workers require;
- keeps every chaos hook's `at` inside the run duration and targets a relay
  that exists, and only allows lifecycle chaos when the profile supplies an
  `external-command` relay lifecycle or a managed environment that synthesizes
  one;
- emits a `workload.abuse.<role>` block for every abuse role it includes.

A generated scenario **omits thresholds** by design. A random scenario has
no known-good latency numbers to assert, so it is judged on orchestration
and resilience invariants — no worker exits non-zero, constructed guests are
torn down, the relay stays healthy outside chaos windows — rather than on
fabricated thresholds. Threshold-based judging remains the province of the
curated scenarios.

## Profile Document

A profile bounds the random space. Every field is optional; an omitted field
takes its default, and an empty profile is exactly the built-in default
(shipped for reference as `profiles/local-smoke.yml`). A profile is a
mapping:

```yaml
duration:
  min: 5
  max: 30
relays:
  min: 1
  max: 1
  provider: generic-relay
  endpoints:
    - ws://127.0.0.1:7777
roles:
  publishers:    { min: 0, max: 3 }
  subscribers:   { min: 0, max: 3 }
  query_readers:  { min: 0, max: 2 }
  object_readers: { min: 0, max: 2 }
  observers:     { min: 0, max: 1 }
workload:
  publish_rate_per_second:      { min: 1, max: 50 }
  query_rate_per_second:        { min: 1, max: 10 }
  object_read_rate_per_second:  { min: 1, max: 5 }
  abuse_publish_rate_per_second: { min: 1, max: 200 }
chaos:
  max_hooks: 0
  actions: [restart, stop, start]
provision:
  workers: [local]
  relays: [local]
```

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `environment.kind` | `local-containers` | none | Optional managed environment to copy into generated scenarios |
| `environment.engine` | `auto`, `docker`, or `podman` | `auto` during scenario normalization | Container engine for `local-containers` |
| `environment.image` | non-empty string | `overnet-burner-reference:local` during scenario normalization | Managed reference image tag |
| `duration.min` / `duration.max` | positive integers, `min <= max` | `5` / `30` | Main-phase duration range in seconds |
| `relays.min` / `relays.max` | positive integers, `min <= max` | `1` / `1` | Relay count range |
| `relays.provider` | `generic-relay` or `external-command` | `generic-relay` for endpoint-based profiles; omitted for managed `local-containers` profiles | Topology provider to put in generated scenarios |
| `relays.endpoints` | list of non-empty strings | `ws://127.0.0.1:7777` for the one-relay endpoint profile; synthesized for managed `local-containers` profiles | Relay endpoints available to generated workers; must contain at least `relays.max` entries when worker roles can be generated outside a managed environment |
| `relays.command.start` / `.health` / `.stop` | non-empty strings | none | Lifecycle commands required when `relays.provider` is `external-command` |
| `roles.<role>.min` / `.max` | non-negative integers, `min <= max` | `min: 0` | Per-role actor-count range; a role omitted from `roles` is never generated |
| `workload.publish_rate_per_second.min` / `.max` | non-negative numbers | `1` / `50` | Publish rate range |
| `workload.query_rate_per_second.min` / `.max` | non-negative numbers | `1` / `10` | Query rate range (used when `query_readers` are generated) |
| `workload.object_read_rate_per_second.min` / `.max` | non-negative numbers | `1` / `5` | Object-read rate range (used when `object_readers` are generated) |
| `workload.abuse_publish_rate_per_second.min` / `.max` | non-negative numbers | `1` / `200` | Per-abuse-role publish rate range |
| `chaos.max_hooks` | non-negative integer | `0` | Upper bound on generated chaos hooks; the generator picks `0..max_hooks` |
| `chaos.actions` | list of relay lifecycle actions | `[restart, stop, start]` | Actions a generated hook may use |
| `provision.workers` / `provision.relays` | list of provisioning methods | `[local]` | Accepted generation-profile provisioning methods; generated scenarios omit `provision` and let scenario normalization apply the endpoint or managed-environment default |

### Roles

The honest roles are `publishers`, `subscribers`, `query_readers`,
`object_readers`, and `observers`. The abuse roles the generator can emit are
`flooders`, `malformed_publishers`, `replayers`, `subscription_abusers`,
`sybils`, and `connection_floods`; each is generated with a
`workload.abuse.<role>` publish rate. A role that is not listed under
`roles` in the profile is never generated, so the default profile — which
lists only honest roles — never produces abuse traffic.

### Relay Wiring

Relay endpoints and lifecycle commands are profile data, not random choices:
they describe the system under test. The built-in one-relay profile defaults
to `ws://127.0.0.1:7777`. If a profile can generate any worker role, it must
provide enough `relays.endpoints` entries for the maximum relay count. When a
generated scenario draws fewer relays than `relays.max`, it uses the matching
prefix of that list.

Managed `environment.kind: local-containers` profiles are the exception. They
describe only the relay count and worker topology. The generated scenario
omits relay provider, endpoints, and lifecycle commands; normal scenario
loading then expands the environment into stable container-network endpoints,
managed relay lifecycle commands, and container provisioning.

```yaml
environment:
  kind: local-containers

relays:
  min: 1
  max: 2

roles:
  publishers:  { min: 1, max: 3 }
  subscribers: { min: 1, max: 3 }
```

The shipped `profiles/local-smoke.yml` and
`profiles/local-resilience.yml` assume relays are already reachable at their
listed local endpoints. They do not start those relays. The shipped
`profiles/local-containers-smoke.yml` starts and wires the local container
reference stack from the generated topology.

Lifecycle chaos (`restart`, `stop`, `start`) requires an
`external-command` relay provider:

```yaml
relays:
  min: 1
  max: 1
  provider: external-command
  command:
    start: systemctl --user start overnet-relay
    health: curl -fsS http://127.0.0.1:7777/health
    stop: systemctl --user stop overnet-relay
  endpoints:
    - ws://127.0.0.1:7777
chaos:
  max_hooks: 2
  actions: [restart, stop, start]
```

### Bounds Beyond v1

Two areas are deliberately conservative in this contract version:

- **Provisioning.** Endpoint-based generated scenarios omit `provision`, so
  scenario normalization uses local execution. Container and virtual
  provisioning are valid scenario configuration, but generation only reaches
  container provisioning through the explicit managed `local-containers`
  environment. Arbitrary container images and virtual machines are not drawn
  at random.
- **Network chaos and `provenance_forger`.** Both require configuration the
  generator does not synthesize (a per-run bridge network; a forged origin
  and authority scope), so neither is generated. Lifecycle chaos is generated
  only for profiles with an `external-command` relay lifecycle or the managed
  `local-containers` environment. The rate-only abuse roles are generated when
  the profile includes them.

## Command-Line Interface

```bash
# Print a generated scenario (built-in default profile).
overnet-burner generate --scenario-seed 42

# Generate within a profile, into a file.
overnet-burner generate --scenario-seed 42 --profile profiles/local-resilience.yml --out scenario.yml

# Generate a random profile envelope from a versioned template.
overnet-burner generate-profile --profile-seed 1001 --profile-template profile-templates/local-containers.yml --out profile.yml

# Generate and run in one step; the exact scenario lands in the run ledger.
# The profile's relay endpoints must be reachable by the workers.
overnet-burner run --random-scenario --scenario-seed 42 --profile profiles/local-smoke.yml --runner rex-local-workers
overnet-burner run --random-scenario --scenario-seed 42 --profile profiles/local-resilience.yml --runner rex-local-workers

# Generate a managed local-container topology and let burner start the relays.
overnet-burner run --random-scenario --scenario-seed 42 --profile profiles/local-containers-smoke.yml --runner rex-local-workers --verbose

# Generate the profile envelope first, then generate and run a scenario in it.
overnet-burner run --random-profile --profile-seed 1001 --profile-template profile-templates/local-containers.yml --random-scenario --scenario-seed 42 --runner rex-local-workers --verbose
```

`generate` writes the scenario as YAML to standard output, or to `--out` when
given. `run --random-scenario` is `--scenario` replaced by generation: it
generates the scenario from `--scenario-seed` (and optional `--profile`),
then runs it exactly as if it had been passed on disk. `generate-profile`
and `run --random-profile` add the profile-generation layer documented in
[profile-generation.md](profile-generation.md). The run's `scenario.yml`,
`config.normalized.json`, and `plan.json` record precisely what ran; random
profile runs also record `profile-template.yml` and `profile.generated.yml`.
`report.json` records the run result before the command exits.
Pass `--verbose` to random runs to see generation, lifecycle, provider,
worker, chaos, and provisioning progress on standard error while preserving
the normal machine-readable run/report paths on standard output.
