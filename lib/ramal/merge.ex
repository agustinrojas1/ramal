defmodule Ramal.Merge do
  @moduledoc """
  Merges a branch into the base: checks that the base did not move under the branch, then replays the branch's log
  through the application's real actions inside one transaction.

  `Ramal.merge/2` is the public entry point. The steps, in order:

    1. The branch process is claimed, which fails unless the branch is open and not already being merged. While it is
       claimed the process refuses writes, reads of its slice, discards and a second merge. Actions still running in the
       branch in other processes are waited for first, up to four seconds, so their writes are replayed only if they
       succeed (ADR 0033).
    2. Every base row the branch fingerprinted is read again, locked (`FOR UPDATE`) where the data layer supports it,
       and compared. A row that is gone or whose fingerprint differs is stale. `on_stale` decides what happens.
    3. The log is replayed oldest first with no branch current, so every action runs for real: validations and
       policies see the base as it is now. Entries marked `nested?` are skipped, because replaying the action that
       wrote them runs their hook again. An update or destroy of a row step 2 read and locked uses that row instead of
       reading it again, once per row, until the first entry a hook wrote.
    4. Still in the transaction, the storage's `mark_merged/2` stores the branch as `:merged`, or refuses a branch it
       already holds as merged (an earlier merge committed and its process died before finishing); with Postgres
       storage on the resources' repo the merged row commits with the replay (ADR 0035,
       `docs/adr/0035-merged-status-in-the-merge-transaction.md`). On success the process stops. On any failure the
       transaction is rolled back and the branch stays open. Once the transaction has committed the merge is never
       reported as failed: if the storage has no `mark_merged/2` and refuses the `:merged` write after the commit, or
       refuses an approval's decision, `merge/2` returns `{:ok, result}` with the error in `result.persist_failed`, and
       the branch process keeps the branch as merged and writes it again when it is idle (ADR 0023).

  Rows a replayed create writes keep the primary key they had in the branch (the key is forced onto the changeset), so
  later log entries and the branch's own diff still name the right rows. So do the rows a hook creates: the entries of
  one action and of its hooks share a `root`, and the replay of the action gives its hooks' creates the keys they had,
  in order (ADR 0041). Attributes the caller set on the changeset after `for_create` or
  `for_update` (`Ash.Changeset.change_attribute/3`) are recorded with the entry as `forced` and set again by the replay.

  ## Options

    * `:actor` - the actor for every replayed action. Default: the actor each entry was recorded with.
    * `:authorize?` - default `true`
    * `:on_stale` - `:error` (default), `:ignore`, or a function from the stale rows to `:continue` or `:abort`
    * `:context` - a map set as the context of every replayed changeset (`Ash.Changeset.set_context/2`), so a change or
      hook reads it from `changeset.context`. It is how a host says what the merge is ("approved as request 42") or passes
      data that is not an action input. The context a write was captured with is not recorded in the log, so this is the
      only context a replayed action sees. Default: none.
    * `:mode` - only `:replay`

  Data layers that cannot run transactions, such as `Ash.DataLayer.Ets`, cannot roll a failed replay back. The staleness
  check still runs before the first write, so a stale base writes nothing. A replayed action that fails after earlier
  entries were written leaves those writes in place, the branch stays open, and the `:merge_failed` error lists the
  resources in `details.not_rolled_back`. `Ash.transact/3` runs the function as it is for such a data layer and returns
  its `{:error, _}` inside `{:ok, _}`, which the merge unwraps.

  ## Inside the caller's transaction

  Called inside a `Repo.transaction/1` or `Ash.transact/3` of the host, the merge sets a `SAVEPOINT` (AshPostgres only)
  and goes back to it when it is refused, so a stale refusal or a failed replay returns `{:error, %Ramal.Error{}}`, the
  host's earlier writes stay in its transaction, the code after the call runs, and the branch stays open. A merge that
  succeeds commits with the host's transaction. The host decides whether to roll its own transaction back. Another data
  layer keeps the behaviour of a nested transaction: a refusal rolls back the host's transaction (#223).

  ## Checking staleness without merging (experimental, ADR 0051)

  `stale/2` runs the check of step 2 and nothing else, and `mark_merged/1` is the claim and the `:merged` write of
  steps 1 and 4 without the replay. A host that commits through its own command layer calls `stale/2` with `lock: true`
  inside its own transaction, runs its commands, commits, and then calls `mark_merged/1`. The check is the one
  `merge/2` runs (`stale_rows/2`), not a copy of it.

  ## Nested forks

  A branch made with `Ramal.fork(parent, nested: true)` merges into its parent instead of the database (ADR 0043). The
  steps differ, and nothing reaches the database:

    1. The fork is claimed as above.
    2. The parent is copied with its `version` (`Server.merge_source/1`), after the actions running in it have ended.
       A parent that is not open, or is being merged, refuses it: `:parent_not_open`.
    3. Every row the fork read or wrote is compared with what the parent held when the fork first saw it
       (`Ramal.Branch.stale_against/2`). `on_stale` decides what happens, as for the database.
    4. The entries the fork wrote itself, not the ones it inherited, are replayed oldest first through the real actions in
       a scratch copy of the parent (`Server.start_scratch/2`), so validations and policies see the parent's view and a
       failed replay leaves the parent as it was.
    5. The parent takes the scratch's overlay, log and base in one call, and persists, if its `version` is the one copied
       (`Server.adopt/4`); otherwise steps 2 to 5 run once more, and then the merge is refused as `:stale`. The parent
       remembers the fork's id, so that a fork whose own `:merged` status was lost (a crash after the parent persisted) is
       found merged and not merged twice.

  Known limits, documented in `docs/adr/0007-merge.md` and `docs/adr/0041-replay-keeps-hook-keys-and-caller-attributes.md`:
  a branch works in one tenant (ADR 0034) and the staleness check reads with it, a hook that creates different rows
  from one run to the next gives them the keys the replay's creates get, and arguments set after `for_create` or
  `for_update` are not in the log.

  ## Example

      {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, actor: current_user)
  """

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL
  alias Ramal.{Branch, Current, Error, Overlay, Resource, Supervisor, Telemetry}
  alias Ramal.Branch.Server
  alias Ramal.{Capture, Current, Error, Overlay, Resource, Supervisor, Telemetry}
  alias Ramal.Merge.Result

  @lock :for_update

  @doc """
  Merges the branch with `id`. See the module doc for the steps and the options.

  Returns `{:error, %Ramal.Error{reason: :stale}}` with the stale rows in `details.rows`, `:merge_failed` with the log
  index, resource, action, Ash error and `not_rolled_back` resources in `details` when a replayed action fails,
  `:not_open` for a merged, discarded or already-merging branch, and `:nested_branch` when called inside `Ramal.run/2`.

  ## Example

      {:error, %Ramal.Error{reason: :stale, details: %{rows: rows}}} = Ramal.merge(branch)
  """
  @spec run(String.t(), keyword) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(id, opts \\ []) when is_binary(id), do: run(id, opts, :open, nil)

  @doc false
  # `Ramal.approve/2` merges a branch that is `:proposed`, and records its decision on the branch in the same step that
  # marks it merged: `decide` turns the merge result into the function that annotates the branch.
  @spec run(
          String.t(),
          keyword,
          :open | :proposed,
          (Result.t() -> (Ramal.Branch.t() -> Ramal.Branch.t())) | nil
        ) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def run(id, opts, from, decide) when is_binary(id) do
    opts = validate!(opts)

    with :ok <- ensure_outside_branch(id),
         {:ok, domain} <- Server.domain(id) do
      :telemetry.span([:ramal, :merge], %{branch_id: id, domain: domain}, fn ->
        result = claim_and_merge(id, opts, from, decide)
        {result, stop_metadata(id, domain, result)}
      end)
    end
  end

  @doc """
  The rows the branch read or wrote whose fingerprint no longer matches the database: the check `run/2` makes, on its
  own (experimental, ADR 0051). Each row is `%{resource: module, key: term, reason: :changed | :deleted}`, sorted.

  The branch is not claimed and not changed, so it may be checked again, and it stays open. Actions still running in it
  are waited for, as for a merge.

  ## Options

    * `:lock` - `true` reads the rows with `FOR UPDATE` where the data layer supports it, as the merge does, so a
      concurrent writer waits until the transaction ends. The locks are held by the caller's transaction, so the call
      must be inside one (`Ash.transact/3` or the repo's): outside one the locks would be gone on return, and the call
      is refused with `:not_in_transaction`. Default `false`.

  ## Example

      {:ok, []} = Ramal.Merge.stale(branch_id)
  """
  @spec stale(String.t(), keyword) ::
          {:ok, [%{resource: module, key: term, reason: :changed | :deleted}]}
          | {:error, Error.t()}
  def stale(id, opts \\ []) when is_binary(id) do
    lock? = Keyword.get(opts, :lock, false)

    unless is_boolean(lock?) do
      raise ArgumentError, "`lock` must be true or false, got: #{inspect(lock?)}"
    end

    with :ok <- ensure_outside_branch(id),
         {:ok, branch, _version} <- Server.merge_source(id),
         :ok <- ensure_database_branch(branch, "Ramal.stale/2"),
         :ok <- ensure_transaction(branch, lock?) do
      {rows, _fetched} = stale_rows(branch, lock?)
      {:ok, rows}
    end
  rescue
    error in [Ash.Error.Invalid, Ash.Error.Unknown, Ash.Error.Forbidden, Ash.Error.Framework] ->
      {:error, to_error(error)}
  end

  @doc """
  Stores an open branch as `:merged` without replaying its log (experimental, ADR 0051), for a host that applied the
  work through its own commands after `stale/2` found nothing stale.

  Call it after the host's transaction committed: the branch is claimed, written as `:merged`, and its process stops, as
  at the end of `run/2`. Returns the merged branch. If the storage refuses the write the process keeps the branch as
  merged and stores it when it is idle (ADR 0023), and the call returns the storage's error.

  ## Example

      {:ok, %Ramal.Branch{status: :merged}} = Ramal.Merge.mark_merged(branch_id)
  """
  @spec mark_merged(String.t()) :: {:ok, Branch.t()} | {:error, Error.t()}
  def mark_merged(id) when is_binary(id) do
    with :ok <- ensure_outside_branch(id),
         {:ok, branch} <- Server.begin_merge(id, :open),
         :ok <- claimed_database_branch(id, branch) do
      case Server.finish_merge(id, :merged) do
        :ok ->
          Telemetry.branch(:mark_merged, branch)
          {:ok, %{branch | status: :merged}}

        {:persist_failed, error} ->
          {:error, error}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # A nested fork merges into its parent, never into the database, so neither check nor mark means anything for it.
  defp ensure_database_branch(%Branch{parent: nil}, _call), do: :ok

  defp ensure_database_branch(%Branch{id: id, parent: parent}, call) do
    {:error,
     Error.new(
       :nested_fork,
       "#{call} is for branches that merge into the database; #{inspect(id)} is a nested fork of #{inspect(parent.id)} " <>
         "and merges into it with Ramal.merge/2",
       %{id: id, parent: parent.id}
     )}
  end

  defp claimed_database_branch(id, branch) do
    with {:error, _} = error <- ensure_database_branch(branch, "Ramal.mark_merged/1") do
      Server.finish_merge(id, :aborted)
      error
    end
  end

  # Locks last until the transaction that took them ends, so a locking read outside one protects nothing. Only the
  # resources whose data layer locks need it: ETS has no transactions and no locks.
  defp ensure_transaction(_branch, false), do: :ok

  defp ensure_transaction(branch, true) do
    outside =
      for {resource, _key} <- Map.keys(branch.base),
          Ash.DataLayer.data_layer_can?(resource, {:lock, @lock}),
          not Ash.DataLayer.in_transaction?(resource),
          uniq: true,
          do: resource

    case outside do
      [] ->
        :ok

      resources ->
        {:error,
         Error.new(
           :not_in_transaction,
           "Ramal.stale/2 with `lock: true` must run inside the transaction that runs the commands; " <>
             "#{Enum.map_join(resources, ", ", &inspect/1)} is not in one. Wrap the check and the commands in " <>
             "Ash.transact/3, or pass `lock: false`",
           %{resources: resources}
         )}
    end
  end

  defp validate!(opts) do
    unless Keyword.get(opts, :mode, :replay) == :replay do
      raise ArgumentError,
            "Ramal.merge/2 only supports `mode: :replay`, got: #{inspect(opts[:mode])}"
    end

    case Keyword.get(opts, :context) do
      nil ->
        :ok

      context when is_map(context) ->
        :ok

      other ->
        raise ArgumentError, "`context` must be a map, got: #{inspect(other)}"
    end

    case Keyword.get(opts, :on_stale, :error) do
      on_stale when on_stale in [:error, :ignore] ->
        :ok

      fun when is_function(fun, 1) ->
        :ok

      other ->
        raise ArgumentError,
              "`on_stale` must be :error, :ignore or a 1-arity function, got: #{inspect(other)}"
    end

    opts
  end

  defp ensure_outside_branch(id) do
    case Current.id() do
      nil ->
        :ok

      current ->
        {:error,
         Error.new(
           :nested_branch,
           "Ramal.merge/2 was called inside branch #{inspect(current)}; merge runs real actions, so call it outside Ramal.run/2",
           %{current: current, requested: id}
         )}
    end
  end

  defp claim_and_merge(id, opts, from, decide) do
    with {:ok, config} <- Supervisor.config(),
         {:ok, branch} <- Server.begin_merge(id, from),
         {:ok, result, marked?} <- merge_or_release(id, branch, opts, config) do
      {:ok, finish(id, result, marked?, decide)}
    end
  end

  # The transaction stored the merged branch; with no decision to add there is nothing left to write.
  defp finish(id, result, true = _marked?, nil = _decide) do
    Server.finish_merge(id, :stored)
    result
  end

  defp finish(id, result, _marked?, decide) do
    annotate = if(decide, do: decide.(result), else: & &1)
    finish(id, %{result | branch: annotate.(result.branch)}, annotate)
  end

  # The replay has committed, so nothing here may turn the merge into an error. Without a merged marker a branch that
  # is merged in the database and open in storage can be merged a second time (ADR 0023); with one, the storage already
  # holds it as merged and this write only adds the approval's decision (ADR 0035). A failed persist is reported in the
  # result.
  defp finish(id, result, annotate) do
    case Server.finish_merge(id, :merged, annotate) do
      :ok ->
        result

      {:persist_failed, error} ->
        persist_failed(result, error)

      {:error, error} ->
        Telemetry.branch(:persist_failed, result.branch, %{reason: :merged, error: error})
        persist_failed(result, error)
    end
  end

  defp persist_failed(result, error), do: %{result | persist_failed: error}

  # The claim is released on every way out except success, so a failed or crashed merge leaves the branch open. A
  # branch the storage already holds as merged was merged by an earlier claim whose process died before finishing: the
  # process takes the stored status instead (ADR 0035).
  defp merge_or_release(id, branch, opts, config) do
    case merge(branch, opts, config) do
      {:ok, result} ->
        {:ok, result, unmark(branch, config, :committed)}

      # A fork the parent already holds the work of: its own `:merged` status was lost, so it is stored now.
      {:error, %Error{reason: :not_open, details: %{status: :merged, parent: _}}} = error ->
        Server.finish_merge(id, :merged)
        error

      {:error, %Error{reason: :not_open, details: %{status: :merged}}} = error ->
        unmark(branch, config, :committed)
        Server.finish_merge(id, :stored)
        error

      {:error, _} = error ->
        unmark(branch, config, :rolled_back)
        Server.finish_merge(id, :aborted)
        error
    end
  catch
    kind, reason ->
      unmark(branch, config, :rolled_back)
      Server.finish_merge(id, :aborted)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Whether the transaction marked the branch merged in storage. The mark is the last step of the transaction, so it was
  # made only if everything before it succeeded; if the commit then failed, a storage that could not join the
  # transaction (ETS, or Postgres on another repo) still says merged, and the open branch is put back.
  defp unmark(branch, config, outcome) do
    marked? = Process.delete({__MODULE__, :marked, branch.id}) == true

    if marked? and outcome == :rolled_back do
      config.storage.put(branch, config.storage_config)
    end

    marked?
  end

  defp mark_merged(branch, config) do
    with true <- marks?(config.storage),
         :ok <- config.storage.mark_merged(branch, config.storage_config) do
      Process.put({__MODULE__, :marked, branch.id}, true)
      :ok
    else
      false -> :ok
      {:error, _} = error -> error
    end
  end

  defp marks?(storage) do
    Code.ensure_loaded?(storage) and function_exported?(storage, :mark_merged, 2)
  end

  defp merge(%Branch{parent: %{}} = branch, opts, config),
    do: merge_nested(branch, opts, config, 1)

  defp merge(branch, opts, config) do
    entries = branch.log |> Enum.reverse() |> Enum.with_index()

    resources =
      entries
      |> Enum.map(fn {{_type, resource, _action, _input, _actor, _opts, _at}, _index} ->
        resource
      end)
      |> Enum.concat(for {{resource, _key}, _row} <- branch.base, do: resource)
      |> Enum.uniq()

    resources
    |> transact(fn ->
      with {:ok, stale, fetched} <- check_staleness(branch, opts),
           {:ok, records, replayed, keys, done} <- replay(entries, fetched, opts),
           :ok <- mark_merged(branch, config) do
        {stale, records, replayed, keys, done}
      end
    end)
    |> case do
      {:ok, {stale, records, replayed, keys, done}} ->
        {:ok,
         %Result{
           branch: %{branch | status: :merged},
           records: records,
           keys: keys,
           entries: done,
           replayed: replayed,
           stale: stale
         }}

      # A data layer that cannot run transactions (Ash.DataLayer.Ets) runs the function as it is, so a failure comes
      # back inside `{:ok, _}` instead of as `{:error, _}`; see `Ash.DataLayer.transaction/5` in `lib/ash/data_layer/data_layer.ex`.
      {:ok, {:error, error}} ->
        {:error, to_error(error)}

      {:ok, {:refused, {:error, error}}} ->
        {:error, to_error(error)}

      {:error, error} ->
        {:error, to_error(error)}
    end
  end

  # Inside the caller's own transaction a refused merge would roll the caller's writes back with it: the merge runs in
  # the caller's transaction, and Ash's `rollback` is a throw that DBConnection turns into a failed outermost
  # transaction (#223). `repo.transaction(fun, mode: :savepoint)` does not help, because DBConnection runs a nested
  # transaction without a savepoint. So the merge sets a real `SAVEPOINT` on each repo that is already in a
  # transaction, catches the rollback throw itself (`DBConnection.rollback/2` throws `{DBConnection, conn_ref, reason}`,
  # lib/db_connection.ex), goes back to the savepoint and returns the error: the caller's earlier writes are kept and
  # the branch stays open. Notifications the rolled-back writes queued are dropped with them. Outside a transaction
  # `Ash.transact/2` opens the real one and nothing changes. Only AshPostgres is known to have savepoints; for another
  # data layer the merge keeps the behaviour of the caller's transaction, which `docs/limits.md` describes.
  defp transact(resources, fun) do
    case savepoint_repos(resources) do
      [] ->
        Ash.transact(resources, fun)

      repos ->
        covered? =
          Enum.all?(resources, &(not transactional?(&1) or Ash.DataLayer.in_transaction?(&1)))

        Ash.transact(resources, fn -> with_savepoints(repos, covered?, fun) end)
    end
  end

  defp transactional?(resource), do: Ash.DataLayer.data_layer_can?(resource, :transact)

  defp savepoint_repos(resources) do
    if Code.ensure_loaded?(AshPostgres.DataLayer.Info) do
      for resource <- resources,
          Info.data_layer(resource) == AshPostgres.DataLayer,
          Ash.DataLayer.in_transaction?(resource),
          uniq: true,
          do: AshPostgres.DataLayer.Info.repo(resource, :mutate)
    else
      []
    end
  end

  defp with_savepoints(repos, covered?, fun) do
    savepoints =
      repos |> Enum.with_index() |> Enum.map(fn {repo, i} -> {repo, "ramal_merge_#{i}"} end)

    Enum.each(savepoints, fn {repo, name} -> savepoint_sql(repo, "SAVEPOINT #{name}") end)
    queued = Ramal.Ash.queued_notifications()

    try do
      fun.()
    catch
      :throw, {DBConnection, _conn_ref, reason} ->
        {:error, Ash.Error.to_ash_error(reason)}

      kind, reason ->
        back_to(savepoints, queued)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      {:error, _} = error ->
        back_to(savepoints, queued)

        # When every repo has a savepoint there is nothing left to roll back, and an `{:error, _}` would make Ash roll
        # the caller's transaction back.
        if covered?, do: {:refused, error}, else: error

      result ->
        Enum.each(savepoints, fn {repo, name} ->
          savepoint_sql(repo, "RELEASE SAVEPOINT #{name}")
        end)

        result
    end
  end

  defp back_to(savepoints, queued) do
    for {repo, name} <- Enum.reverse(savepoints) do
      savepoint_sql(repo, "ROLLBACK TO SAVEPOINT #{name}")
      savepoint_sql(repo, "RELEASE SAVEPOINT #{name}")
    end

    Ramal.Ash.restore_notifications(queued)
  end

  defp savepoint_sql(repo, sql), do: SQL.query!(repo, sql, [])

  defp to_error(error) do
    Error.find(error) || Error.new(:merge_failed, Exception.message(error), %{error: error})
  end

  # -- staleness ----------------------------------------------------------------------------------------------------

  defp check_staleness(branch, opts) do
    {rows, fetched} = stale_rows(branch)

    with :ok <- resolve_stale(rows, Keyword.get(opts, :on_stale, :error), "the base") do
      {:ok, rows, fetched}
    end
  end

  # What `on_stale` says to do with rows that changed under the branch.
  defp resolve_stale([], _on_stale, _where), do: :ok
  defp resolve_stale(_rows, :ignore, _where), do: :ok
  defp resolve_stale(rows, :error, where), do: {:error, stale_error(rows, where)}

  defp resolve_stale(rows, fun, where) do
    if fun.(rows) == :continue, do: :ok, else: {:error, stale_error(rows, where)}
  end

  # The stale rows, and the rows as the transaction read them (by `{resource, key}`), which the replay reuses.
  defp stale_rows(branch, lock? \\ true) do
    {stale, fetched} =
      branch.base
      |> Enum.filter(fn {_ref, row} -> row.fingerprint != nil end)
      |> Enum.group_by(fn {{resource, _key}, _row} -> resource end, fn {{_resource, key}, row} ->
        {key, row.fingerprint}
      end)
      |> Enum.map_reduce(%{}, fn {resource, expected}, fetched ->
        {stale, rows} = stale_in(resource, Map.new(expected), branch.tenant, lock?)

        {stale,
         Enum.reduce(rows, fetched, &Map.put(&2, {resource, Resource.key(resource, &1)}, &1))}
      end)

    {stale |> Enum.concat() |> Enum.sort_by(&{inspect(&1.resource), &1.key}), fetched}
  end

  defp stale_in(resource, expected, tenant, lock?) do
    rows =
      resource
      |> Ash.Query.new()
      |> Ash.Query.set_tenant(Resource.read_tenant(resource, tenant))
      |> filter_keys(resource, Map.keys(expected))
      |> lock(lock?)
      |> Resource.read_all(authorize?: false)
      |> case do
        {:ok, rows} -> rows
        {:error, error} -> raise error
      end

    current = current_fingerprints(resource, rows)

    stale =
      for {key, fingerprint} <- expected,
          reason = staleness(Map.fetch(current, key), fingerprint),
          do: %{resource: resource, key: key, reason: reason}

    {stale, rows}
  end

  # A row with an attribute the read could not load (a field policy) has no fingerprint and compares as changed.
  defp current_fingerprints(resource, rows) do
    fingerprints =
      Map.new(Resource.fingerprints(resource, rows), fn {{_resource, key}, fp} -> {key, fp} end)

    Map.new(rows, fn row ->
      key = Resource.key(resource, row)
      {key, Map.get(fingerprints, key)}
    end)
  end

  defp staleness(:error, _expected), do: :deleted
  defp staleness({:ok, fingerprint}, fingerprint), do: nil
  defp staleness({:ok, _other}, _expected), do: :changed

  defp filter_keys(query, resource, keys) do
    case Info.primary_key(resource) do
      [field] ->
        Ramal.Ash.do_filter(query, [{field, [in: keys]}])

      fields ->
        Ramal.Ash.do_filter(query, or: Enum.map(keys, &Enum.zip(fields, Tuple.to_list(&1))))
    end
  end

  defp lock(query, lock?) do
    if lock? and Ash.DataLayer.data_layer_can?(query.resource, {:lock, @lock}) do
      Ash.Query.lock(query, @lock)
    else
      query
    end
  end

  defp stale_error(rows, where) do
    Error.new(
      :stale,
      "#{length(rows)} row(s) changed in #{where} since the branch first saw them: " <>
        Enum.map_join(rows, ", ", &"#{inspect(&1.resource)} #{inspect(&1.key)} (#{&1.reason})") <>
        "; pass `on_stale: :ignore` to merge anyway",
      %{rows: rows}
    )
  end

  # -- nested forks -------------------------------------------------------------------------------------------------

  # ADR 0043. The fork's own entries are replayed in a copy of the parent, and the parent takes the copy if it did not
  # change in the meantime. One retry, because a write to the parent during a replay is ordinary; two in a row is not.
  defp merge_nested(branch, opts, config, attempt) do
    parent_id = branch.parent.id

    with {:ok, parent, version} <- merge_source(parent_id, branch),
         :ok <- not_adopted(parent, branch),
         stale = Branch.stale_against(branch, parent),
         :ok <-
           resolve_stale(
             stale,
             Keyword.get(opts, :on_stale, :error),
             "parent branch #{inspect(parent_id)}"
           ),
         {:ok, scratch, records, replayed, keys, done} <-
           replay_in_scratch(branch, parent, opts, config) do
      case Server.adopt(parent_id, scratch, branch, version) do
        :ok ->
          {:ok,
           %Result{
             branch: %{branch | status: :merged},
             records: records,
             replayed: replayed,
             stale: stale,
             keys: keys,
             entries: done
           }}

        {:error, :moved} when attempt == 1 ->
          merge_nested(branch, opts, config, 2)

        {:error, :moved} ->
          {:error, moved_error(branch, parent_id)}

        {:error, %Error{reason: :not_open, details: %{status: :merged}} = error} ->
          {:error, error}

        {:error, %Error{reason: :not_open} = error} ->
          {:error, parent_not_open(branch, parent_id, error)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp merge_source(parent_id, branch) do
    case Server.merge_source(parent_id) do
      {:ok, parent, version} ->
        {:ok, parent, version}

      {:error, %Error{reason: :not_open} = error} ->
        {:error, parent_not_open(branch, parent_id, error)}

      {:error, _} = error ->
        error
    end
  end

  # A fork whose id the parent holds merged into it already. Its own status is stored as merged by the caller.
  defp not_adopted(parent, branch) do
    if branch.id in parent.merged_children do
      {:error,
       Error.new(
         :not_open,
         "branch #{inspect(branch.id)} already merged into branch #{inspect(parent.id)}",
         %{id: branch.id, status: :merged, parent: parent.id}
       )}
    else
      :ok
    end
  end

  # The writes land in a copy of the parent that is never stored. Whatever happens, the copy is stopped.
  defp replay_in_scratch(branch, parent, opts, config) do
    scratch = Branch.scratch(parent)

    with {:ok, _pid} <- Server.start_scratch(scratch, config) do
      try do
        replay_into(scratch.id, Branch.own_entries(branch), opts)
      after
        Server.stop_scratch(scratch.id)
      end
    end
  end

  defp replay_into(id, entries, opts) do
    with {:ok, replayed} <- Ramal.run(id, fn -> replay(entries, %{}, opts) end),
         {:ok, records, count, keys, done} <- replayed,
         {:ok, scratch} <- Server.get(id) do
      {:ok, scratch, records, count, keys, done}
    end
  end

  defp parent_not_open(branch, parent_id, %Error{details: details}) do
    status = Map.get(details, :status)

    Error.new(
      :parent_not_open,
      "branch #{inspect(branch.id)} merges into branch #{inspect(parent_id)}, which is #{status}, not open; " <>
        "discard the fork",
      %{id: branch.id, parent: parent_id, status: status}
    )
  end

  defp moved_error(branch, parent_id) do
    Error.new(
      :stale,
      "parent branch #{inspect(parent_id)} was written to again while branch #{inspect(branch.id)} was merged into it; " <>
        "merge again",
      %{rows: [], parent: parent_id}
    )
  end

  # -- replay -------------------------------------------------------------------------------------------------------

  # `fetched` holds the rows the staleness check read in this transaction, locked where the data layer can lock. An
  # update or destroy takes its row from there instead of reading it again (a read per change was half the cost of a
  # merge). A row is used once, because the replay changes it. The cache is dropped for good at the first entry a hook
  # wrote (`nested?`): that hook may have changed any row, and replaying it again may change a different one.
  #
  # `renames` maps the placeholder of a row whose key the database generates to the key the replayed create got
  # (ADR 0042). Every later entry is rewritten with it before it is replayed.
  defp replay(entries, fetched, opts) do
    plans = key_plans(entries)

    entries
    |> Enum.reduce_while({:ok, Overlay.new(), [], fetched, %{}}, fn {entry, index},
                                                                    {:ok, records, done, fetched,
                                                                     renames} ->
      case replay_step(entry, index, entries, fetched, renames, {opts, plans}) do
        {:skip, fetched} ->
          {:cont, {:ok, records, done, fetched, renames}}

        {:ok, kind, ref, record, fetched, renames} ->
          done = [result_entry(entry, index, kind, ref, record) | done]
          {:cont, {:ok, record_in(records, kind, ref, record), done, fetched, renames}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, records, done, _fetched, renames} ->
        done = Enum.reverse(done)
        {:ok, records, length(done), renamed_keys(renames), done}

      {:error, _} = error ->
        error
    end
  end

  # One item of `Result.entries`: what the replay of the log entry at `index` returned, with the real key.
  defp result_entry(
         {type, resource, action, _params, _actor, _opts, _at},
         index,
         kind,
         {_resource, key},
         record
       ) do
    %{
      index: index,
      type: type,
      resource: resource,
      action: action,
      key: key,
      record: if(kind == :deleted, do: :deleted, else: record),
      metadata: metadata_of(record)
    }
  end

  defp metadata_of(%{__metadata__: metadata}) when is_map(metadata), do: metadata
  defp metadata_of(_other), do: %{}

  defp replay_step(
         {_type, _resource, _action, _params, _actor, entry_opts, _at} = entry,
         index,
         entries,
         fetched,
         renames,
         {opts, plans}
       ) do
    if entry_opts[:nested?] do
      {:skip, %{}}
    else
      entry = rename_entry(entry, renames)
      {row, fetched} = take_fetched(fetched, entry)

      case replay_entry(entry, row, opts, Map.get(plans, entry_opts[:root], [])) do
        {:ok, kind, ref, record} ->
          renames =
            renames
            |> learn_rename(entry, entry_opts, ref)
            |> Map.merge(learn_planned(Capture.take_learned_keys()))

          {:ok, kind, ref, record, forget_upserted(fetched, ref, entry_opts), renames}

        {:error, error} ->
          {:error, merge_failed(entry, index, error, written_before(entries, index))}
      end
    end
  end

  # -- placeholder keys ---------------------------------------------------------------------------------------------

  # A replayed create that had a placeholder key (`generated_key?`) was written without forcing the key, so the record
  # it returned has the real one: the placeholder maps to it from here on.
  defp learn_rename(
         renames,
         {_type, resource, _action, _params, _actor, _opts, _at},
         entry_opts,
         {resource, real}
       ) do
    if entry_opts[:generated_key?] do
      Map.put(renames, entry_opts[:key], {resource, real})
    else
      renames
    end
  end

  # The rows an entry's hooks created with a placeholder key got their real keys while the entry was replayed under its
  # key plan (`Capture.take_learned_keys/0`); a later entry that names one of them by its placeholder finds it.
  defp learn_planned(learned) do
    Map.new(learned, fn {resource, placeholder, real} -> {placeholder, {resource, real}} end)
  end

  # The placeholder values are unique within a branch (one counter, and random UUIDs), so a value names its row without
  # the resource.
  defp renamed_keys(renames) do
    for {placeholder, {resource, real}} <- renames, into: %{}, do: {{resource, placeholder}, real}
  end

  defp rename_entry(entry, renames) when renames == %{}, do: entry

  defp rename_entry({type, resource, action, params, actor, entry_opts, at}, renames) do
    entry_opts =
      case entry_opts[:key] do
        key when is_map_key(renames, key) ->
          {_resource, real} = Map.fetch!(renames, key)
          Keyword.put(entry_opts, :key, real)

        _key ->
          entry_opts
      end

    entry_opts =
      case entry_opts[:forced] do
        nil -> entry_opts
        forced -> Keyword.put(entry_opts, :forced, rename_value(forced, renames))
      end

    {type, resource, action, rename_value(params, renames), actor, entry_opts, at}
  end

  # Every value of the input that is a placeholder, whatever level of maps, lists and tuples it sits at. A key that
  # arrives as text (a form sends `"-2147483647"`) is matched as text and keeps its form. Structs are left alone.
  defp rename_value(value, renames) when is_map_key(renames, value) do
    {_resource, real} = Map.fetch!(renames, value)
    real
  end

  defp rename_value(value, renames) when is_binary(value) do
    case text_rename(value, renames) do
      {:ok, real} -> real
      :error -> value
    end
  end

  defp rename_value(%_{} = struct, _renames), do: struct

  defp rename_value(map, renames) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, rename_value(value, renames)} end)
  end

  defp rename_value(list, renames) when is_list(list),
    do: Enum.map(list, &rename_value(&1, renames))

  defp rename_value(tuple, renames) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&rename_value(&1, renames)) |> List.to_tuple()
  end

  defp rename_value(value, _renames), do: value

  defp text_rename(text, renames) do
    Enum.find_value(renames, :error, fn {placeholder, {_resource, real}} ->
      if is_integer(placeholder) and Integer.to_string(placeholder) == text,
        do: {:ok, to_text(real)}
    end)
  end

  defp to_text(real) when is_binary(real), do: real
  defp to_text(real), do: to_string(real)

  # An upsert that found its row changed it, so the copy the staleness check read is out of date.
  defp forget_upserted(fetched, ref, entry_opts) do
    case entry_opts[:upsert] do
      {_identity, _fields, true} -> Map.delete(fetched, ref)
      _not_a_found_upsert -> fetched
    end
  end

  # The keys the hooks of each outermost action created in the branch, by the action's root, in the order they ran. A
  # replay of the action creates those rows again and gives them these keys (ADR 0041). An upsert that found its row
  # in the branch has the row's own key, so the replay's upsert is to find it again and takes no key.
  defp key_plans(entries) do
    entries
    |> Enum.reduce(%{}, fn
      {{:create, resource, _action, _params, _actor, entry_opts, _at}, _index}, plans ->
        if entry_opts[:nested?] && entry_opts[:root] do
          planned = {resource, planned_key(entry_opts)}
          Map.update(plans, entry_opts[:root], [planned], &[planned | &1])
        else
          plans
        end

      _other, plans ->
        plans
    end)
    |> Map.new(fn {root, plan} -> {root, Enum.reverse(plan)} end)
  end

  # A row with a placeholder key gets no forced key: the database gives it one, and the replay learns it (ADR 0042).
  defp planned_key(entry_opts) do
    case {entry_opts[:upsert], entry_opts[:generated_key?]} do
      {{_identity, _fields, true}, _generated} -> :keep
      {_created, true} -> {:generated, entry_opts[:key]}
      {_created, _fixed} -> entry_opts[:key]
    end
  end

  defp take_fetched(fetched, {type, resource, _action, _params, _actor, entry_opts, _at})
       when type in [:update, :destroy] do
    if Ash.DataLayer.data_layer_can?(resource, {:lock, @lock}) do
      Map.pop(fetched, {resource, entry_opts[:key]})
    else
      {nil, fetched}
    end
  end

  defp take_fetched(fetched, _entry), do: {nil, fetched}

  # The resources the replay wrote to before the entry at `index` failed, restricted to the ones whose data layer has
  # no transaction to roll those writes back with.
  defp written_before(entries, index) do
    for {{_type, resource, _action, _params, _actor, entry_opts, _at}, i} <- entries,
        i < index,
        not entry_opts[:nested?],
        not Ash.DataLayer.data_layer_can?(resource, :transact),
        uniq: true,
        do: resource
  end

  defp replay_entry(
         {type, resource, action, params, recorded_actor, entry_opts, _at},
         row,
         opts,
         plan
       ) do
    key = entry_opts[:key]
    actor = if Keyword.has_key?(opts, :actor), do: opts[:actor], else: recorded_actor
    authorize? = Keyword.get(opts, :authorize?, true)
    run_opts = [actor: actor, authorize?: authorize?, tenant: entry_opts[:tenant]]

    run_opts =
      if context = opts[:context], do: Keyword.put(run_opts, :context, context), else: run_opts

    ref = {resource, key}

    case type do
      :create ->
        replay_create(resource, action, params, run_opts, entry_opts, plan)

      :update ->
        with {:ok, record} <- row_or_fetch(row, resource, key, entry_opts[:tenant]) do
          record
          |> Ash.Changeset.for_update(action, params, run_opts)
          |> force_caller_changes(entry_opts)
          |> run_planned(plan, &Ash.update(&1, run_opts))
          |> tag(:updated, ref)
        end

      :destroy ->
        with {:ok, record} <- row_or_fetch(row, resource, key, entry_opts[:tenant]) do
          destroy_opts = Keyword.put(run_opts, :return_destroyed?, true)

          record
          |> Ash.Changeset.for_destroy(action, params, run_opts)
          |> run_planned(plan, &Ash.destroy(&1, destroy_opts))
          |> tag(:deleted, ref)
        end
    end
  end

  # A create the branch logged as an upsert is replayed as one, with the identity and the fields it had in the branch.
  # It forces the key only when the branch found no row: a found row has its own key, and forcing the branch's would
  # conflict on the primary key instead of the identity. A create with a placeholder key (`generated_key?`) forces
  # nothing either: the database gives the row its key, and the record says which it is.
  defp replay_create(resource, action, params, run_opts, entry_opts, plan) do
    {run_opts, found?} =
      case entry_opts[:upsert] do
        nil ->
          {run_opts, false}

        {identity, fields, found?} ->
          {Keyword.merge(run_opts,
             upsert?: true,
             upsert_identity: identity,
             upsert_fields: fields
           ), found?}
      end

    generated? = entry_opts[:generated_key?] == true

    changeset =
      resource
      |> Ash.Changeset.for_create(action, params, run_opts)
      |> force_caller_changes(entry_opts)

    changeset =
      if found? or generated?,
        do: changeset,
        else: Resource.force_key(changeset, entry_opts[:key])

    case run_planned(changeset, plan, &Ash.create(&1, run_opts)) do
      {:ok, record} ->
        key = if generated?, do: Resource.key(resource, record), else: entry_opts[:key]
        {:ok, if(found?, do: :updated, else: :created), {resource, key}, record}

      {:error, _} = error ->
        error
    end
  end

  defp tag({:ok, record}, kind, ref), do: {:ok, kind, ref, record}
  defp tag({:error, _} = error, _kind, _ref), do: error
  defp tag(:ok, kind, ref), do: {:ok, kind, ref, nil}

  defp run_planned(changeset, plan, run),
    do: Capture.with_key_plan(plan, fn -> run.(changeset) end)

  # What the caller set on the changeset outside the action's input, as the branch recorded it.
  defp force_caller_changes(changeset, entry_opts) do
    case entry_opts[:forced] do
      nil -> changeset
      forced -> Ash.Changeset.force_change_attributes(changeset, forced)
    end
  end

  defp key_values(key) when is_tuple(key), do: Tuple.to_list(key)
  defp key_values(key), do: [key]

  defp row_or_fetch(nil, resource, key, tenant), do: fetch(resource, key, tenant)
  defp row_or_fetch(row, _resource, _key, _tenant), do: {:ok, row}

  defp fetch(resource, key, tenant) do
    identifier =
      case Info.primary_key(resource) do
        [_field] -> key
        fields -> Enum.zip(fields, key_values(key))
      end

    Ash.get(resource, identifier, authorize?: false, tenant: tenant)
  end

  defp record_in(records, :created, ref, record), do: Overlay.put_created(records, ref, record)
  defp record_in(records, :updated, ref, record), do: Overlay.put_updated(records, ref, record)
  defp record_in(records, :deleted, ref, _record), do: Overlay.put_deleted(records, ref)

  defp merge_failed(
         {type, resource, action, _params, _actor, _opts, _at},
         index,
         error,
         not_rolled_back
       ) do
    Error.new(
      :merge_failed,
      "replaying log entry #{index} (#{type} #{inspect(resource)}.#{action}) failed: #{Exception.message(error)}; " <>
        written_note(not_rolled_back) <> "the branch is still open",
      %{
        index: index,
        type: type,
        resource: resource,
        action: action,
        error: error,
        not_rolled_back: not_rolled_back
      }
    )
  end

  defp written_note([]), do: "nothing was written and "

  defp written_note(resources) do
    "the rows already replayed into #{Enum.map_join(resources, ", ", &inspect/1)} stay written, " <>
      "because its data layer cannot roll back, and "
  end

  # -- telemetry ----------------------------------------------------------------------------------------------------

  defp stop_metadata(id, domain, {:ok, %Result{} = result}) do
    %{branch_id: id, domain: domain, result: :ok, replayed: result.replayed}
  end

  defp stop_metadata(id, domain, {:error, %Error{reason: reason}}) do
    %{branch_id: id, domain: domain, result: :error, reason: reason}
  end
end
