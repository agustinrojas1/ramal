# Ramal for AI agents

An agent that changes real data is risky; an agent that changes a **branch** is not. The pattern Ramal is built for:

1. A branch is opened for the agent (by your orchestrator or by the agent).
2. The agent reads and writes inside it with your own Ash actions, so validations and policies still apply.
3. It looks at the result (`diff`, `aggregate`), forks to try a variation, and discards what it will not keep.
4. It **proposes** the best branch. A person (or a stricter program) reads the diff and approves or rejects.

Nothing reaches the database before step 4's approval, for every resource that uses `Ramal.Resource`, and an agent that holds only the tools below cannot approve. A resource that opted out with `branchable? false` is written for real (`Ramal.branch/2` refuses a domain with a resource that neither uses the extension nor opts out), and an agent whose tools run in processes other than a `Task` must call `Ramal.run/2` in them.

This guide has three parts: [teaching a coding agent how to use Ramal](#teach-a-coding-agent), [giving a running agent the
branch tools](#give-an-agent-the-branch-tools), and [wiring a branch into an MCP server](#run-an-mcp-servers-tools-in-a-branch).

## Teach a coding agent

Ramal ships its rules for coding agents (Claude Code, Cursor, Copilot) in the format of the
[`usage_rules`](https://hex.pm/packages/usage_rules) package: a `usage-rules.md` and a skill.

```elixir
# mix.exs
{:usage_rules, "~> 1.2", only: :dev},

defp usage_rules do
  [
    file: "AGENTS.md",
    usage_rules: [:ramal],
    skills: [location: ".claude/skills", package_skills: [:ramal]]
  ]
end
```

Add `usage_rules: usage_rules()` to `project/0` and run `mix usage_rules.sync`. The rules go into `AGENTS.md`, and the
skill (`usage-rules/skills/ramal/SKILL.md`) is copied to `.claude/skills/ramal/`. Without `usage_rules`, copy those two
files from [the repository](https://github.com/agustinrojas1/ramal) by hand: they are plain Markdown.

## Give an agent the branch tools

`Ramal.Tools` is the agent's side of the API as data: six tools with a name, a description and a JSON Schema, and one
function that runs a tool call. It depends on no AI library.

| Tool | Does |
|---|---|
| `ramal_open_branch` | Opens a branch; returns its id |
| `ramal_list_branches` | Lists the agent's branches, optionally by status |
| `ramal_fork_branch` | Copies a branch to try a variation |
| `ramal_branch_diff` | Lists what a branch changed, row by row |
| `ramal_propose_branch` | Freezes a branch and offers it for approval, with a reason |
| `ramal_discard_branch` | Throws a branch away |

There is no merge, approve or reject tool, on purpose. You decide the scope in options the model cannot change:

```elixir
opts = [domain: MyApp.Farm, owner: "session-42", proposed_by: "planner agent"]
```

With `owner:` the agent opens branches owned by `"session-42"` and sees no others, whatever id it passes (a foreign id is
reported as not found). `owner: nil` raises, because it would match every unowned branch.

The definitions have the shape of an MCP tool (`name`, `description`, `inputSchema`) and of the Anthropic API's `tools`
(`name`, `description`, `input_schema`). Pass them to your model, and route each tool call back:

```elixir
tools = Ramal.Tools.definitions(opts)
# ... send `tools` with your messages, along with your own tools for reading and writing the farm ...

def run_tool(%{name: "ramal_" <> _ = name, input: input}, opts) do
  case Ramal.Tools.call(name, input, opts) do
    {:ok, result} -> %{is_error: false, content: Jason.encode!(result)}
    {:error, message} -> %{is_error: true, content: message}
  end
end
```

The agent still needs tools for the application's own data (`list_herds`, `move_herd`, ...). Those are yours. Give each a
`branch_id` argument and run it in the branch, so the agent chooses which alternative it works in:

```elixir
def run_tool(%{name: "move_herd", input: %{"branch_id" => branch_id, "herd" => herd, "paddock" => paddock}}, opts) do
  # The model chose the id, so check that the branch is the session's before running anything in it: Ramal.run/2
  # accepts any id. A branch of another owner is reported as not found, as Ramal.Tools does.
  with {:ok, %Ramal.Branch{owner: owner}} when owner == opts[:owner] <- Ramal.get(branch_id) do
    Ramal.run(branch_id, fn -> MyApp.Farm.move_herd(herd, paddock, actor: agent_actor) end)
  else
    _ -> {:error, "not_found: no branch with that id"}
  end
  |> to_tool_result()
end
```

When the agent has proposed, your code (not the agent) shows `Ramal.diff/1` to a person and calls
`Ramal.approve(branch, decided_by: person.id, actor: person)` or `Ramal.reject/2`. The
[inspector](https://github.com/agustinrojas1/ramal/tree/main/ramal_live) is a page for exactly that.

## Run an MCP server's tools in a branch

An MCP server such as [`AshAi.Mcp.Router`](https://hexdocs.pm/ash_ai) runs each tool call in its own request and passes
the request's Ash context to the action. `Ramal.context/1` is a context that puts the action in a branch, so a plug can
give every tool call of a request the same branch:

```elixir
defmodule MyAppWeb.RamalBranchPlug do
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  # The orchestrator opens the branch and gives the MCP client its id as a header, so the agent never chooses it.
  @impl true
  def call(conn, _opts) do
    case Plug.Conn.get_req_header(conn, "x-ramal-branch") do
      [branch_id] ->
        # A client sets this header, so it is not trusted: the branch must belong to the caller, or any client could
        # read and write any branch. `conn.assigns.current_user` stands for however your app identifies the caller.
        case Ramal.get(branch_id) do
          {:ok, %Ramal.Branch{owner: owner}} when owner == conn.assigns.current_user.id ->
            Ash.PlugHelpers.set_context(conn, Ramal.context(branch_id))

          _ ->
            conn |> Plug.Conn.send_resp(404, "no such branch") |> Plug.Conn.halt()
        end

      _ ->
        conn |> Plug.Conn.send_resp(400, "x-ramal-branch is required") |> Plug.Conn.halt()
    end
  end
end

# router.ex
pipeline :mcp do
  plug MyAppWeb.RamalBranchPlug
end

scope "/mcp" do
  pipe_through :mcp
  forward "/", AshAi.Mcp.Router, tools: [:list_herds, :move_herd], otp_app: :my_app
end
```

Every `AshAi` tool of that request now reads and writes the branch. When the agent is done, the orchestrator calls
`Ramal.diff/1` and `Ramal.propose/2` (or hands the agent `Ramal.Tools` over another channel).

What is tested: [`examples/ash_ai`](https://github.com/agustinrojas1/ramal/tree/main/examples/ash_ai) is a Mix project
that runs in CI against `ash_ai` **1.4.0** (pinned). It exposes a read tool and a write tool of a small domain, drives
them through `AshAi.Tools.execute/4` and through `AshAi.Mcp.Router` with `Plug.Test` behind the plug above, and checks that
the data layer is untouched, that `Ramal.diff/1` is exactly what the tools wrote, that `Ramal.propose/2` freezes it, that a
caller who names a branch it does not own gets a 404 and that `Ramal.Tools` and the AshAi tools work in one loop. The
claims above about the context (AshAi reads the conn's Ash context in `AshAi.Mcp.Server.handle_post/4` and hands `context[:context]` to the action
in `AshAi.Tool.Execution`) are therefore checked against that version, not only read.

**An AshAi `update` or `destroy` tool does not work in a branch.** AshAi 1.4.0 runs them with `Ash.bulk_update!/4` and
`Ash.bulk_destroy!/4` on a query with `limit(1)` (`AshAi.Tool.Execution.run_update/7`), and a branch refuses every bulk
action (`:bulk_unsupported`, ADR 0005): the stream strategy writes through the data layer without calling the capture hook.
Read and create tools are fine. For a write that updates or destroys, expose a generic action that does the single-record
call itself and make it the tool; the example's `move_herd` is one, and passes the branch on with
`Ash.Scope.to_opts(context)`:

```elixir
action :move_herd, :struct do
  constraints instance_of: __MODULE__
  argument :id, :uuid, allow_nil?: false
  argument :paddock, :string, allow_nil?: false

  run fn input, context ->
    opts = Ash.Scope.to_opts(context)

    __MODULE__
    |> Ash.get!(input.arguments.id, opts)
    |> Ash.Changeset.for_update(:move, %{paddock: input.arguments.paddock}, opts)
    |> Ash.update(opts)
  end
end
```

`Ramal.Tools` and the AshAi tools go in one tool list: the model opens a branch with `ramal_open_branch`, the host runs each
AshAi tool call with `context: Ramal.context(id)` for the id it got from that call (owned by the caller), and the model
proposes with `ramal_propose_branch`. The example's second test does exactly that.

Two differences from `Ramal.run/2` to know about:

- **Notifications are not held back.** Inside `run/2` the notifications of a write are dropped unless the resource sets
  `notify_in_branch? true`. With `context:` the notifier fires, so a "herd moved" email would go out for a what-if.
  Ash has no per-call way to hold notifications back, so make the notifier skip them:
  `unless Ramal.in_branch?(notification), do: send_the_email(notification)`. Prefer `run/2` where you can wrap the call.
- **A bad branch fails the action, not the plug.** An unknown or frozen branch makes the tool call return
  `not_found` / `not_open`. The plug above does not look the branch up; add `Ramal.get/1` if you want a 4xx.

## Things an agent gets wrong

The full list is in [usage-rules.md](https://github.com/agustinrojas1/ramal/blob/main/usage-rules.md). The ones that bite
an unattended agent:

- It merges when it should propose. Do not give it `Ramal.merge/2`.
- It forks a branch and merges both. The second merge is `:stale`; that is the guard working.
- It uses a bulk action. Bulk actions and upserts are refused inside a branch; it must loop over single-row actions. An AshAi `update` or `destroy` tool is a bulk action (see above).
- It forgets branches. Set `max_active_branches` and `branch_rate` on `Ramal.Supervisor` when an agent can open branches.
- It filters or sorts on an aggregate declared on the resource (`filter head_count > 10`). That is judged on the base rows; an aggregate it only loads is computed from the branch, and `Ramal.aggregate/4` gives one total.
