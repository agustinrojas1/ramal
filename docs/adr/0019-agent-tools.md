# 0019. Branch tools for AI agents, and a context that puts an Ash call in a branch

Status: accepted, 2026-10-23. Follows ADR 0012 (proposals) and ADR 0018 (owner).

## Context

Ramal's pitch is that an agent explores alternatives in branches and a person decides. Two things stood in the way of
using it that way without writing glue. An agent's tool server (an MCP server, `AshAi`) runs each tool call in its own
request and passes `context:` to Ash; it cannot wrap the call in `Ramal.run/2`. And an agent needs the branch calls
(open, diff, propose) as tools with names, descriptions and JSON Schemas, with a guarantee that it cannot reach a branch
it was not given or approve its own work. The roadmap rules out a dependency on a specific LLM provider or agent
framework, and `AshAi` exposes only Ash actions, whereas the branch calls are plain functions.

## Decision

- **`Ramal.context/1`** returns the Ash context (`%{shared: %{ramal_branch_id: id}}`) that the hooks already read
  (ADR 0002). Passed as `context:` to a read or write it puts that call in the branch. It is the existing carrier made
  public, with no new mechanism. It does not check that the branch is open before the call (the hooks fail the action
  with `:not_found` or `:not_open`) and it does not queue notifications as `run/2` does. Ash has no documented per-call way to suppress them (the
  list is built from the resource's notifiers), so `Ramal.in_branch?/1` lets a notifier recognise a write made through
  the context and skip it.
- **`Ramal.Tools`** is a catalogue of six tools as data (`definitions/1`: name, description, JSON Schema) and one
  function (`call/3`) that runs one with the arguments a model produced: `ramal_open_branch`, `ramal_list_branches`,
  `ramal_fork_branch`, `ramal_branch_diff`, `ramal_propose_branch`, `ramal_discard_branch`. It has no dependency. The
  shape fits an MCP tool and the `tools` of the Anthropic and OpenAI APIs.
- **There is no merge, approve or reject tool.** An agent proposes; a person decides. The host calls `Ramal.approve/2`.
- **The host fixes the scope**, in options the model cannot change: `:domain` (required), `:owner`, `:proposed_by`.
  A branch id of another domain or owner is "not found". `owner: nil` raises, because it would match the unowned branches.
- Results are JSON-safe maps and errors are strings written for the model; dates, decimals and structs in a diff become
  strings.
- **Docs, not a dependency, for `AshAi`.** The guide (`docs/agents.md`) shows a plug that sets `Ramal.context/1` on an
  `AshAi.Mcp.Router` request, read from the source of `ash_ai` 1.4.0. Ramal's tests cover the `context:` contract, not
  `AshAi`.

## Consequences

- A host can give an agent a branch with a plug and nothing else, or hand it `Ramal.Tools` in any tool loop.
- Tools are scoped by the host's options, not by authorization. Ramal still does not decide who may approve.
- The `ramal_` tool names and the result keys are public from now on; a change to them is a breaking change.
- `Ramal.context/1` is the one way to run a call in a branch without `run/2`, and inherits its limits plus the two above.
- Not done: an `ash_ai` extension or an Ash resource that exposes the branch calls as actions. It would add a
  dependency on a fast-moving package; revisit if hosts ask for it.
