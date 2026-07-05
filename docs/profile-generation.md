# overnet-burner Profile Generation

Profile generation produces a random-but-reproducible scenario-generation
profile from a versioned template. It is the layer above scenario generation:
the generated profile defines the envelope, and a generated scenario draws one
concrete run from that envelope.

The profile template is a language-neutral YAML contract. The Perl
`Overnet::Burner::ProfileGenerator` module is the reference implementation.
The generated profile is an ordinary profile document accepted by
`Overnet::Burner::Generator`.

## Determinism

Profile generation derives every choice from `profile-seed` plus a stable path
inside the template. The same profile seed and template produce the same
profile byte for byte. Different profile seeds explore different envelopes.

The scenario seed remains separate. A fully random run therefore has two seeds:

- `profile-seed` chooses the profile envelope.
- `scenario-seed` chooses the concrete scenario inside that envelope.

## Template Document

A profile template has:

```yaml
template_version: 1
profile:
  duration:
    random_range: { min: 5, max: 30 }
  relays:
    random_range: { min: 1, max: 2 }
```

The v1 schema is:

```text
schemas/profile-template-v1.schema.json
```

The `profile` mapping is recursively expanded. Fixed scalars, lists, and maps
are copied. The following operators introduce deterministic randomness:

| Operator | Output | Description |
|---|---|---|
| `random_int: { min, max }` | integer | Draw one integer in the inclusive range. |
| `random_number: { min, max, precision }` | number | Draw one number. `precision` defaults to `3`. |
| `random_range: { min, max, min_width }` | `{ min, max }` | Draw two integers, sort them, and enforce optional minimum width. |
| `one_of: [...]` | any value | Pick one option and recursively expand it. |

An operator mapping must contain only that operator. For example, this is valid:

```yaml
roles:
  publishers:
    random_range: { min: 1, max: 5 }
```

This is invalid because it mixes an operator with ordinary fields:

```yaml
roles:
  publishers:
    random_range: { min: 1, max: 5 }
    max: 10
```

After expansion, the generated profile is normalized and validated as an
ordinary profile. Invalid templates or templates that generate invalid profiles
are rejected.

## Commands

Generate a profile:

```bash
overnet-burner generate-profile \
  --profile-seed 1001 \
  --profile-template profile-templates/local-containers.yml \
  --out profile.yml
```

Generate a scenario inside a fixed profile:

```bash
overnet-burner run \
  --random-scenario \
  --scenario-seed 42 \
  --profile profiles/local-containers-smoke.yml \
  --runner rex-local-workers
```

Generate a profile, then generate a scenario inside it:

```bash
overnet-burner run \
  --random-profile \
  --profile-seed 1001 \
  --profile-template profile-templates/local-containers.yml \
  --random-scenario \
  --scenario-seed 42 \
  --runner rex-local-workers \
  --verbose
```

Compatibility aliases remain available:

```bash
overnet-burner run --random --seed 42 --profile profiles/local-smoke.yml
```

That is equivalent to:

```bash
overnet-burner run --random-scenario --scenario-seed 42 --profile profiles/local-smoke.yml
```

## Run Ledger

For random-profile runs, the run directory records:

```text
profile-template.yml
profile.generated.yml
scenario.yml
```

`scenario.yml` is still the exact scenario that ran. `profile.generated.yml`
records the generated envelope, and `profile-template.yml` records the template
that produced it.
