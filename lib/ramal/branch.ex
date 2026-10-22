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
end
