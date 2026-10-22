defmodule Ramal.Branch do
  @moduledoc """
  A branch: the struct a branch process holds and storage persists, plus the pure functions over it.

  * `id` - a UUID string
  * `name` - free text for people
  * `domain` - the Ash domain whose resources the branch covers
  * `status` - `:open`, `:merged` or `:discarded`
  * `base` - what the branch knows about the base rows it touched (fingerprints and snapshots)
  * `overlay` - see `Ramal.Overlay`
  * `log` - the writes the branch captured, newest first so that recording one is O(1); readers use `Enum.reverse/1`
  * `inserted_at` - when the branch was created
  * `metadata` - a map the host uses freely; Ramal only adds `forked_from` to a fork

  Nothing here touches a process or storage, so it is tested with plain data.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm, name: "move herd R7", metadata: %{ticket: 42})
      iex> {branch.name, branch.status, branch.overlay, branch.metadata}
      {"move herd R7", :open, %{}, %{ticket: 42}}
      iex> Ramal.Branch.open?(branch)
      true
  """

  alias Ramal.Overlay

  @type status :: :open | :merged | :discarded
  @type kind :: :created | :updated | :deleted
  @type ref :: Overlay.ref()

  @typedoc """
  A captured write: `{action_type, resource, action_name, input, actor, opts, at}`. `input` is the params the action
  was called with, `opts` carries `:key` (the primary key written), `:tenant` and `:nested?` (the write was made by
  a hook of another captured action, so replaying that action reproduces it).
  """
  @type log_entry ::
          {Ash.Resource.Actions.action_type(), module, atom, map, term, keyword, DateTime.t()}

  @typedoc "What `put_write/6` replaced, so `undo/2` can put it back."
  @type undo :: %{ref: ref, overlay: Overlay.entry() | :none, base: map | :none, entry: log_entry}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          domain: module,
          status: status,
          base: map,
          overlay: Overlay.t(),
          log: list,
          inserted_at: DateTime.t(),
          metadata: map
        }

  @enforce_keys [:id, :domain, :inserted_at]
  defstruct [
    :id,
    :name,
    :domain,
    :inserted_at,
    status: :open,
    base: %{},
    overlay: %{},
    log: [],
    metadata: %{}
  ]

  @doc """
  A new open branch for `domain` with a fresh id.

  ## Options

    * `:name` - a label for people, default `nil`
    * `:metadata` - a map for the host, default `%{}`

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> {branch.domain, branch.name, branch.log}
      {MyApp.Farm, nil, []}
  """
  @spec new(module, keyword) :: t
  def new(domain, opts \\ []) when is_atom(domain) do
    %__MODULE__{
      id: Ash.UUID.generate(),
      name: opts[:name],
      domain: domain,
      inserted_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Whether the branch still accepts reads, writes and merges.

  ## Example

      iex> Ramal.Branch.open?(%Ramal.Branch{id: "b", domain: MyApp.Farm, inserted_at: DateTime.utc_now(), status: :merged})
      false
  """
  @spec open?(t) :: boolean
  def open?(%__MODULE__{status: status}), do: status == :open

  @doc """
  The branch after `discard`: status `:discarded` and no overlay, log or base, so a discarded branch costs nothing to keep.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> branch = %{branch | overlay: %{{MyApp.Herd, 1} => :deleted}}
      iex> discarded = Ramal.Branch.discard(branch)
      iex> {discarded.status, discarded.overlay}
      {:discarded, %{}}
  """
  @spec discard(t) :: t
  def discard(%__MODULE__{} = branch) do
    %{branch | status: :discarded, overlay: %{}, log: [], base: %{}}
  end

  @doc """
  The branch after one captured write.

  `kind` says what the write did to the row `ref`, `record` is the row as the action left it, and `snapshot` is the
  row as the action found it. The snapshot is kept in `base` the first time the branch touches an existing row, so
  `Ramal.Overlay.diff/3` never needs the database. `entry` is prepended to the log.

  Returns the new branch and an `undo` that `undo/2` uses to take the write back when the action that made it fails.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> entry = {:update, MyApp.Herd, :update, %{name: "b"}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {branch, _undo} = Ramal.Branch.put_write(branch, :updated, {MyApp.Herd, 1}, %{id: 1, name: "b"}, %{id: 1, name: "a"}, entry)
      iex> {branch.overlay, branch.base, length(branch.log)}
      {%{{MyApp.Herd, 1} => {:updated, %{id: 1, name: "b"}}}, %{{MyApp.Herd, 1} => %{id: 1, name: "a"}}, 1}
  """
  @spec put_write(t, kind, ref, map, map | nil, log_entry) :: {t, undo}
  def put_write(%__MODULE__{} = branch, kind, ref, record, snapshot, entry) do
    undo = %{
      ref: ref,
      overlay: Map.get(branch.overlay, ref, :none),
      base: Map.get(branch.base, ref, :none),
      entry: entry
    }

    overlay =
      case kind do
        :created -> Overlay.put_created(branch.overlay, ref, record)
        :updated -> Overlay.put_updated(branch.overlay, ref, record)
        :deleted -> Overlay.put_deleted(branch.overlay, ref)
      end

    # An overlay entry means the branch already holds the row's snapshot, or created the row itself.
    base =
      if kind != :created and snapshot != nil and not Map.has_key?(branch.overlay, ref) do
        Map.put_new(branch.base, ref, snapshot)
      else
        branch.base
      end

    {%{branch | overlay: overlay, base: base, log: [entry | branch.log]}, undo}
  end

  @doc """
  The branch with the writes described by `undos` taken back, newest write first.

  Only the refs and log entries the undos name are touched, so a write another process made in the meantime stays.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> entry = {:destroy, MyApp.Herd, :destroy, %{}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {written, undo} = Ramal.Branch.put_write(branch, :deleted, {MyApp.Herd, 1}, %{id: 1}, %{id: 1}, entry)
      iex> Ramal.Branch.undo(written, [undo]) == branch
      true
  """
  @spec undo(t, [undo]) :: t
  def undo(%__MODULE__{} = branch, undos) do
    Enum.reduce(undos, branch, fn undo, acc ->
      %{
        acc
        | overlay: restore(acc.overlay, undo.ref, undo.overlay),
          base: restore(acc.base, undo.ref, undo.base),
          log: List.delete(acc.log, undo.entry)
      }
    end)
  end

  defp restore(map, ref, :none), do: Map.delete(map, ref)
  defp restore(map, ref, value), do: Map.put(map, ref, value)
end
