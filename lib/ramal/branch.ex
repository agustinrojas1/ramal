defmodule Ramal.Branch do
  @moduledoc """
  A branch: the struct a branch process holds and storage persists, plus the pure functions over it.

  * `id` - a UUID string
  * `name` - free text for people
  * `domain` - the Ash domain whose resources the branch covers
  * `status` - `:open`, `:proposed`, `:merged`, `:rejected` or `:discarded`
  * `base` - what the branch knows about the base rows it touched, by `{resource, key}`: `%{fingerprint: hash | nil,
    snapshot: record | nil}`. The fingerprint is taken when a row is first read or written, the snapshot when it is first
    written, so `diff/2` never queries the database
  * `overlay` - see `Ramal.Overlay`
  * `log` - the writes the branch captured, newest first so that recording one is O(1); readers use `Enum.reverse/1`
  * `inserted_at` - when the branch was created
  * `metadata` - a map the host uses freely; Ramal only adds `forked_from` to a fork
  * `owner` - who the host says the branch belongs to, `nil` unless given at `branch/2` or `fork/2`. Ramal never
    interprets it: `Ramal.list/2` can filter by it (ADR 0018) and nothing else reads it
  * `tenant` - the one tenant the branch works in, `nil` unless given at `branch/2` (ADR 0034). A fork keeps it
  * `proposal` - `nil` until `Ramal.propose/2`; then `t:proposal/0`
  * `epoch` - the fencing token of a branch held by a process of a cluster (ADR 0044): the storage's epoch for the branch
    when the process loaded it, `nil` otherwise. Storage never writes it into `state`, and a fork starts without one
  * `parent` - `nil`, or for a nested fork (`Ramal.fork(parent, nested: true)`, ADR 0043) `%{id: parent_id, log_length:
    n}`: the branch it merges into and how many of its own log entries the fork inherited
  * `parent_seen` - for a nested fork, `ref => view`: what the parent held for each row the fork read or wrote, the
    first time it did. `view/2` says what a view is. Merging into the parent compares them with the parent's now
  * `merged_children` - the ids of the nested forks that merged into this branch, so that one cannot merge twice
  * `next_placeholder` - how many placeholder keys the branch handed out for rows whose key the database generates
    (ADR 0042). A fork keeps the count, and its placeholders are its own
  * `durable` - whether the branch appends the writes of every action that ends to the storage's write log, so a crash
    loses none of them (ADR 0048). Set at `branch/2` and kept by a fork
  * `wal` - the sequence number of the last delta of the write log this struct includes. Storage deletes the deltas up
    to it when the branch is stored as a snapshot, and a load applies the ones after it. `0` for a branch that never
    appended

  Nothing here touches a process or storage, so it is tested with plain data.

  `inspect/1` prints `id`, `name`, `domain`, `status` and `inserted_at` only. The log keeps the raw input and the actor of
  every captured write, which can hold passwords and tokens, and a crash report prints the state of a branch process.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm, name: "move herd R7", metadata: %{ticket: 42})
      iex> {branch.name, branch.status, branch.overlay, branch.metadata}
      {"move herd R7", :open, %{}, %{ticket: 42}}
      iex> Ramal.Branch.open?(branch)
      true
  """

  alias Ramal.{Change, Overlay}

  @type status :: :open | :proposed | :merged | :rejected | :discarded

  @typedoc """
  A branch's proposal: who proposed it and why, and once decided, how. `proposer` and `by` are whatever the host passed
  (`:proposed_by`, `:decided_by`); `stale` and `replayed` are what the approving merge saw.
  """
  @type proposal :: %{
          proposer: term,
          reason: String.t() | nil,
          proposed_at: DateTime.t(),
          decision:
            nil
            | %{
                status: :approved | :rejected,
                by: term,
                reason: String.t() | nil,
                at: DateTime.t(),
                replayed: non_neg_integer | nil,
                stale: [Ramal.Merge.Result.stale_row()]
              }
        }
  @type kind :: :created | :updated | :deleted
  @type ref :: Overlay.ref()

  @typedoc """
  A captured write: `{action_type, resource, action_name, input, actor, opts, at}`. `input` is the params the action
  was called with, `opts` carries `:key` (the primary key written), `:tenant`, `:nested?` (the write was made by
  a hook of another captured action, so replaying that action reproduces it), `:upsert` (`{identity, fields, found?}`
  for a create that was an upsert, ADR 0037) and `:generated_key?` (the key is a placeholder for one the database
  generates, ADR 0042).
  """
  @type log_entry ::
          {Ash.Resource.Actions.action_type(), module, atom, map, term, keyword, DateTime.t()}

  @typedoc "What the branch knows about one base row."
  @type base_row :: %{fingerprint: non_neg_integer | nil, snapshot: map | nil}

  @typedoc """
  What a branch holds for a row: `:base` when it has no overlay entry (the row is the database's), otherwise the hash of
  the entry. Two views are the same row in the same state when they are equal.
  """
  @type view :: :base | non_neg_integer

  @typedoc "What `put_write/6` replaced, so `undo/2` can put it back."
  @type undo :: %{
          ref: ref,
          overlay: Overlay.entry() | :none,
          base: base_row | :none,
          seen: :added | :kept,
          entry: log_entry
        }

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          domain: module,
          status: status,
          base: map,
          overlay: Overlay.t(),
          log: list,
          inserted_at: DateTime.t(),
          metadata: map,
          owner: term,
          tenant: term,
          proposal: proposal | nil,
          epoch: non_neg_integer | nil,
          parent: %{id: String.t(), log_length: non_neg_integer} | nil,
          parent_seen: %{optional(ref) => view},
          merged_children: [String.t()],
          next_placeholder: non_neg_integer,
          durable: boolean,
          wal: non_neg_integer
        }

  @typedoc """
  What one action added to the branch (ADR 0048), as `delta/2` builds it and `apply_delta/2` applies it: the overlay
  entries and base rows of the rows the action wrote as they stand when it ends, the rows whose entry is gone (a created
  row the action then destroyed), the action's log entries, oldest first, `seen`, what a nested fork recorded of its
  parent for those rows (`parent_seen`, ADR 0043), and `next_placeholder`, the count of placeholder keys the branch had
  handed out (ADR 0042), so that a recovered branch does not hand out one again.
  """
  @type delta :: %{
          overlay: %{optional(ref) => Overlay.entry()},
          gone: [ref],
          base: %{optional(ref) => base_row},
          log: [log_entry],
          seen: %{optional(ref) => view},
          next_placeholder: non_neg_integer
        }

  # `inspect/1` shows the branch's identity and nothing it holds. The log keeps the raw input of every captured action
  # (a password argument, a token) and `Ash` only redacts sensitive attributes of records, so printing the whole struct
  # would put those values in a crash report, where a branch process's state is printed, and in any log line that
  # inspects a branch. Read `overlay`, `log` and `base` from the struct when you need them.
  @derive {Inspect, only: [:id, :name, :domain, :status, :inserted_at]}
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
    metadata: %{},
    owner: nil,
    tenant: nil,
    proposal: nil,
    epoch: nil,
    parent: nil,
    parent_seen: %{},
    merged_children: [],
    next_placeholder: 0,
    durable: false,
    wal: 0
  ]

  @doc """
  A new open branch for `domain` with a fresh id.

  ## Options

    * `:name` - a label for people, default `nil`
    * `:metadata` - a map for the host, default `%{}`
    * `:owner` - who the branch belongs to, any term, default `nil` (see `Ramal.list/2`)
    * `:tenant` - the tenant the branch works in, default `nil`: the branch then refuses multitenant resources used with
      a tenant (ADR 0034)
    * `:durable` - append every action's writes to the storage's write log when the action ends, default `false`
      (ADR 0048)

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm, owner: 7, tenant: "acme")
      iex> {branch.domain, branch.name, branch.log, branch.owner, branch.tenant}
      {MyApp.Farm, nil, [], 7, "acme"}
  """
  @spec new(module, keyword) :: t
  def new(domain, opts \\ []) when is_atom(domain) do
    %__MODULE__{
      id: Ash.UUID.generate(),
      name: opts[:name],
      domain: domain,
      inserted_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{}),
      owner: opts[:owner],
      tenant: opts[:tenant],
      durable: Keyword.get(opts, :durable, false)
    }
  end

  @placeholder_base -2_147_483_648

  @doc """
  A placeholder key for a row whose key the database generates, and the branch that has handed it out.

  An integer key gets `-2_147_483_648 + n` for the branch's `n`th placeholder: it fits `int4` and `int8`, so a filter on
  it reaches Postgres without overflowing, and a generated key is positive, so it cannot be mistaken for a real one.
  A UUID key gets a fresh UUID. Any other type has no placeholder (`:error`).

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> {:ok, key, branch} = Ramal.Branch.placeholder(branch, Ash.Type.Integer)
      iex> {key, branch.next_placeholder}
      {-2_147_483_647, 1}
      iex> Ramal.Branch.placeholder(branch, Ash.Type.String)
      :error
  """
  @spec placeholder(t, module) :: {:ok, term, t} | :error
  def placeholder(%__MODULE__{} = branch, Ash.Type.Integer) do
    n = branch.next_placeholder + 1
    {:ok, @placeholder_base + n, %{branch | next_placeholder: n}}
  end

  def placeholder(%__MODULE__{} = branch, type) when type in [Ash.Type.UUID, Ash.Type.UUIDv7] do
    n = branch.next_placeholder + 1
    {:ok, Ash.UUID.generate(), %{branch | next_placeholder: n}}
  end

  def placeholder(%__MODULE__{}, _type), do: :error

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
  The branch after `Ramal.propose/2`: status `:proposed`, frozen until someone decides, with the proposal recorded.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> proposed = Ramal.Branch.propose(branch, %{id: 7}, "move R7 before the rain", ~U[2026-01-01 00:00:00Z])
      iex> {proposed.status, proposed.proposal.proposer, proposed.proposal.reason, proposed.proposal.decision}
      {:proposed, %{id: 7}, "move R7 before the rain", nil}
  """
  @spec propose(t, term, String.t() | nil, DateTime.t()) :: t
  def propose(%__MODULE__{} = branch, proposer, reason, %DateTime{} = at) do
    %{
      branch
      | status: :proposed,
        proposal: %{proposer: proposer, reason: reason, proposed_at: at, decision: nil}
    }
  end

  @doc """
  The branch with the decision on its proposal recorded. `status` is `:approved` or `:rejected`; only a rejection
  changes the branch's own status (to `:rejected`), because an approval is followed by the merge that marks it `:merged`.
  `details` may carry `:by`, `:reason`, `:replayed` and `:stale`.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> branch = Ramal.Branch.propose(branch, nil, nil, ~U[2026-01-01 00:00:00Z])
      iex> rejected = Ramal.Branch.decide(branch, :rejected, ~U[2026-01-02 00:00:00Z], by: %{id: 1}, reason: "not now")
      iex> {rejected.status, rejected.proposal.decision.status, rejected.proposal.decision.reason}
      {:rejected, :rejected, "not now"}
  """
  @spec decide(t, :approved | :rejected, DateTime.t(), keyword) :: t
  def decide(%__MODULE__{proposal: proposal} = branch, status, %DateTime{} = at, details \\ [])
      when status in [:approved, :rejected] and is_map(proposal) do
    decision = %{
      status: status,
      by: details[:by],
      reason: details[:reason],
      at: at,
      replayed: details[:replayed],
      stale: Keyword.get(details, :stale, [])
    }

    branch = %{branch | proposal: %{proposal | decision: decision}}
    if status == :rejected, do: %{branch | status: :rejected}, else: branch
  end

  @doc """
  The branch after one captured write.

  `kind` says what the write did to the row `ref`, `record` is the row as the action left it, and `base_row` is the
  row as the action found it (`nil` for a created row). The first time the branch writes an existing row, its snapshot
  goes into `base`, keeping a fingerprint taken by an earlier read if there is one. `entry` is prepended to the log.

  Returns the new branch and an `undo` that `undo/2` uses to take the write back when the action that made it fails.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> entry = {:update, MyApp.Herd, :update, %{name: "b"}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> before = %{fingerprint: 7, snapshot: %{id: 1, name: "a"}}
      iex> {branch, _undo} = Ramal.Branch.put_write(branch, :updated, {MyApp.Herd, 1}, %{id: 1, name: "b"}, before, entry)
      iex> {branch.overlay, branch.base, length(branch.log)}
      {%{{MyApp.Herd, 1} => {:updated, %{id: 1, name: "b"}}}, %{{MyApp.Herd, 1} => %{fingerprint: 7, snapshot: %{id: 1, name: "a"}}}, 1}
  """
  @spec put_write(t, kind, ref, map, base_row | nil, log_entry) :: {t, undo}
  def put_write(%__MODULE__{} = branch, kind, ref, record, base_row, entry) do
    {record, base_row, entry} = share_terms(branch, ref, record, base_row, entry)

    # A nested fork's first touch of a row records what it held before the write, which is what its parent held when it
    # was forked (see `see/2`).
    {parent_seen, seen} = first_touch(branch, ref)

    undo = %{
      ref: ref,
      overlay: Map.get(branch.overlay, ref, :none),
      base: Map.get(branch.base, ref, :none),
      seen: seen,
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
      if kind != :created and base_row != nil and not Map.has_key?(branch.overlay, ref) do
        Map.update(branch.base, ref, base_row, fn read ->
          %{base_row | fingerprint: read.fingerprint || base_row.fingerprint}
        end)
      else
        branch.base
      end

    {%{
       branch
       | overlay: overlay,
         base: base,
         log: [entry | branch.log],
         parent_seen: parent_seen
     }, undo}
  end

  defp first_touch(%__MODULE__{parent: nil, parent_seen: seen}, _ref), do: {seen, :kept}

  defp first_touch(%__MODULE__{parent_seen: %{} = seen}, ref) when is_map_key(seen, ref),
    do: {seen, :kept}

  defp first_touch(%__MODULE__{parent_seen: seen} = branch, ref),
    do: {Map.put(seen, ref, view(branch, ref)), :added}

  # The record, the snapshot and the log entry reach the branch process as copies of terms the writer built, without the
  # sharing it had (`Ramal.Overlay.share/3`). Sharing them again is what keeps a row's cost at the values that are its
  # own: the fields of an update that did not change point at the snapshot, the ones the previous write of the resource
  # also holds point at that write, and the key is the one term of the ref.
  defp share_terms(branch, {resource, key}, record, base_row, entry) do
    {sibling, sibling_snapshot} = sibling(branch, resource)

    {record, base_row} =
      case {Map.get(branch.overlay, {resource, key}), base_row} do
        {{_kind, held}, _base_row} ->
          {Overlay.share(record, [held, sibling], key), base_row}

        {_none_or_deleted, %{snapshot: snapshot} = base_row} when is_map(snapshot) ->
          snapshot = Overlay.share(snapshot, [sibling_snapshot], key)
          {Overlay.share(record, [snapshot, sibling], key), %{base_row | snapshot: snapshot}}

        _created ->
          {Overlay.share(record, [sibling], key), base_row}
      end

    {record, base_row, share_entry(entry, List.first(branch.log), key)}
  end

  # The record and snapshot of the write before this one, when it was a write of the same resource: a loop over rows
  # writes siblings, which hold the same foreign keys, the same states and the same metadata.
  defp sibling(branch, resource) do
    case branch.log do
      [{_type, ^resource, _action, _input, _actor, opts, _at} | _] ->
        sibling_ref = {resource, opts[:key]}
        {held_record(branch.overlay, sibling_ref), held_snapshot(branch.base, sibling_ref)}

      _other_resource_or_empty ->
        {%{}, %{}}
    end
  end

  defp held_record(overlay, ref) do
    case overlay do
      %{^ref => {_kind, record}} -> record
      _none_or_deleted -> %{}
    end
  end

  defp held_snapshot(base, ref) do
    case base do
      %{^ref => %{snapshot: snapshot}} when is_map(snapshot) -> snapshot
      _none -> %{}
    end
  end

  # The actor of a run is the same term in every write the run makes, and a user record is the largest thing a log entry
  # holds, so a write whose actor equals the previous one's points at it. The key in the options and the time are shared
  # like the fields of a record.
  defp share_entry({type, resource, action, input, actor, opts, at}, previous, key) do
    actor =
      case previous do
        {_type, _resource, _action, _input, ^actor, _opts, _at} -> elem(previous, 4)
        _other -> actor
      end

    opts = for {name, value} <- opts, do: {name, if(value === key, do: key, else: value)}
    {type, resource, action, input, actor, opts, Overlay.share(at, [])}
  end

  @doc """
  The branch with its terms shared the way `put_write/6` shares them as the writes come in.

  A branch that comes out of storage is a copy that kept none of that sharing: an ETS table and a message copy every
  term in full, and a decoded branch builds each row from its own parts. The branch process runs this once when it
  starts, so a branch that was unloaded and loaded again costs the heap it cost before. The result is equal to `branch`.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> Ramal.Branch.share(branch) == branch
      true
  """
  @spec share(t) :: t
  def share(%__MODULE__{} = branch) do
    log = Enum.reverse(branch.log)

    {overlay, base, _siblings} =
      log
      |> Enum.map(fn {_type, resource, _action, _input, _actor, opts, _at} ->
        {resource, opts[:key]}
      end)
      |> Enum.uniq()
      |> Enum.reduce({branch.overlay, branch.base, %{}}, &share_row/2)

    %{branch | overlay: overlay, base: base, log: share_log(log, nil, [])}
  end

  defp share_row({resource, key} = ref, {overlay, base, siblings}) do
    {sibling, sibling_snapshot} = Map.get(siblings, resource, {%{}, %{}})

    snapshot =
      case base do
        %{^ref => %{snapshot: snapshot}} when is_map(snapshot) ->
          Overlay.share(snapshot, [sibling_snapshot], key)

        _none ->
          nil
      end

    record =
      case overlay do
        %{^ref => {_kind, record}} -> Overlay.share(record, [snapshot || %{}, sibling], key)
        _none_or_deleted -> nil
      end

    siblings = Map.put(siblings, resource, {record || sibling, snapshot || sibling_snapshot})
    {put_shared(overlay, ref, record), put_shared_snapshot(base, ref, snapshot), siblings}
  end

  defp put_shared(overlay, _ref, nil), do: overlay
  defp put_shared(overlay, ref, record), do: Map.update!(overlay, ref, &put_elem(&1, 1, record))

  defp put_shared_snapshot(base, _ref, nil), do: base

  defp put_shared_snapshot(base, ref, snapshot),
    do: Map.update!(base, ref, &%{&1 | snapshot: snapshot})

  # Oldest first, so that an entry points at the term of the one before it and the list comes out newest first.
  defp share_log([], _previous, shared), do: shared

  defp share_log([{type, resource, action, input, actor, opts, at} | rest], previous, shared) do
    {_name, key} = List.keyfind(opts, :key, 0, {:key, nil})
    entry = share_entry({type, resource, action, input, actor, opts, at}, previous, key)
    share_log(rest, entry, [entry | shared])
  end

  @doc """
  The branch after reading base rows with these fingerprints.

  A row the branch already knows keeps its first fingerprint: staleness is measured from the first touch.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> branch = Ramal.Branch.put_fingerprints(branch, %{{MyApp.Herd, 1} => 7})
      iex> branch = Ramal.Branch.put_fingerprints(branch, %{{MyApp.Herd, 1} => 8})
      iex> branch.base
      %{{MyApp.Herd, 1} => %{fingerprint: 7, snapshot: nil}}
  """
  @spec put_fingerprints(t, %{optional(ref) => non_neg_integer} | [{ref, non_neg_integer}]) :: t
  def put_fingerprints(%__MODULE__{} = branch, fingerprints) do
    base =
      Enum.reduce(fingerprints, branch.base, fn {ref, fingerprint}, base ->
        if is_map_key(base, ref),
          do: base,
          else: Map.put(base, ref, %{fingerprint: fingerprint, snapshot: nil})
      end)

    %{branch | base: base}
  end

  @doc """
  A new open branch that starts as a copy of `parent`: same domain, tenant, overlay, log and base. It has no write log of
  its own yet (`wal` is `0`): the storage holds the fork as a snapshot of everything it copied.

  Overlays, logs and the base are immutable, so the copy shares structure with the parent and neither sees the
  other's later changes. `metadata` gets `forked_from: parent.id`.

  A plain fork is a sibling: it merges into the database. With `nested: true` it records `parent` and merges into
  `parent` instead (ADR 0043); either way it forgets the parent's own `parent`, `parent_seen` and `merged_children`.

  ## Options

    * `:name` - default: the parent's name
    * `:metadata` - default: the parent's metadata
    * `:owner` - default: the parent's owner
    * `:durable` - default: the parent's
    * `:nested` - default `false`

  ## Example

      iex> parent = Ramal.Branch.new(MyApp.Farm, name: "what if")
      iex> parent = %{parent | overlay: %{{MyApp.Herd, 1} => :deleted}}
      iex> fork = Ramal.Branch.fork(parent, name: "variant")
      iex> {fork.name, fork.overlay == parent.overlay, fork.metadata.forked_from == parent.id, fork.id != parent.id}
      {"variant", true, true, true}
      iex> Ramal.Branch.fork(parent, nested: true).parent == %{id: parent.id, log_length: 0}
      true
  """
  @spec fork(t, keyword) :: t
  def fork(%__MODULE__{} = parent, opts \\ []) do
    metadata =
      opts |> Keyword.get(:metadata, parent.metadata) |> Map.put(:forked_from, parent.id)

    link = if opts[:nested], do: %{id: parent.id, log_length: length(parent.log)}

    %{
      parent
      | id: Ash.UUID.generate(),
        name: Keyword.get(opts, :name, parent.name),
        inserted_at: DateTime.utc_now(),
        metadata: metadata,
        owner: Keyword.get(opts, :owner, parent.owner),
        durable: Keyword.get(opts, :durable, parent.durable),
        wal: 0,
        epoch: nil,
        parent: link,
        parent_seen: %{},
        merged_children: []
    }
  end

  @doc """
  What the branch holds for `ref`: `:base` without an overlay entry, otherwise the hash of the entry.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> Ramal.Branch.view(branch, {MyApp.Herd, 1})
      :base
      iex> branch = %{branch | overlay: %{{MyApp.Herd, 1} => :deleted}}
      iex> Ramal.Branch.view(branch, {MyApp.Herd, 1}) == :erlang.phash2(:deleted)
      true
  """
  @spec view(t, ref) :: view
  def view(%__MODULE__{overlay: overlay}, ref) do
    case overlay do
      %{^ref => entry} -> :erlang.phash2(entry)
      _none -> :base
    end
  end

  @doc """
  The branch after its reads returned the rows `refs`: a nested fork records, for each one it has not recorded yet, what
  it holds for it, which is what its parent held when it was forked, since only the fork's own writes change an entry.
  Any other branch is returned as it is.

  ## Example

      iex> parent = Ramal.Branch.new(MyApp.Farm)
      iex> child = Ramal.Branch.fork(parent, nested: true)
      iex> Ramal.Branch.see(child, [{MyApp.Herd, 1}]).parent_seen
      %{{MyApp.Herd, 1} => :base}
      iex> Ramal.Branch.see(parent, [{MyApp.Herd, 1}]).parent_seen
      %{}
  """
  @spec see(t, Enumerable.t()) :: t
  def see(%__MODULE__{parent: nil} = branch, _refs), do: branch

  def see(%__MODULE__{} = branch, refs) do
    seen =
      Enum.reduce(refs, branch.parent_seen, fn ref, seen ->
        if is_map_key(seen, ref), do: seen, else: Map.put(seen, ref, view(branch, ref))
      end)

    %{branch | parent_seen: seen}
  end

  @doc """
  The rows a nested fork saw in its parent that the parent holds differently now, as `%{resource, key, reason}` sorted by
  resource and key. `reason` is `:deleted` when the parent now holds the row as deleted and `:changed` otherwise.

  ## Example

      iex> parent = Ramal.Branch.new(MyApp.Farm)
      iex> child = Ramal.Branch.see(Ramal.Branch.fork(parent, nested: true), [{MyApp.Herd, 1}, {MyApp.Herd, 2}])
      iex> parent = %{parent | overlay: %{{MyApp.Herd, 1} => :deleted}}
      iex> Ramal.Branch.stale_against(child, parent)
      [%{resource: MyApp.Herd, key: 1, reason: :deleted}]
  """
  @spec stale_against(t, t) :: [%{resource: module, key: term, reason: :changed | :deleted}]
  def stale_against(%__MODULE__{parent_seen: seen, log: log}, %__MODULE__{} = parent) do
    # A row the fork created under a placeholder key (ADR 0042) is the fork's own: the parent may hand out the same
    # placeholder to another row, and the replay in the copy gives the fork's row a placeholder of the parent's.
    placeholders =
      for {:create, resource, _action, _params, _actor, opts, _at} <- log,
          opts[:generated_key?],
          into: MapSet.new(),
          do: {resource, opts[:key]}

    for {{resource, key} = ref, expected} <- seen,
        not MapSet.member?(placeholders, ref),
        view(parent, ref) != expected do
      reason = if Map.get(parent.overlay, ref) == :deleted, do: :deleted, else: :changed
      %{resource: resource, key: key, reason: reason}
    end
    |> Enum.sort_by(&{inspect(&1.resource), &1.key})
  end

  @doc """
  The log entries a nested fork wrote itself, oldest first, each with its index in the fork's log: the entries it
  inherited from its parent come first in the log and are left out.

  ## Example

      iex> parent = Ramal.Branch.new(MyApp.Farm)
      iex> child = Ramal.Branch.fork(parent, nested: true)
      iex> entry = {:create, MyApp.Herd, :create, %{}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {child, _} = Ramal.Branch.put_write(child, :created, {MyApp.Herd, 1}, %{id: 1}, nil, entry)
      iex> Ramal.Branch.own_entries(child)
      [{entry, 0}]
  """
  @spec own_entries(t) :: [{log_entry, non_neg_integer}]
  def own_entries(%__MODULE__{log: log, parent: %{log_length: inherited}}) do
    log |> Enum.reverse() |> Enum.with_index() |> Enum.drop(inherited)
  end

  @doc """
  A copy of `branch` with a new id, for the replay of a nested merge (ADR 0043): the writes go there, and the parent
  takes them with `adopt/3` only if the replay succeeded and the parent did not change meanwhile.

  The copy is not durable, even when `branch` is: nothing of it is stored, and the parent stores what it adopts as a
  snapshot (ADR 0048).

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> scratch = Ramal.Branch.scratch(branch)
      iex> {scratch.id != branch.id, scratch.overlay == branch.overlay}
      {true, true}
  """
  @spec scratch(t) :: t
  def scratch(%__MODULE__{} = branch), do: %{branch | id: Ash.UUID.generate(), durable: false}

  @doc """
  `parent` after it adopted the work of `child` that was replayed in `scratch` (a `scratch/1` of `parent`): the scratch's
  overlay, log and `parent_seen`, `child` among its `merged_children`, and a `base` that keeps the earliest fingerprint of
  each row, which is the child's when the parent had not seen the row, since the replay fingerprinted it later. The
  rows the child read join the parent's `parent_seen` where the parent has none, so that a parent that is itself nested
  keeps their protection.

  ## Example

      iex> parent = Ramal.Branch.new(MyApp.Farm)
      iex> child = Ramal.Branch.fork(parent, nested: true)
      iex> adopted = Ramal.Branch.adopt(parent, Ramal.Branch.scratch(parent), child)
      iex> adopted.merged_children == [child.id]
      true
  """
  @spec adopt(t, t, t) :: t
  def adopt(%__MODULE__{} = parent, %__MODULE__{} = scratch, %__MODULE__{} = child) do
    base =
      Enum.reduce(child.base, scratch.base, fn {ref, row}, base ->
        if is_map_key(parent.base, ref) do
          base
        else
          held = Map.get(base, ref, %{fingerprint: nil, snapshot: nil})

          Map.put(base, ref, %{
            fingerprint: row.fingerprint || held.fingerprint,
            snapshot: row.snapshot || held.snapshot
          })
        end
      end)

    seen = if parent.parent, do: Map.merge(child.parent_seen, scratch.parent_seen), else: %{}

    %{
      parent
      | overlay: scratch.overlay,
        log: scratch.log,
        base: base,
        parent_seen: seen,
        next_placeholder: scratch.next_placeholder,
        merged_children: [child.id | parent.merged_children]
    }
  end

  @doc """
  The branch's changes as `Ramal.Change` structs, in the order the log first touched each row.

  Never reads the database: updated and deleted rows are compared with the snapshot in `base`. See
  `Ramal.Overlay.diff/3` for the rules; the options are the same.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> entry = fn key -> {:create, MyApp.Herd, :create, %{}, nil, [key: key], ~U[2026-01-01 00:00:00Z]} end
      iex> {branch, _} = Ramal.Branch.put_write(branch, :created, {MyApp.Herd, 2}, %{id: 2}, nil, entry.(2))
      iex> {branch, _} = Ramal.Branch.put_write(branch, :created, {MyApp.Herd, 1}, %{id: 1}, nil, entry.(1))
      iex> {:ok, changes} = Ramal.Branch.diff(branch)
      iex> Enum.map(changes, & &1.key)
      [2, 1]
  """
  @spec diff(t, keyword) :: {:ok, [Change.t()]} | {:error, Ramal.Error.t()}
  def diff(%__MODULE__{} = branch, opts \\ []) do
    snapshots =
      for {ref, %{snapshot: snapshot}} <- branch.base,
          snapshot != nil,
          into: %{},
          do: {ref, snapshot}

    with {:ok, changes} <- Overlay.diff(branch.overlay, snapshots, opts) do
      {:ok, in_log_order(changes, branch.log)}
    end
  end

  @doc """
  What merging the nested fork `child` into `parent` would change in it: the changes of the rows the fork wrote itself,
  compared with what `parent` holds for them now, not with the database. Rows the parent changed and the fork did not
  touch are left out, and so are the changes the fork inherited.

  Never reads the database; see `diff/2` for the options and the errors.

  ## Example

      iex> parent = Ramal.Branch.new(MyApp.Farm)
      iex> child = Ramal.Branch.fork(parent, nested: true)
      iex> entry = {:create, MyApp.Herd, :create, %{}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {child, _} = Ramal.Branch.put_write(child, :created, {MyApp.Herd, 1}, %{id: 1}, nil, entry)
      iex> {:ok, [change]} = Ramal.Branch.diff_against(child, parent)
      iex> {change.kind, change.key}
      {:created, 1}
  """
  @spec diff_against(t, t, keyword) :: {:ok, [Change.t()]} | {:error, Ramal.Error.t()}
  def diff_against(%__MODULE__{} = child, %__MODULE__{} = parent, opts \\ []) do
    refs =
      child
      |> own_entries()
      |> Enum.map(fn {{_type, resource, _action, _input, _actor, entry_opts, _at}, _index} ->
        {resource, entry_opts[:key]}
      end)
      |> Enum.uniq()

    {overlay, snapshots} =
      Enum.reduce(refs, {%{}, %{}}, fn ref, {overlay, snapshots} ->
        case relative(Map.get(child.overlay, ref), Map.get(parent.overlay, ref)) do
          nil ->
            {overlay, snapshots}

          {entry, held} ->
            {Map.put(overlay, ref, entry),
             put_snapshot(snapshots, ref, held || base_snapshot(parent, child, ref))}
        end
      end)

    with {:ok, changes} <- Overlay.diff(overlay, snapshots, opts) do
      {:ok, in_log_order(changes, child.log)}
    end
  end

  # The fork's entry for a row as a change to what the parent holds: the fork's own entry when the parent holds the row
  # as the database has it, an update or a delete of the parent's copy when the parent changed it, and a create when the
  # parent deleted it. The second element is the parent's copy, the "before" of the change, when there is one.
  defp relative(nil, nil), do: nil
  defp relative(entry, nil), do: {entry, nil}
  defp relative({_kind, record}, {_parent_kind, held}), do: {{:updated, record}, held}
  defp relative(_deleted_or_dropped, {_parent_kind, held}), do: {:deleted, held}
  defp relative({_kind, record}, :deleted), do: {{:created, record}, nil}
  defp relative(_deleted_or_dropped, :deleted), do: nil

  defp base_snapshot(parent, child, ref) do
    Enum.find_value([parent, child], fn branch ->
      case branch.base do
        %{^ref => %{snapshot: snapshot}} -> snapshot
        _none -> nil
      end
    end)
  end

  defp put_snapshot(snapshots, _ref, nil), do: snapshots
  defp put_snapshot(snapshots, ref, snapshot), do: Map.put(snapshots, ref, snapshot)

  # The first entry of the oldest write to each row decides its position; rows the log does not mention go last.
  defp in_log_order(changes, log) do
    order =
      log
      |> Enum.reverse()
      |> Enum.map(fn {_type, resource, _action, _input, _actor, opts, _at} ->
        {resource, opts[:key]}
      end)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new()

    Enum.sort_by(changes, &Map.get(order, {&1.resource, &1.key}, map_size(order)))
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
          parent_seen: unsee(acc.parent_seen, undo),
          log: List.delete(acc.log, undo.entry)
      }
    end)
  end

  @typedoc """
  What `savepoint/1` kept of a branch so that `rollback/2` can put it back: the maps themselves (immutable, so keeping
  them costs nothing until the branch moves on), the length of the log and the placeholder counter, and the `wal` of a
  durable branch.
  """
  @type savepoint :: %{
          overlay: Overlay.t(),
          base: map,
          parent_seen: map,
          log_length: non_neg_integer,
          next_placeholder: non_neg_integer,
          wal: non_neg_integer
        }

  @doc """
  What `rollback/2` needs to take the branch back to how it is now.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> Ramal.Branch.savepoint(branch).log_length
      0
  """
  @spec savepoint(t) :: savepoint
  def savepoint(%__MODULE__{} = branch) do
    %{
      overlay: branch.overlay,
      base: branch.base,
      parent_seen: branch.parent_seen,
      log_length: length(branch.log),
      next_placeholder: branch.next_placeholder,
      wal: branch.wal
    }
  end

  @doc """
  The branch with every write made since `savepoint` taken back: the log is cut back to its length then, and the
  overlay entries, base rows and `parent_seen` of the rows those writes touched are put back as they were (or removed,
  if the branch held nothing for the row). The placeholder counter goes back too, so the next generated key is the
  one the rolled-back write got.

  Unlike `undo/2` this takes back writes whose actions have ended, and it takes back every write of the log since,
  whoever made it. Rows only read since stay as they are: their fingerprints say what the base held when they were
  read, which the rolled-back work does not change.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> savepoint = Ramal.Branch.savepoint(branch)
      iex> entry = {:create, MyApp.Herd, :create, %{}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {written, _undo} = Ramal.Branch.put_write(branch, :created, {MyApp.Herd, 1}, %{id: 1}, nil, entry)
      iex> Ramal.Branch.rollback(written, savepoint) == branch
      true
  """
  @spec rollback(t, savepoint) :: t
  def rollback(%__MODULE__{} = branch, savepoint) do
    {dropped, log} = Enum.split(branch.log, max(length(branch.log) - savepoint.log_length, 0))

    # Every log entry is one `put_write/6`, and its ref is the resource and the `:key` the entry records.
    refs =
      dropped
      |> Enum.map(fn {_type, resource, _action, _input, _actor, opts, _at} ->
        {resource, opts[:key]}
      end)
      |> Enum.uniq()

    %{
      branch
      | overlay: restore_from(branch.overlay, savepoint.overlay, refs),
        base: restore_from(branch.base, savepoint.base, refs),
        parent_seen: restore_from(branch.parent_seen, savepoint.parent_seen, refs),
        log: log,
        next_placeholder: savepoint.next_placeholder
    }
  end

  defp restore_from(map, saved, refs) do
    Enum.reduce(refs, map, fn ref, acc ->
      case Map.fetch(saved, ref) do
        {:ok, value} -> Map.put(acc, ref, value)
        :error -> Map.delete(acc, ref)
      end
    end)
  end

  defp unsee(seen, %{ref: ref, seen: :added}), do: Map.delete(seen, ref)
  defp unsee(seen, _undo), do: seen

  defp restore(map, ref, :none), do: Map.delete(map, ref)
  defp restore(map, ref, value), do: Map.put(map, ref, value)

  @doc """
  What the writes described by `undos` (newest first, as the process holds them) added to the branch: the delta a
  durable branch appends to the storage's write log when their action ends (ADR 0048).

  The delta holds the overlay entry and base row each written row has now, not the writes one by one, so it is as small
  as the rows the action touched. That is the action's own rows only: no running action writes a row another running
  action wrote (`:row_busy`), so nothing in it belongs to an action that has not ended.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> entry = {:create, MyApp.Herd, :create, %{}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {branch, undo} = Ramal.Branch.put_write(branch, :created, {MyApp.Herd, 1}, %{id: 1}, nil, entry)
      iex> delta = Ramal.Branch.delta(branch, [undo])
      iex> {delta.overlay, delta.gone, delta.base, delta.log == [entry], delta.next_placeholder}
      {%{{MyApp.Herd, 1} => {:created, %{id: 1}}}, [], %{}, true, 0}
  """
  @spec delta(t, [undo]) :: delta
  def delta(%__MODULE__{} = branch, undos) do
    refs = undos |> Enum.map(& &1.ref) |> Enum.uniq()

    %{
      overlay: Map.take(branch.overlay, refs),
      gone: Enum.reject(refs, &is_map_key(branch.overlay, &1)),
      base: Map.take(branch.base, refs),
      log: undos |> Enum.map(& &1.entry) |> Enum.reverse(),
      seen: Map.take(branch.parent_seen, refs),
      next_placeholder: branch.next_placeholder
    }
  end

  @doc """
  The branch with `delta` applied, as the write log of storage is read back: the entries of its rows replace the
  branch's, its log entries go on the log, and `wal` becomes `seq`. Deltas are applied in `seq` order, which is the order
  their actions ended in.

  ## Example

      iex> branch = Ramal.Branch.new(MyApp.Farm)
      iex> entry = {:create, MyApp.Herd, :create, %{}, nil, [key: 1], ~U[2026-01-01 00:00:00Z]}
      iex> {written, undo} = Ramal.Branch.put_write(branch, :created, {MyApp.Herd, 1}, %{id: 1}, nil, entry)
      iex> delta = Ramal.Branch.delta(written, [undo])
      iex> Ramal.Branch.apply_delta(branch, 1, delta) == %{written | wal: 1}
      true
  """
  @spec apply_delta(t, pos_integer, delta) :: t
  def apply_delta(%__MODULE__{} = branch, seq, delta) do
    %{
      branch
      | overlay: branch.overlay |> Map.drop(delta.gone) |> Map.merge(delta.overlay),
        base: Map.merge(branch.base, delta.base),
        log: Enum.reduce(delta.log, branch.log, &[&1 | &2]),
        parent_seen: Map.merge(branch.parent_seen, delta.seen),
        next_placeholder: max(branch.next_placeholder, delta.next_placeholder),
        wal: seq
    }
  end
end
