# Topology Providers

Topology providers are the implementation-under-test boundary in
`overnet-burner`. Rex remains the execution substrate; provider descriptors
only describe what a relay implementation needs for lifecycle orchestration.

## `generic-relay`

`generic-relay` is the simple built-in provider used by the baseline scenario.
It does not require implementation-specific command data.

## `external-command`

`external-command` is the first descriptor path for arbitrary
Overnet-compatible relay implementations. It keeps lifecycle commands in the
scenario, plan, and Rex bundle artifacts without executing them during
validation, planning, or `render-rex`.

```yaml
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: python -m pyovernet.relay --config {config}
      stop: pkill -f pyovernet.relay
      health: curl -fsS http://127.0.0.1:{port}/health
```

The `start`, `stop`, and `health` command fields are required non-empty
strings. Rendered Rex bundles record those commands as planned lifecycle hints
under `artifacts/rex/topology-provider.json` and per-relay actor config.
