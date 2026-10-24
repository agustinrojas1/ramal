defmodule Ramal do
  @moduledoc """
  Data branches as BEAM processes.

  A branch is a process holding an overlay over an Ash application's data. Inside `run/2`, reads see the base
  data patched with the branch's changes, and writes land in the overlay instead of the data layer. A branch can
  be forked, diffed, merged back through the application's own actions, or discarded.

  ## Example

  Add `Ramal.Supervisor` to the application's supervision tree first, then:

      {:ok, branch} = Ramal.branch(MyApp.Farm, name: "move herd R7 to paddock L18")

      {:ok, herds} = Ramal.run(branch, fn -> Ash.read!(MyApp.Farm.Herd) end)

      :ok = Ramal.discard(branch)

  Every function that takes a branch also takes its id, and starts the branch process from storage when it is
  not running, so callers never need to know whether a branch is in memory.

  """

  alias Ash.Resource.Info
  alias Ramal.{Branch, Current, Error, Limits, Resource, Storage, Supervisor, Telemetry}
  alias Ramal.Branch.Server
  alias Ramal.Preparation.Related

  @type branch_or_id :: Branch.t() | String.t()

  @doc """
  Creates an open branch over `domain` and starts its process.

  ## Options

    * `:name` - a label for people
    * `:metadata` - a map the host uses freely
    * `:owner` - who the branch belongs to, so that `list/2` can show a user only their own (ADR 0018). Any term, but an
      id or a string, not a record: it is stored with the branch and compared with `==`. Default `nil`
    * `:tenant` - the one tenant the branch works in (ADR 0034). Reads and writes of a multitenant resource inside the
      branch must carry it (`:tenant_mismatch` otherwise); the merge reads the staleness rows with it. A branch without a
      tenant refuses multitenant resources used with a tenant (`:multitenancy_unsupported`). Default `nil`
    * `:durable` - `true` to append the writes of every action that ends to the storage's write log before the action
      returns, so that a crash of the node loses none of them (ADR 0048). Default: the supervisor's `:durable`, which is
      `false`. Costs one storage write per action; the writes of an action that has not ended are never stored. The
      fingerprints of rows the branch read but did not write since its last save are not in the log, so after a crash
      the merge cannot see a change to those rows in the database. Needs a storage that defines
      `c:Ramal.Storage.append/4` and `c:Ramal.Storage.writes_after/2`

  Returns `{:error, %Ramal.Error{reason: :not_started}}` when `Ramal.Supervisor` is not running, and
  `:no_branchable_resources` when no resource of the domain uses `Ramal.Resource` (or all of them opted out), since
  such a branch could never change what a read returns, `:unbranchable_resources` when a resource of the domain has write
  actions and neither uses `Ramal.Resource` nor opts out with `branchable? false` (ADR 0027), `:limit_reached` when the supervisor's
  `:max_active_branches` or `:branch_rate` is reached (both off by default, see `Ramal.Supervisor`), and
  `:durability_unsupported` when `durable: true` meets a storage that cannot keep the write log.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm, name: "what if", metadata: %{ticket: 42})
      branch.status
      #=> :open
  """
  @spec branch(module, keyword) :: {:ok, Branch.t()} | {:error, Error.t()}
  def branch(domain, opts \\ []) when is_atom(domain) do
    with {:ok, config} <- Supervisor.config(),
         :ok <- ensure_branchable(domain),
         :ok <- Limits.check(domain, :branch, config),
         opts = Keyword.put_new(opts, :durable, config.durable),
         :ok <- ensure_durable(opts[:durable], config),
         branch = Branch.new(domain, opts),
         :ok <- config.storage.put(branch, config.storage_config),
         {:ok, _pid} <- Server.start(branch, config) do
      Telemetry.branch(:create, branch)
      {:ok, branch}
    end
  end

  @doc """
  Runs `fun` with the branch as the current branch of the calling process and returns `{:ok, result}`.

  The previous state is restored when `fun` returns and also when it raises, throws or exits. `run/2` does not nest:
  calling it inside another `run/2` returns `{:error, %Ramal.Error{reason: :nested_branch}}` without running `fun`. A
  branch of a branch is a nested fork (`fork/2` with `nested: true`), and it is run on its own, not inside its parent. Tasks started inside `fun` do not inherit the branch; call `run/2` inside the task with the same branch.

  Returns `:not_found` for an unknown id and `:not_open` for a merged or discarded branch.

  Creates, updates and destroys inside `fun` land in the branch instead of the data layer (`Ramal.Capture`), and the
  notifications they produce are dropped unless the resource sets `notify_in_branch? true`.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:ok, nil} = Ramal.run(branch, fn -> Ramal.current() && nil end)
  """
  @spec run(branch_or_id, (-> result)) :: {:ok, result} | {:error, Error.t()} when result: term
  def run(branch_or_id, fun) when is_function(fun, 0) do
    id = id_of(branch_or_id)

    if current = Current.own_id() do
      {:error,
       Error.new(
         :nested_branch,
         "Ramal.run/2 was called inside branch #{inspect(current)}; use a nested fork (`Ramal.fork/2` with `nested: true`) for a branch of a branch",
         %{current: current, requested: id}
       )}
    else
      with {:ok, status} <- Server.status(id),
           :ok <- ensure_open(id, status) do
        id |> collect_notifications(fun) |> refuse_raw_query(id)
      end
    end
  end

  @doc """
  Like `run/2` but returns the result and raises `Ramal.Error` instead of returning an error tuple.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      Ramal.run!(branch, fn -> :done end)
      #=> :done
  """
  @spec run!(branch_or_id, (-> result)) :: result when result: term
  def run!(branch_or_id, fun) do
    case run(branch_or_id, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  @doc """
  The branch the calling process is running in, or `nil` outside `run/2`.

  ## Example

      Ramal.current()
      #=> nil
      Ramal.run!(branch, fn -> Ramal.current().id end)
      #=> branch.id
  """
  @spec current() :: Branch.t() | nil
  def current do
    with id when is_binary(id) <- Current.id(),
         {:ok, branch} <- Server.get(id) do
      branch
    else
      _ -> nil
    end
  end

  @doc """
  The Ash context that makes an action run in the branch, for callers that cannot use `run/2`.

  `run/2` puts the branch in the calling process. A tool runner such as an LLM agent's MCP server executes each tool
  call inside its own request, passes `context:` to Ash and cannot wrap the call in a function. Pass this map as the
  `context` option of the read, create, update or destroy and the action sees and writes the branch, as it does inside
  `run/2`, with the differences below. Ash carries `context[:shared]` into the queries and changesets it derives, so
  relationship loads follow (ADR 0002). `AshAi` hands the `context` of its MCP router and its tool loop to the action
  it runs.

  Unlike `run/2` this does not check that the branch exists or is open: an unknown, proposed, merged or discarded
  branch makes the action fail instead, with the error `run/2` would have returned. It also does not queue the
  notifications of the writes, so a notifier fires for a write made in a branch even on a resource without
  `notify_in_branch? true`. Ash has no per-call switch to hold notifications back, so the notifier has to skip them
  itself: `in_branch?/1` tells it that the write belongs to a branch. Prefer `run/2` whenever you can wrap the call in
  a function.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      herd = Ash.create!(MyApp.Farm.Herd, %{name: "R10", head: 5}, context: Ramal.context(branch))
      # The row is in the branch, not in the database.
  """
  @spec context(branch_or_id) :: map
  def context(branch_or_id), do: Current.shared_context(id_of(branch_or_id))

  @doc """
  Whether a notification, changeset, query or context map carries a branch passed with `context/1`.

  A write made with `context: Ramal.context(branch)` sends its notifications, unlike a write inside `run/2`, and Ash
  offers no way to hold them back per call (it builds the notification from the resource's notifiers and the
  action's, `for: Ash.Resource.Info.notifiers(resource) ++ action.notifiers`). A notifier that must not fire for a what-if checks this first.
  Writes inside `run/2` do not need it: their notifications are dropped, or sent after `run/2` returns for a resource
  with `notify_in_branch? true`, and are then no longer marked.

  ## Example

      iex> Ramal.in_branch?(Ramal.context("b1"))
      true
      iex> Ramal.in_branch?(%{})
      false

  In a notifier:

      def notify(notification) do
        unless Ramal.in_branch?(notification), do: send_the_email(notification)
        :ok
      end
  """
  @spec in_branch?(Ash.Notifier.Notification.t() | Ash.Changeset.t() | Ash.Query.t() | map) ::
          boolean
  def in_branch?(%Ash.Notifier.Notification{changeset: changeset}), do: in_branch?(changeset)

  def in_branch?(%struct{context: context}) when struct in [Ash.Changeset, Ash.Query],
    do: in_branch?(context)

  def in_branch?(%_{}), do: false
  def in_branch?(context) when is_map(context), do: is_binary(Current.shared_id(context))
  def in_branch?(_other), do: false

  @doc """
  The branch with that id, with its overlay and log as they are now.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:ok, ^branch} = Ramal.get(branch.id)
  """
  @spec get(String.t()) :: {:ok, Branch.t()} | {:error, Error.t()}
  def get(id) when is_binary(id), do: Server.get(id)

  @doc """
  The branches of `domain` as last persisted, oldest first.

  This reads storage and never loads a process, so a branch that is in memory shows the state of its last persist
  (its creation, its last unload, or its status change). Use `get/1` for the live state.

  ## Options

    * `:status` - only branches with that status (`:open`, `:proposed`, `:merged`, `:rejected`, `:discarded`)
    * `:owner` - only branches created or forked with that `:owner` (compared with `==`). `owner: nil` lists the
      branches that have none. Without the option every branch of the domain is listed, as before.

  The owner filter is for showing each user their own branches; it is not access control. A branch is still reachable
  by its id (`SECURITY.md`).

  ## Example

      {:ok, open} = Ramal.list(MyApp.Farm, status: :open)
      {:ok, mine} = Ramal.list(MyApp.Farm, owner: current_user.id)
  """
  @spec list(module, keyword) :: {:ok, [Branch.t()]} | {:error, Error.t()}
  def list(domain, opts \\ []) when is_atom(domain) do
    filters = Keyword.take(opts, [:status, :owner])

    with {:ok, config} <- Supervisor.config(),
         {:ok, branches} <- config.storage.list(domain, filters, config.storage_config) do
      # A storage written before owners existed ignores the filter, and returning every user's branches for an owner
      # filter is the failure this option exists to prevent, so the result is checked again here.
      {:ok, filter_owner(branches, filters)}
    end
  end

  defp filter_owner(branches, filters) do
    case Keyword.fetch(filters, :owner) do
      {:ok, owner} -> Enum.filter(branches, &(&1.owner == owner))
      :error -> branches
    end
  end

  @doc """
  Forks a branch: a new open branch, with its own process, that starts with the parent's overlay, log and base.

  The fork sees the parent's changes as of the moment of the fork and nothing after; the parent never sees the fork's.
  Both share the same database. `metadata.forked_from` holds the parent's id. A fork counts against the same limits
  as `branch/2` (`:limit_reached`), counted for the parent's domain.

  Only an open branch can be forked, and not while a merge holds it: a fork of a branch being merged would replay the
  same writes again (`:not_open`, ADR 0007). The writes of actions still running in the parent are left out of the
  fork, because those actions may yet fail (ADR 0033).

  A plain fork is a sibling: merging it replays its whole log, including what it inherited, into the database. A
  nested fork (`nested: true`, ADR 0043) is a branch of the branch: `merge/2` replays only what it wrote itself into the
  parent, through the real actions, and the parent merges to the database later, as one branch. The fork records what
  it saw of the parent's rows, and the merge is refused as `:stale` when the parent holds one of them differently now
  (`on_stale` applies as for the database). The parent can be forked this way again and again, and a nested fork can
  have nested forks of its own. A fork merges into its parent once, and not at all into a parent that is no longer open
  (`:parent_not_open`): when the parent was merged to the database or discarded, discard its forks.

  ## Options

    * `:name` - default: the parent's name
    * `:metadata` - default: the parent's metadata
    * `:owner` - default: the parent's owner
    * `:nested` - make the fork a branch of the parent that merges into it, default `false`
    * `:durable` - default: the parent's. The fork is stored as a snapshot of what it copied and starts a write log of
      its own (ADR 0048)

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:ok, fork} = Ramal.fork(branch, name: "variant")
      fork.metadata.forked_from == branch.id
      #=> true

      {:ok, child} = Ramal.fork(branch, nested: true)
      Ramal.run!(child, fn -> Ash.update!(herd, %{head: 31}, authorize?: false) end)
      {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(child, authorize?: false)
      # The change is in `branch` now, and still not in the database.
  """
  @spec fork(branch_or_id, keyword) :: {:ok, Branch.t()} | {:error, Error.t()}
  def fork(branch_or_id, opts \\ []) do
    with {:ok, config} <- Supervisor.config(),
         {:ok, parent} <- Server.fork_source(id_of(branch_or_id)),
         :ok <- Limits.check(parent.domain, :fork, config),
         fork = Branch.fork(parent, opts),
         :ok <- ensure_durable(fork.durable, config),
         :ok <- config.storage.put(fork, config.storage_config),
         {:ok, _pid} <- Server.start_forked(fork, config) do
      Telemetry.branch(:fork, fork, %{parent_id: parent.id, nested: opts[:nested] == true})
      {:ok, fork}
    end
  end

  @doc """
  The changes a branch holds, as `Ramal.Change` structs in the order the branch first touched each row.

  Never queries the database: updated and deleted rows are compared with the copy the branch kept when it first wrote
  them. A row the branch changed and then changed back is left out. A fork's diff includes what it inherited.

  ## Options

    * `:against` - `:parent`, for a nested fork: only the rows the fork wrote itself, compared with what its parent holds
      now (`Ramal.Branch.diff_against/3`), which is what merging it would change in the parent. A branch that is not a
      nested fork returns `:no_parent`. Default: the database

  ## Example

      {:ok, [change]} = Ramal.diff(branch)
      change.kind
      #=> :updated
      change.changes
      #=> %{head: {30, 31}}
  """
  @spec diff(branch_or_id, keyword) :: {:ok, [Ramal.Change.t()]} | {:error, Error.t()}
  def diff(branch_or_id, opts \\ []) do
    id = id_of(branch_or_id)

    case Keyword.get(opts, :against) do
      nil -> Server.diff(id, attributes: &Resource.attributes/1)
      :parent -> diff_against_parent(id)
    end
  end

  defp diff_against_parent(id) do
    with {:ok, child} <- Server.get(id),
         {:ok, parent} <- parent_of(child),
         do: Branch.diff_against(child, parent, attributes: &Resource.attributes/1)
  end

  defp parent_of(%Branch{parent: %{id: parent_id}}), do: Server.get(parent_id)

  defp parent_of(%Branch{id: id}) do
    {:error,
     Error.new(
       :no_parent,
       "branch #{inspect(id)} is not a nested fork, so it has no parent to diff against",
       %{id: id}
     )}
  end

  @doc """
  `Ash.load/3` for records a branch changed.

  `Ash.load/3` first reselects the relationship's source attribute (for example `paddock_id`) from the data layer, and
  that read runs none of the read hooks (`reselect_and_load/6` in Ash 3.37), so after a herd moved to another paddock in
  the branch `Ash.load(herd, :paddock)` follows the database's foreign key (ADR 0031). Inside a branch this puts the
  branch's attribute values on each record that has an overlay entry, then loads with `reuse_values?: true`, which skips
  the reselect; the relationship itself is read through the read actions, so it is patched too. Outside a branch it is
  `Ash.load/3`.

  `data` is a record or a list of records, `load` and `opts` are `Ash.load/3`'s. A branch carried only by
  `context: Ramal.context(branch)` in `opts` counts as current. Records the branch destroyed are loaded as they are.

  ## Example

      Ramal.run!(branch, fn ->
        moved = Ash.update!(herd, %{paddock_id: other.id})
        Ramal.load!(moved, :paddock).paddock.id
        #=> other.id
      end)
  """
  @spec load(Ash.Resource.record() | [Ash.Resource.record()], term, keyword) ::
          {:ok, Ash.Resource.record() | [Ash.Resource.record()]} | {:error, Ash.Error.t()}
  def load(data, load, opts \\ []) when is_list(opts) do
    case Current.resolve(opts[:context] || %{}) do
      nil ->
        Ash.load(data, load, opts)

      id ->
        with {:ok, data} <- with_branch_values(id, data) do
          Ash.load(data, load, Keyword.put(opts, :reuse_values?, true))
        end
    end
  end

  @doc """
  Like `load/3` but returns the records or raises.

  ## Example

      Ramal.run!(branch, fn -> Ramal.load!(herd, :paddock) end)
  """
  @spec load!(Ash.Resource.record() | [Ash.Resource.record()], term, keyword) ::
          Ash.Resource.record() | [Ash.Resource.record()]
  def load!(data, load, opts \\ []) do
    case load(data, load, opts) do
      {:ok, loaded} -> loaded
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  # The records a caller holds may predate the branch's writes (a struct read before the update), and `Ash.load/3`
  # would overwrite them with the database's values. Only attributes are copied, so what the caller loaded stays.
  defp with_branch_values(id, data) when is_list(data) do
    data
    |> Enum.group_by(& &1.__struct__)
    |> Enum.reduce_while({:ok, %{}}, fn {resource, records}, {:ok, entries} ->
      keys = Enum.map(records, &Resource.key(resource, &1))

      case Server.fetch(id, resource, keys) do
        {:ok, found} -> {:cont, {:ok, Map.put(entries, resource, found)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.map(data, &put_branch_values(&1, entries))}
      {:error, _} = error -> error
    end
  end

  defp with_branch_values(id, %{__struct__: _} = record) do
    with {:ok, [record]} <- with_branch_values(id, [record]), do: {:ok, record}
  end

  defp put_branch_values(%resource{} = record, entries) do
    case entries |> Map.fetch!(resource) |> Map.fetch(Resource.key(resource, record)) do
      {:ok, {_kind, branch_record}} ->
        names = resource |> Info.attributes() |> Enum.map(& &1.name)
        Map.merge(record, Map.take(branch_record, names))

      _deleted_or_untouched ->
        record
    end
  end

  @doc """
  Computes an aggregate over the rows a read of `query` returns. Inside `run/2` those rows are the branch's: base rows
  patched with the overlay, filtered, sorted and limited as the query says. Outside a branch it is `Ash.count/2`,
  `Ash.sum/3` and the like, so the same call works in both places.

  This exists because the aggregates Ash hands to the data layer (`Ash.count/2`, `aggregates do ... end`) never see the
  overlay. The answer is exact and its cost follows the overlay, not the table: the database aggregates the rows the
  overlay does not touch, and the branch reads only the rows it does. A query with a `limit`, an `offset` or a
  `distinct` is answered by reading every matching row instead, because the aggregate then depends on which rows come
  first. See `Ramal.Aggregate`.

  The rows the database aggregates are not read, so they are not fingerprinted and do not join the merge staleness
  check (ADR 0013): a branch that only aggregated a row and never read or wrote it does not go stale when that row
  changes.

  `kind` is `:count`, `:exists`, `:sum`, `:min`, `:max`, `:avg`, `:first` or `:list`; `field` is an attribute (not needed
  for `:count` and `:exists`). `:first` is the field of the first row of the query, `nil` included, as `Ash.first/3`;
  `:list` is the field of every row in the query's order, without `nil`s unless `include_nil?: true`, and with each value
  once, keeping the first, if `uniq?: true`, as `Ash.list/3`. Both depend on the order of the rows, so they are answered
  by reading every matching row, and sort the query when the order matters. `opts` go to the read: `:actor`,
  `:authorize?`, `:tenant`, `:domain`, `:context`. A branch carried only by
  `context: Ramal.context(branch)`, in `opts` or in the query's context, counts as a current branch, as it does for
  reads. Returns `{:ok, value}` or the error Ash returned. Raises `ArgumentError` for an unknown kind or a field that is
  not an attribute, in a branch or not.

  `:min` and `:max` over strings of an AshPostgres resource compare by the collation of the column, for the branch's
  rows as for the database's, so `"apple"` is the minimum of `"apple"` and `"Banana"` under `en_US.UTF-8`
  (ADR 0045). The comparison is one read-only query for the values that need ordering.

  Confirmed against Ash 3.37 (`lib/ash.ex`): `Ash.count/2` takes no field, and the others take `(query, field, opts)`.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)

      Ramal.run!(branch, fn ->
        Ash.create!(MyApp.Farm.Herd, %{name: "R10", head: 5})
        {:ok, total} = Ramal.aggregate(MyApp.Farm.Herd, :sum, :head)
        total
        #=> the base total plus 5
      end)
  """
  @spec aggregate(Ash.Query.t() | module, Ramal.Aggregate.kind(), atom | nil, keyword) ::
          {:ok, term} | {:error, Ash.Error.t()}
  def aggregate(query, kind, field \\ nil, opts \\ [])
      when is_atom(kind) and (is_atom(field) or is_nil(field)) and is_list(opts) do
    query = Ash.Query.new(query)
    Ramal.Aggregate.validate!(kind, field, query.resource)
    {shape, opts} = Keyword.split(opts, [:uniq?, :include_nil?])
    spec = {kind, field, shape}

    # The hooks resolve the branch from the process and from the query's context, so this does too: an agent or MCP
    # caller carries it only in `context: Ramal.context(branch)` or in the query's context.
    case Current.resolve(query.context) || Current.resolve(opts[:context] || %{}) do
      nil -> outside_branch(query, spec, opts)
      id -> in_branch(id, query, spec, opts)
    end
  end

  @doc """
  Like `aggregate/4` but returns the value or raises.

  ## Example

      Ramal.run!(branch, fn -> Ramal.aggregate!(MyApp.Farm.Herd, :count) end)
  """
  @spec aggregate!(Ash.Query.t() | module, Ramal.Aggregate.kind(), atom | nil, keyword) :: term
  def aggregate!(query, kind, field \\ nil, opts \\ []) do
    case aggregate(query, kind, field, opts) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  # With overlay entries the database aggregates the rows outside the overlay and the branch reads only the overlaid
  # ones (Ramal.Aggregate). Without any, the base is the branch, so the data layer's answer is exact.
  defp in_branch(id, query, spec, opts) do
    with {:ok, affected?} <- Related.affected?(query, id),
         do: in_branch(affected?, id, query, spec, opts)
  rescue
    # `:min` and `:max` of a string ask the database for its collation (ADR 0045), which can fail like any query.
    error in Ramal.Error -> {:error, error}
  end

  # A filter through a relationship the branch changed is judged by the base's rows in the database's part of the delta,
  # so it reads every matching row through the patched path (ADR 0025).
  defp in_branch(true, _id, query, spec, opts), do: read_every_row(query, spec, opts)

  defp in_branch(false, id, query, {kind, field, _shape} = spec, opts) do
    case Server.keys(id, query.resource) do
      {:ok, []} ->
        outside_branch(query, spec, opts)

      {:ok, keys} ->
        if kind not in [:first, :list] and Ramal.Aggregate.applies?(query, length(keys)) do
          Ramal.Aggregate.delta(query, kind, field, opts, keys)
        else
          read_every_row(query, spec, opts)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # `Ash.first/3` takes the first row's value whatever it is, so `:first` keeps `nil`s here too.
  defp read_every_row(query, {kind, field, shape}, opts) do
    shape = if kind == :first, do: [include_nil?: true], else: shape
    shape = [tenant: opts[:tenant] || query.tenant] ++ shape

    with {:ok, records} <- Resource.read_all(query, opts) do
      {:ok, Ramal.Aggregate.compute(kind, field, records, query.resource, shape)}
    end
  end

  defp outside_branch(query, {:count, _field, _shape}, opts), do: Ash.count(query, opts)
  defp outside_branch(query, {:exists, _field, _shape}, opts), do: Ash.exists(query, opts)

  defp outside_branch(query, {:list, field, shape}, opts),
    do: Ash.list(query, field, shape ++ opts)

  defp outside_branch(query, {kind, field, _shape}, opts),
    do: apply(Ash, kind, [query, field, opts])

  @doc """
  Merges a branch into the database by replaying its log through the application's own actions, in one transaction.

  First every base row the branch read or wrote is compared with what the database holds now; if any changed, the
  merge is refused unless `on_stale` allows it. Then the log is replayed oldest first with real validations and
  policies. If anything fails, nothing is written and the branch stays open. On success the branch is `:merged`, its
  process stops, and the result holds what the replay wrote. See `Ramal.Merge` for the details and the limits.

  A nested fork (`fork/2` with `nested: true`) merges into its parent branch instead: the entries it wrote itself are
  replayed there, and the database is not touched until the parent is merged.

  ## Options

    * `:actor` - the actor for every replayed action. Default: the actor each write was captured with.
    * `:authorize?` - default `true`
    * `:on_stale` - `:error` (default), `:ignore`, or a function from the stale rows to `:continue` or `:abort`
    * `:mode` - only `:replay`

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      Ramal.run!(branch, fn -> Ash.update!(herd, %{head: 31}, authorize?: false) end)
      {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, authorize?: false)
  """
  @spec merge(branch_or_id, keyword) :: {:ok, Ramal.Merge.Result.t()} | {:error, Error.t()}
  def merge(branch_or_id, opts \\ []), do: branch_or_id |> id_of() |> Ramal.Merge.run(opts)

  @doc """
  Proposes an open branch for a decision: the branch is frozen (status `:proposed`, no more reads, writes or forks) and
  persisted, with who proposed it and why. Someone with the right to decide then calls `approve/2`, which merges it, or
  `reject/2`. The proposer can still `discard/1` it to withdraw it.

  Ramal does not decide who may approve: the host checks that before calling `approve/2` or `reject/2`, in its own
  policies. The people involved are whatever terms the host passes (a user struct, an id); a record loses its
  `sensitive?` attributes when stored (ADR 0010).

  ## Options

    * `:proposed_by` - who proposes it, default `nil`
    * `:reason` - why, a string, default `nil`

  Actions still running in the branch in other processes are waited for, up to four seconds (ADR 0033).

  Returns `{:error, %Ramal.Error{reason: :not_open}}` for a branch that is not open, including one already proposed.
  List the pending ones with `list(domain, status: :proposed)`; the diff to review is `diff/1`.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      Ramal.run!(branch, fn -> Ash.update!(herd, %{head: 31}, authorize?: false) end)
      {:ok, proposed} = Ramal.propose(branch, proposed_by: user, reason: "R7 has 31 head after the count")
      proposed.status
      #=> :proposed
  """
  @spec propose(branch_or_id, keyword) :: {:ok, Branch.t()} | {:error, Error.t()}
  def propose(branch_or_id, opts \\ []) do
    proposer = opts[:proposed_by]
    reason = opts[:reason]
    at = DateTime.utc_now()

    Server.propose(id_of(branch_or_id), &Branch.propose(&1, proposer, reason, at))
  end

  @doc """
  Approves a proposed branch: merges it exactly as `merge/2` would (staleness check, replay through the real actions,
  one transaction) and records the decision on the branch: who, why, when, how many entries were replayed and which
  stale rows were let through.

  Takes the options of `merge/2`, so `:actor` is the actor the replayed actions run as, and two more:

    * `:decided_by` - who approves it, default `nil`
    * `:reason` - why, a string, default `nil`

  A stale base or a failing replay returns the same errors as `merge/2` and leaves the branch `:proposed`, so the
  decider can retry with `on_stale: :ignore` or `reject/2` it. Returns `:not_open` for a branch that is not proposed.

  ## Example

      {:ok, %Ramal.Merge.Result{branch: branch}} =
        Ramal.approve(proposed, decided_by: manager, actor: manager, reason: "checked on site")

      branch.proposal.decision.status
      #=> :approved
  """
  @spec approve(branch_or_id, keyword) :: {:ok, Ramal.Merge.Result.t()} | {:error, Error.t()}
  def approve(branch_or_id, opts \\ []) do
    {decision, merge_opts} = Keyword.split(opts, [:decided_by, :reason])
    at = DateTime.utc_now()

    decide = fn result ->
      &Branch.decide(&1, :approved, at,
        by: decision[:decided_by],
        reason: decision[:reason],
        replayed: result.replayed,
        stale: result.stale
      )
    end

    with {:ok, result} <- Ramal.Merge.run(id_of(branch_or_id), merge_opts, :proposed, decide) do
      Telemetry.branch(:approve, result.branch)
      {:ok, result}
    end
  end

  @doc """
  Rejects a proposed branch: the decision is recorded and persisted, the branch becomes `:rejected` and its process
  stops. The overlay and log are kept so the rejected diff can still be read with `get/1` and `diff/1`; `discard/1`
  does not apply to a rejected branch.

  ## Options

    * `:decided_by` - who rejects it, default `nil`
    * `:reason` - why, a string, default `nil`

  Returns `:not_open` for a branch that is not proposed.

  ## Example

      {:ok, rejected} = Ramal.reject(proposed, decided_by: manager, reason: "count it again")
      rejected.status
      #=> :rejected
  """
  @spec reject(branch_or_id, keyword) :: {:ok, Branch.t()} | {:error, Error.t()}
  def reject(branch_or_id, opts \\ []) do
    at = DateTime.utc_now()

    Server.reject(
      id_of(branch_or_id),
      &Branch.decide(&1, :rejected, at, by: opts[:decided_by], reason: opts[:reason])
    )
  end

  @doc """
  Discards an open or proposed branch (a proposer withdrawing a proposal): its process stops and its overlay and log are
  dropped.

  The record stays in storage with status `:discarded`, so `list/2` can show it and later calls return
  `:not_open`. Discarding an already discarded branch is a no-op. A merged branch cannot be discarded.

  ## Options

    * `:purge` - `true` also deletes the record and its write log once the branch is discarded, as `delete/1` does, so
      nothing is left in storage or in `list/2`. Default `false`.

  A host that opens a branch (or a fork) per request as scratch space should discard it with `purge: true`: a kept
  record is about 1 KB in ETS and nothing else ever removes it, so the table and `list/2` grow without bound. Keep the
  record only for a branch someone will look at later, and `delete/1` it when they are done.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      :ok = Ramal.discard(branch)
      {:error, %Ramal.Error{reason: :not_open}} = Ramal.run(branch, fn -> :never end)

      {:ok, scratch} = Ramal.branch(MyApp.Farm)
      :ok = Ramal.discard(scratch, purge: true)
      {:error, %Ramal.Error{reason: :not_found}} = Ramal.get(scratch.id)
  """
  @spec discard(branch_or_id) :: :ok | {:error, Error.t()}
  def discard(branch_or_id), do: branch_or_id |> id_of() |> Server.discard()

  # Only `warn_raw_queries: :raise` records a raw query (Ramal.RawQueryGuard); telemetry cannot raise in the query.
  defp refuse_raw_query(result, id) do
    case Supervisor.take_raw_query(id) do
      nil -> {:ok, result}
      detail -> {:error, Ramal.RawQueryGuard.error(detail)}
    end
  end

  @doc """
  `discard/1` with options: `discard(branch, purge: true)` also deletes the record, as `delete/1` does. See `discard/1`
  for what discarding does and for the options.

  ## Example

      :ok = Ramal.discard(branch, purge: true)
  """
  @spec discard(branch_or_id, keyword) :: :ok | {:error, Error.t()}
  def discard(branch_or_id, opts) when is_list(opts) do
    with :ok <- discard(branch_or_id) do
      if Keyword.get(opts, :purge, false), do: delete(branch_or_id), else: :ok
    end
  end

  @doc """
  Deletes the record of a branch that is `:discarded`, `:merged` or `:rejected` from storage, with its write log.

  Afterwards `get/1` returns `:not_found` and `list/2` no longer shows it. An `:open` or `:proposed` branch is refused
  with `{:error, %Ramal.Error{reason: :not_terminal}}`: discard it first, or use `discard/2` with `purge: true`.
  Deleting a branch that is not in storage returns `:not_found`.

  This never touches the database the branch was made from, only the branch's own record.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)
      {:error, %Ramal.Error{reason: :not_terminal}} = Ramal.delete(branch)
      :ok = Ramal.discard(branch)
      :ok = Ramal.delete(branch)
  """
  @spec delete(branch_or_id) :: :ok | {:error, Error.t()}
  def delete(branch_or_id), do: branch_or_id |> id_of() |> Server.purge()

  # Writes inside a branch queue their notifications exactly as writes inside `Ash.transaction/3` do: nothing is sent
  # until the outermost transaction ends. `Ash.transaction/3` with no resources opens no database transaction and,
  # with `return_notifications?: true`, hands the queue back instead of sending it. Only resources that opted in with
  # `notify_in_branch? true` get theirs sent.
  defp collect_notifications(id, fun) do
    {:ok, result, notifications} =
      Ash.transaction([], fn -> Current.with_branch(id, fun) end, return_notifications?: true)

    notifications
    |> Enum.filter(&Resource.notify_in_branch?(&1.resource))
    |> Ash.Notifier.notify()

    result
  end

  defp ensure_durable(true, %{storage: storage}) do
    if Storage.durable?(storage), do: :ok, else: {:error, Storage.durability_unsupported(storage)}
  end

  defp ensure_durable(_not_durable, _config), do: :ok

  defp ensure_branchable(domain) do
    case Resource.branchable_resources(domain) do
      [] ->
        {:error,
         Error.new(
           :no_branchable_resources,
           "#{inspect(domain)} has no resource with `extensions: [Ramal.Resource]` that is branchable; " <>
             "add the extension to the resources a branch should cover",
           %{domain: domain}
         )}

      _branchable ->
        case Resource.uncovered(domain) do
          [] -> :ok
          resources -> {:error, uncovered_error(domain, resources)}
        end
    end
  end

  # A write to a resource without the hooks reaches the database from inside a branch, with no error (ADR 0027).
  defp uncovered_error(domain, resources) do
    Error.new(
      :unbranchable_resources,
      "#{inspect(domain)} has resources a branch would not cover: #{Enum.map_join(resources, ", ", &inspect/1)}. A write " <>
        "to one inside a branch would reach the database. Add `extensions: [Ramal.Resource]` to each, or opt out " <>
        "explicitly with `ramal do branchable? false end` (writes to it are then real)",
      %{domain: domain, resources: resources}
    )
  end

  defp id_of(%Branch{id: id}), do: id
  defp id_of(id) when is_binary(id), do: id

  defp ensure_open(_id, :open), do: :ok

  defp ensure_open(id, status) do
    {:error,
     Error.new(:not_open, "branch #{inspect(id)} is #{status}, not open", %{
       id: id,
       status: status
     })}
  end
end
