# Ramal and AshAi

A small Mix project that runs [AshAi](https://hexdocs.pm/ash_ai) tools inside a Ramal branch, pinned to `ash_ai` 1.4.0.
CI runs it, so the claims in [`docs/agents.md`](../../docs/agents.md) about AshAi are checked, not only read.

```
cd examples/ash_ai
mix deps.get
mix ci
```

What it shows, and tests:

- `Farm` exposes a read tool and a write tool. A scripted agent turn runs them with `context: Ramal.context(branch)`; the
  data layer is untouched, `Ramal.diff/1` is what the tools wrote, and `Ramal.propose/2` freezes it.
- `RamalAshAiExample.BranchPlug` takes the branch id from an `x-ramal-branch` header and checks that the branch belongs to
  the caller before putting it in the request's Ash context. `AshAi.Mcp.Router` is driven with `Plug.Test` behind it.
- `Ramal.Tools` and the AshAi tools work in one loop.
- An AshAi `update` or `destroy` tool is a bulk action (`Ash.bulk_update!/4` on a `limit(1)` query), which a branch refuses;
  the write tool is a generic action that updates the one record itself.

The data layer is ETS, so no database is needed.
