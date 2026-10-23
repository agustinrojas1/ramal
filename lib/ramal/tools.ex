defmodule Ramal.Tools do
  @moduledoc """
  The branch tools an LLM agent can call, as plain data and one function, for any tool loop or MCP server.

  An agent explores alternatives in branches and a person decides which one happens. This module is the agent's half
  of `Ramal.branch/2`, `Ramal.list/2`, `Ramal.fork/2`, `Ramal.diff/1`, `Ramal.propose/2` and `Ramal.discard/1`. It does
  **not** expose `merge/2`, `approve/2` or `reject/2`: an agent proposes, a person decides (ADR 0019). It depends on no
  AI library: `definitions/1` returns the name, description and JSON Schema of each tool, which is the shape of an MCP
  tool and of the `tools` of the Anthropic and OpenAI APIs, and `call/3` runs one.

  The tools carry branch ids. The agent's reads and writes of the application's own data are the host's tools, run in a
  branch with `Ramal.run/2` or with `Ramal.context/1` as the `context` option of the Ash call; the guide in
  `usage-rules.md` shows both.

  ## Options

  Both functions take the same options, which the host sets and the model cannot change:

    * `:domain` - required. The Ash domain whose branches the tools open and see. A branch of another domain is reported
      as not found
    * `:owner` - when given, the tools open branches with that owner and see only branches with it (ADR 0018), whatever
      id the model passes. Pass the id of the agent's user or session, never `nil` (that raises). Without it the tools
      see every branch of the domain, so the agent can fork, diff and propose branches that belong to other people:
      set `:owner` whenever more than one person or session shares the domain
    * `:proposed_by` - what `ramal_propose_branch` records as the proposer, any term. Default `nil`

  The values in a diff go to the model's provider. Attributes marked `sensitive?` appear as `"[redacted]"` (see
  `Ramal.Change.redact/1`); every other value is sent as it is. `ramal_discard_branch` refuses a branch a person is
  reviewing (status `proposed`).

  ## Example

      opts = [domain: MyApp.Farm, owner: "session-42", proposed_by: "planner agent"]

      [%{name: "ramal_open_branch"} | _] = Ramal.Tools.definitions(opts)

      {:ok, %{"id" => id}} = Ramal.Tools.call("ramal_open_branch", %{"name" => "move R7"}, opts)
      {:ok, %{"changes" => []}} = Ramal.Tools.call("ramal_branch_diff", %{"branch_id" => id}, opts)
  """

  alias Ramal.{Branch, Change, Error}

  @type definition :: %{name: String.t(), description: String.t(), input_schema: map}

  @branch_id %{
    "type" => "string",
    "description" => "The id of a branch, as an earlier tool call returned it."
  }

  @tools [
    %{
      name: "ramal_open_branch",
      description:
        "Open a new branch: a private copy of the application's data in which you can try changes without " <>
          "touching the real data. Returns the branch id. Nothing you do in a branch is real until a person approves it.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "A short label for people, such as the goal."
          }
        },
        "additionalProperties" => false
      }
    },
    %{
      name: "ramal_list_branches",
      description: "List your branches, optionally only those with one status.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "status" => %{
            "type" => "string",
            "enum" => ["open", "proposed", "merged", "rejected", "discarded"],
            "description" => "Only branches with this status."
          }
        },
        "additionalProperties" => false
      }
    },
    %{
      name: "ramal_fork_branch",
      description:
        "Copy a branch as it is now into a new open branch, to try a variation without losing the original. " <>
          "Returns the new branch id.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"branch_id" => @branch_id},
        "required" => ["branch_id"],
        "additionalProperties" => false
      }
    },
    %{
      name: "ramal_branch_diff",
      description:
        "List what a branch changed compared with the real data: for each row, whether it was created, updated or " <>
          "deleted and the before and after value of each attribute. Read it before you propose.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"branch_id" => @branch_id},
        "required" => ["branch_id"],
        "additionalProperties" => false
      }
    },
    %{
      name: "ramal_propose_branch",
      description:
        "Offer a branch to a person for approval. The branch is frozen: it takes no more changes, and the diff the " <>
          "person reads is the diff that would be applied. Say in the reason what the change achieves.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "branch_id" => @branch_id,
          "reason" => %{"type" => "string", "description" => "Why this change should be applied."}
        },
        "required" => ["branch_id", "reason"],
        "additionalProperties" => false
      }
    },
    %{
      name: "ramal_discard_branch",
      description:
        "Throw a branch away. Use it for an alternative you will not propose. A branch you have proposed cannot be discarded.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"branch_id" => @branch_id},
        "required" => ["branch_id"],
        "additionalProperties" => false
      }
    }
  ]

  @doc """
  The tools as data: a list of `%{name, description, input_schema}`, where `input_schema` is a JSON Schema object.

  ## Example

      Ramal.Tools.definitions(domain: MyApp.Farm) |> Enum.map(& &1.name)
      #=> ["ramal_open_branch", "ramal_list_branches", "ramal_fork_branch", "ramal_branch_diff",
      #=>  "ramal_propose_branch", "ramal_discard_branch"]
  """
  @spec definitions(keyword) :: [definition]
  def definitions(opts) do
    _domain = fetch_domain!(opts)
    @tools
  end

  @doc """
  Runs the tool called `name` with the arguments a model produced (a map with string keys).

  Returns `{:ok, map}` with a JSON-safe result, or `{:error, message}` with a message written for the model to read and
  act on. It never raises on bad arguments, and never touches a branch the options do not allow.

  ## Example

      {:ok, %{"id" => id, "status" => "open"}} = Ramal.Tools.call("ramal_open_branch", %{}, domain: MyApp.Farm)
      {:error, "branch_id is required"} = Ramal.Tools.call("ramal_branch_diff", %{}, domain: MyApp.Farm)
  """
  @spec call(String.t(), map, keyword) :: {:ok, map} | {:error, String.t()}
  def call(name, args, opts) when is_binary(name) and is_map(args) do
    domain = fetch_domain!(opts)
    run(name, args, domain, opts)
  end

  defp fetch_domain!(opts) do
    # `owner: nil` would match every unowned branch (ADR 0018), the opposite of scoping, so it is refused as a mistake.
    if Keyword.has_key?(opts, :owner) and is_nil(opts[:owner]) do
      raise ArgumentError,
            "Ramal.Tools got `owner: nil`; pass the owner's id, or leave :owner out to see every branch"
    end

    case Keyword.fetch(opts, :domain) do
      {:ok, domain} when is_atom(domain) and not is_nil(domain) ->
        domain

      _ ->
        raise ArgumentError,
              "Ramal.Tools needs the :domain option, the Ash domain whose branches the tools see"
    end
  end

  defp run("ramal_open_branch", args, domain, opts) do
    with {:ok, name} <- optional_string(args, "name"),
         {:ok, branch} <- Ramal.branch(domain, name: name, owner: opts[:owner]) do
      {:ok, summary(branch)}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  defp run("ramal_list_branches", args, domain, opts) do
    with {:ok, filters} <- status_filter(args),
         {:ok, branches} <- Ramal.list(domain, filters ++ owner_filter(opts)) do
      {:ok, %{"branches" => Enum.map(branches, &summary/1)}}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  defp run("ramal_fork_branch", args, domain, opts) do
    with {:ok, branch} <- scoped(args, domain, opts),
         {:ok, fork} <- Ramal.fork(branch) do
      {:ok, summary(fork)}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  defp run("ramal_branch_diff", args, domain, opts) do
    with {:ok, branch} <- scoped(args, domain, opts),
         {:ok, changes} <- Ramal.diff(branch) do
      {:ok, %{"branch" => summary(branch), "changes" => Enum.map(changes, &change/1)}}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  defp run("ramal_propose_branch", args, domain, opts) do
    with {:ok, branch} <- scoped(args, domain, opts),
         {:ok, reason} <- required_string(args, "reason"),
         {:ok, proposed} <- Ramal.propose(branch, proposed_by: opts[:proposed_by], reason: reason) do
      {:ok, summary(proposed)}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  defp run("ramal_discard_branch", args, domain, opts) do
    with {:ok, branch} <- scoped(args, domain, opts),
         :ok <- not_proposed(branch),
         :ok <- Ramal.discard(branch) do
      {:ok, %{"id" => branch.id, "status" => "discarded"}}
    else
      {:error, error} -> {:error, message(error)}
    end
  end

  defp run(name, _args, _domain, _opts), do: {:error, "unknown tool #{inspect(name)}"}

  # A proposed branch is in front of a person; the agent that proposed it must not be able to withdraw it.
  defp not_proposed(%Branch{status: :proposed}),
    do:
      {:error, "proposed: a person is reviewing this branch, so it cannot be discarded by a tool"}

  defp not_proposed(_branch), do: :ok

  # The model chooses the id, so it is checked against the domain and the owner the host configured. A branch outside
  # them is "not found", the same answer as for an id that does not exist.
  defp scoped(args, domain, opts) do
    with {:ok, id} <- required_string(args, "branch_id"),
         {:ok, branch} <- Ramal.get(id),
         true <- in_scope?(branch, domain, opts) do
      {:ok, branch}
    else
      false -> {:error, "not_found: no branch with that id"}
      other -> other
    end
  end

  defp in_scope?(%Branch{domain: domain, owner: owner}, domain, opts) do
    case Keyword.fetch(opts, :owner) do
      {:ok, wanted} -> owner == wanted
      :error -> true
    end
  end

  defp in_scope?(_branch, _domain, _opts), do: false

  defp owner_filter(opts) do
    case Keyword.fetch(opts, :owner) do
      {:ok, owner} -> [owner: owner]
      :error -> []
    end
  end

  # Spelled out: `String.to_existing_atom/1` at compile time depends on another module having been compiled first in
  # the same VM, so it failed on an incremental `mix compile` (and could on a parallel one).
  @statuses %{
    "open" => :open,
    "proposed" => :proposed,
    "merged" => :merged,
    "rejected" => :rejected,
    "discarded" => :discarded
  }

  defp status_filter(args) do
    case args["status"] do
      nil -> {:ok, []}
      status when is_map_key(@statuses, status) -> {:ok, [status: Map.fetch!(@statuses, status)]}
      _ -> {:error, "status must be one of #{@statuses |> Map.keys() |> Enum.join(", ")}"}
    end
  end

  defp required_string(args, key) do
    case args[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      nil -> {:error, "#{key} is required"}
      _ -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp optional_string(args, key) do
    case args[key] do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp message(message) when is_binary(message), do: message
  defp message(%Error{reason: reason, message: message}), do: "#{reason}: #{message}"

  defp summary(%Branch{} = branch) do
    %{
      "id" => branch.id,
      "name" => branch.name,
      "status" => Atom.to_string(branch.status),
      "changed_rows" => map_size(branch.overlay)
    }
  end

  # Values go to a model provider, so `sensitive?` attributes are redacted as the inspector does (ADR 0016).
  defp change(%Change{} = change) do
    change = Change.redact(change)

    %{
      "resource" => inspect(change.resource),
      "key" => json(change.key),
      "kind" => Atom.to_string(change.kind),
      "changes" =>
        Map.new(change.changes, fn {attribute, {before, after_value}} ->
          {Atom.to_string(attribute), %{"before" => json(before), "after" => json(after_value)}}
        end)
    }
  end

  # A diff holds Ash values: dates, decimals, atoms, structs. The model reads text, so anything JSON cannot say natively
  # becomes its string form.
  defp json(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)

  defp json(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: inspect(value))

  defp json(%_{} = value),
    do: if(String.Chars.impl_for(value), do: to_string(value), else: inspect(value))

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value) when is_map(value), do: Map.new(value, fn {k, v} -> {json_key(k), json(v)} end)
  defp json(value), do: inspect(value)

  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key)
end
