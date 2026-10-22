defmodule Ramal.Merge do
  @moduledoc """
  Merges a branch into the base: checks that the base did not move under the branch, then replays the branch's log
  through the application's real actions inside one transaction.

  `Ramal.merge/2` is the public entry point. The steps, in order:

    1. The branch is claimed (`Ramal.Branch.Server.begin_merge/1`), which fails unless it is open and not already being
       merged.
    2. Every base row the branch fingerprinted is read again, locked (`FOR UPDATE`) where the data layer supports it,
       and compared. A row that is gone or whose fingerprint differs is stale. `on_stale` decides what happens.
    3. The log is replayed oldest first with no branch current, so every action runs for real: validations and
       policies see the base as it is now. Entries marked `nested?` are skipped, because replaying the action that
       wrote them runs their hook again.
    4. On success the branch is marked `:merged`, persisted, and its process stops. On any failure the transaction is
       rolled back and the branch stays open.

  Rows a replayed create writes keep the primary key they had in the branch (the key is forced onto the changeset), so
  later log entries and the branch's own diff still name the right rows.

  ## Options

    * `:actor` - the actor for every replayed action. Default: the actor each entry was recorded with.
    * `:authorize?` - default `true`
    * `:on_stale` - `:error` (default), `:ignore`, or a function from the stale rows to `:continue` or `:abort`
    * `:mode` - only `:replay`

  Known limits, documented in `docs/adr/0007-merge.md`: tenants are not part of the staleness check, a top-level action
  that targets a row created by a hook cannot be replayed, and changes made with `Ash.Changeset.change_attribute/3`
  outside the action's own inputs are not in the log.

  ## Example

      {:ok, %Ramal.Merge.Result{replayed: 1}} = Ramal.merge(branch, actor: current_user)
  """

  alias Ash.Resource.Info
  alias Ramal.Branch.Server
  alias Ramal.{Current, Error, Overlay, Resource}
  alias Ramal.Merge.Result

  @lock :for_update

  @doc """
  Merges the branch with `id`. See the module doc for the steps and the options.

  Returns `{:error, %Ramal.Error{reason: :stale}}` with the stale rows in `details.rows`, `:merge_failed` with the log
  index, resource, action and Ash error in `details` when a replayed action fails, `:not_open` for a merged,
  discarded or already-merging branch, and `:nested_branch` when called inside `Ramal.run/2`.

  ## Example

      {:error, %Ramal.Error{reason: :stale, details: %{rows: rows}}} = Ramal.merge(branch)
  """
  @spec run(String.t(), keyword) :: {:ok, Result.t()} | {:error, Error.t()}
  def run(id, opts \\ []) when is_binary(id) do
    opts = validate!(opts)

    with :ok <- ensure_outside_branch(id),
         {:ok, branch} <- Server.get(id) do
      :telemetry.span([:ramal, :merge], %{branch_id: id, domain: branch.domain}, fn ->
        result = claim_and_merge(id, opts)
        {result, stop_metadata(id, branch, result)}
      end)
    end
  end

  defp validate!(opts) do
    unless Keyword.get(opts, :mode, :replay) == :replay do
      raise ArgumentError,
            "Ramal.merge/2 only supports `mode: :replay`, got: #{inspect(opts[:mode])}"
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

  defp claim_and_merge(id, opts) do
    with {:ok, branch} <- Server.begin_merge(id),
         {:ok, result} <- merge_or_release(id, branch, opts),
         :ok <- Server.finish_merge(id, :merged) do
      {:ok, result}
    end
  end

  # The claim is released on every way out except success, so a failed or crashed merge leaves the branch open.
  defp merge_or_release(id, branch, opts) do
    case merge(branch, opts) do
      {:ok, _result} = ok ->
        ok

      {:error, _} = error ->
        Server.finish_merge(id, :aborted)
        error
    end
  catch
    kind, reason ->
      Server.finish_merge(id, :aborted)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp merge(branch, opts) do
    entries = branch.log |> Enum.reverse() |> Enum.with_index()

    resources =
      entries
      |> Enum.map(fn {{_type, resource, _action, _input, _actor, _opts, _at}, _index} ->
        resource
      end)
      |> Enum.concat(for {{resource, _key}, _row} <- branch.base, do: resource)
      |> Enum.uniq()

    resources
    |> Ash.transact(fn ->
      with {:ok, stale} <- check_staleness(branch, opts),
           {:ok, records, replayed} <- replay(entries, opts) do
        {stale, records, replayed}
      end
    end)
    |> case do
      {:ok, {stale, records, replayed}} ->
        {:ok,
         %Result{
           branch: %{branch | status: :merged},
           records: records,
           replayed: replayed,
           stale: stale
         }}

      {:error, error} ->
        {:error,
         Error.find(error) || Error.new(:merge_failed, Exception.message(error), %{error: error})}
    end
  end

  # -- staleness ----------------------------------------------------------------------------------------------------

  defp check_staleness(branch, opts) do
    rows = stale_rows(branch)

    case {rows, Keyword.get(opts, :on_stale, :error)} do
      {[], _} -> {:ok, []}
      {_, :ignore} -> {:ok, rows}
      {_, :error} -> {:error, stale_error(rows)}
      {_, fun} -> if fun.(rows) == :continue, do: {:ok, rows}, else: {:error, stale_error(rows)}
    end
  end

  defp stale_rows(branch) do
    branch.base
    |> Enum.filter(fn {_ref, row} -> row.fingerprint != nil end)
    |> Enum.group_by(fn {{resource, _key}, _row} -> resource end, fn {{_resource, key}, row} ->
      {key, row.fingerprint}
    end)
    |> Enum.flat_map(fn {resource, expected} -> stale_in(resource, Map.new(expected)) end)
    |> Enum.sort_by(&{inspect(&1.resource), &1.key})
  end

  defp stale_in(resource, expected) do
    current =
      resource
      |> Ash.Query.new()
      |> filter_keys(resource, Map.keys(expected))
      |> lock()
      |> Ash.read!(authorize?: false)
      |> Map.new(&{Resource.key(resource, &1), Resource.fingerprint(&1)})

    for {key, fingerprint} <- expected,
        reason = staleness(Map.fetch(current, key), fingerprint),
        do: %{resource: resource, key: key, reason: reason}
  end

  defp staleness(:error, _expected), do: :deleted
  defp staleness({:ok, fingerprint}, fingerprint), do: nil
  defp staleness({:ok, _other}, _expected), do: :changed

  defp filter_keys(query, resource, keys) do
    case Info.primary_key(resource) do
      [field] ->
        Ash.Query.do_filter(query, [{field, [in: keys]}])

      fields ->
        Ash.Query.do_filter(query, or: Enum.map(keys, &Enum.zip(fields, Tuple.to_list(&1))))
    end
  end

  defp lock(query) do
    if Ash.DataLayer.data_layer_can?(query.resource, {:lock, @lock}) do
      Ash.Query.lock(query, @lock)
    else
      query
    end
  end

  defp stale_error(rows) do
    Error.new(
      :stale,
      "#{length(rows)} row(s) changed in the base since the branch first saw them: " <>
        Enum.map_join(rows, ", ", &"#{inspect(&1.resource)} #{inspect(&1.key)} (#{&1.reason})") <>
        "; pass `on_stale: :ignore` to merge anyway",
      %{rows: rows}
    )
  end

  # -- replay -------------------------------------------------------------------------------------------------------

  defp replay(entries, opts) do
    entries
    |> Enum.reject(fn {{_type, _resource, _action, _input, _actor, entry_opts, _at}, _index} ->
      entry_opts[:nested?]
    end)
    |> Enum.reduce_while({:ok, Overlay.new(), 0}, fn {entry, index}, {:ok, records, count} ->
      case replay_entry(entry, opts) do
        {:ok, kind, ref, record} ->
          {:cont, {:ok, record_in(records, kind, ref, record), count + 1}}

        {:error, error} ->
          {:halt, {:error, merge_failed(entry, index, error)}}
      end
    end)
  end

  defp replay_entry({type, resource, action, params, recorded_actor, entry_opts, _at}, opts) do
    key = entry_opts[:key]
    actor = if Keyword.has_key?(opts, :actor), do: opts[:actor], else: recorded_actor
    authorize? = Keyword.get(opts, :authorize?, true)
    run_opts = [actor: actor, authorize?: authorize?, tenant: entry_opts[:tenant]]
    ref = {resource, key}

    case type do
      :create ->
        resource
        |> Ash.Changeset.for_create(action, params, run_opts)
        |> force_key(resource, key)
        |> Ash.create(run_opts)
        |> tag(:created, ref)

      :update ->
        with {:ok, record} <- fetch(resource, key, entry_opts[:tenant]) do
          record
          |> Ash.Changeset.for_update(action, params, run_opts)
          |> Ash.update(run_opts)
          |> tag(:updated, ref)
        end

      :destroy ->
        with {:ok, record} <- fetch(resource, key, entry_opts[:tenant]) do
          record
          |> Ash.Changeset.for_destroy(action, params, run_opts)
          |> Ash.destroy(Keyword.put(run_opts, :return_destroyed?, true))
          |> tag(:deleted, ref)
        end
    end
  end

  defp tag({:ok, record}, kind, ref), do: {:ok, kind, ref, record}
  defp tag({:error, _} = error, _kind, _ref), do: error
  defp tag(:ok, kind, ref), do: {:ok, kind, ref, nil}

  defp force_key(changeset, resource, key) do
    resource
    |> Info.primary_key()
    |> Enum.zip(key_values(key))
    |> Enum.reduce(changeset, fn {field, value}, changeset ->
      Ash.Changeset.force_change_attribute(changeset, field, value)
    end)
  end

  defp key_values(key) when is_tuple(key), do: Tuple.to_list(key)
  defp key_values(key), do: [key]

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

  defp merge_failed({type, resource, action, _params, _actor, _opts, _at}, index, error) do
    Error.new(
      :merge_failed,
      "replaying log entry #{index} (#{type} #{inspect(resource)}.#{action}) failed: #{Exception.message(error)}; " <>
        "nothing was written and the branch is still open",
      %{index: index, type: type, resource: resource, action: action, error: error}
    )
  end

  # -- telemetry ----------------------------------------------------------------------------------------------------

  defp stop_metadata(id, branch, {:ok, %Result{} = result}) do
    %{branch_id: id, domain: branch.domain, result: :ok, replayed: result.replayed}
  end

  defp stop_metadata(id, branch, {:error, %Error{reason: reason}}) do
    %{branch_id: id, domain: branch.domain, result: :error, reason: reason}
  end
end
