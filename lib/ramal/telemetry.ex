defmodule Ramal.Telemetry do
  @moduledoc """
  The telemetry events Ramal emits, in one place.

  Every branch event carries `%{branch_id: id, domain: module}` in its metadata, plus whatever the event adds.
  The library never logs above `:debug`; observability goes through these events.

  | event | when |
  |---|---|
  | `[:ramal, :branch, :create]` | a branch was created |
  | `[:ramal, :branch, :fork]` | a branch was forked from another (extra metadata: `parent_id`, and `nested: true` for a fork that merges into its parent) |
  | `[:ramal, :branch, :load]` | a branch process started from storage, or right after creation |
  | `[:ramal, :branch, :unload]` | a branch process stopped after persisting (`reason`: `:idle` or `:shutdown`) |
  | `[:ramal, :branch, :persist_failed]` | storage refused the write of a branch (`reason`: `:idle`, `:shutdown` or `:merged`, `error`): an idle branch stays loaded and tries again; so does a merge whose commit succeeded but whose `:merged` status could not be stored (`Ramal.Merge.Result` `persist_failed`); on a shutdown its last persisted state is what remains |
  | `[:ramal, :branch, :adopt]` | a branch took the work of a nested fork that merged into it (extra metadata: `child_id`; ADR 0043) |
  | `[:ramal, :branch, :discard]` | a branch was discarded |
  | `[:ramal, :branch, :propose]` | a branch was proposed for a decision |
  | `[:ramal, :branch, :approve]` | a proposed branch was approved and merged (after the `[:ramal, :merge]` span) |
  | `[:ramal, :branch, :reject]` | a proposed branch was rejected |
  | `[:ramal, :branch, :too_large]` | a branch process was killed for exceeding `max_heap_size` |
  | `[:ramal, :limit, :reached]` | `branch/2` or `fork/2` was refused by a limit of `Ramal.Supervisor` (metadata: `domain`, `operation`, `limit`) |
  | `[:ramal, :merge, :start \| :stop \| :exception]` | a span around `Ramal.merge/2`; `stop` adds `result` (`:ok` or `:error`) and `replayed`, or `reason` |
  | `[:ramal, :read, :patch]` | a read inside a branch was patched with the overlay (measurements: `base_rows`, `overlay_rows`, `result_rows`, `duration`) |
  | `[:ramal, :read, :unpatched_aggregate]` | a read inside a branch selected an aggregate Ramal cannot compute over the overlay (`custom`, a join filter, a custom read action, ...), so it has the database's value |
  | `[:ramal, :write, :capture]` | a create, update or destroy inside a branch was put in the overlay instead of the data layer (metadata: `action_type`, `resource`, `action`, `nested?`) |

  ## Example

      iex> :telemetry.attach("doc-example", [:ramal, :branch, :create], fn _, _, meta, pid -> send(pid, meta) end, self())
      iex> Ramal.Telemetry.branch(:create, %{id: "b1", domain: MyApp.Farm})
      iex> receive do: (%{branch_id: id} -> id)
      "b1"
      iex> :telemetry.detach("doc-example")
  """

  @doc """
  The branch lifecycle event names, for attaching handlers.

  ## Example

      iex> [:ramal, :branch, :create] in Ramal.Telemetry.branch_events()
      true
  """
  @spec branch_events() :: [[atom]]
  def branch_events do
    for step <- [
          :create,
          :fork,
          :adopt,
          :load,
          :unload,
          :persist_failed,
          :discard,
          :too_large,
          :propose,
          :approve,
          :reject
        ],
        do: [:ramal, :branch, step]
  end

  @doc """
  Emits a read event (`:patch` or `:unpatched_aggregate`) with the given measurements and metadata.

  ## Example

      iex> Ramal.Telemetry.read(:patch, %{base_rows: 3}, %{branch_id: "b1", resource: MyApp.Herd})
      :ok
  """
  @spec read(atom, map, map) :: :ok
  def read(step, measurements, metadata) do
    :telemetry.execute([:ramal, :read, step], measurements, metadata)
  end

  @doc """
  Emits a branch lifecycle event for `branch` (anything with `:id` and `:domain`), merging `extra` into the metadata.

  ## Example

      iex> Ramal.Telemetry.branch(:discard, %{id: "b1", domain: MyApp.Farm}, %{reason: :requested})
      :ok
  """
  @spec branch(atom, %{id: String.t(), domain: module}, map) :: :ok
  def branch(step, %{id: id, domain: domain}, extra \\ %{}) do
    :telemetry.execute(
      [:ramal, :branch, step],
      %{system_time: System.system_time()},
      Map.merge(%{branch_id: id, domain: domain}, extra)
    )
  end

  @doc """
  Emits `[:ramal, :limit, :reached]` with `metadata` (`domain`, `operation`, `limit`).

  ## Example

      iex> Ramal.Telemetry.limit(:reached, %{domain: MyApp.Farm, operation: :fork, limit: :branch_rate})
      :ok
  """
  @spec limit(atom, map) :: :ok
  def limit(step, metadata) do
    :telemetry.execute([:ramal, :limit, step], %{system_time: System.system_time()}, metadata)
  end

  @doc """
  Emits `[:ramal, :write, :capture]` for a write captured by `branch`, merging `extra` into the metadata.

  ## Example

      iex> Ramal.Telemetry.write(:capture, %{id: "b1", domain: MyApp.Farm}, %{action_type: :update})
      :ok
  """
  @spec write(atom, %{id: String.t(), domain: module}, map) :: :ok
  def write(step, %{id: id, domain: domain}, extra \\ %{}) do
    :telemetry.execute(
      [:ramal, :write, step],
      %{system_time: System.system_time()},
      Map.merge(%{branch_id: id, domain: domain}, extra)
    )
  end
end
