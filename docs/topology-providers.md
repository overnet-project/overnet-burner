# Topology Providers

Topology providers are the implementation-under-test boundary in
`overnet-burner`. Provider descriptors only describe what a relay
implementation needs for lifecycle orchestration; runners choose the execution
backend that performs it — the guest interface by default, or Rex when a Rex
runner is selected (see [rex-backend.md](rex-backend.md)).

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
under `artifacts/rex/topology-provider.json` and per-relay actor config. The
current `rex-local` runner invokes Rex tasks from the rendered `Rexfile`
using `rex`, or `OVERNET_BURNER_REX` when an alternate executable is needed,
while preserving those planned command artifacts without executing the command
strings.

Provider command execution is opt-in through the `rex-local-provider` runner.
It reads `start`, `health`, and `stop` commands from the rendered
`topology-provider.json`, writes command stdout and stderr under
`logs/provider/`, records command events in `logs/runner.jsonl`, and attempts
`stop` cleanup for relays whose `start` command completed before a later
failure. `rex-local-provider` executes those commands through the controller's
guest primitive.

The `rex-remote` runner performs the same lifecycle through **real Rex tasks**
against each relay's host, renders the bundle in `performed` mode, and reports a
truthful `execution.remote_execution` value. See
[rex-backend.md](rex-backend.md).

## Relay Endpoints

Scenarios that launch workers declare the client-facing endpoint of each
relay, since only the scenario author knows the addresses their provider
commands bind:

```yaml
topology:
  relays:
    count: 1
    provider: external-command
    command:
      start: ...
      health: ...
      stop: ...
    endpoints:
      - ws://127.0.0.1:7777
```

`endpoints` is optional, but when present it must list exactly one non-empty
endpoint per relay, in relay ordinal order. Plans copy each endpoint onto its
relay actor, and worker input documents receive the full list under
`endpoints.relays`.
