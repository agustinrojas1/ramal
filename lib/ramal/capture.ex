defmodule Ramal.Capture do
  @moduledoc """
  The change `Ramal.Resource` installs on every create, update and destroy action.

  Inside `Ramal.run/2` it replaces "write this row to the data layer" with "put this row in the branch's overlay".
  Everything else about the action still happens: argument casting, validations, policies, defaults, timestamps and
  the action's own `before_action` and `after_action` hooks. Outside a branch it does nothing.

  What the action returns is what the action would have returned: a created or updated record, or the destroyed one.
  The write is also appended to the branch log so that `Ramal.merge/2` can replay the action later.

  How it works, confirmed against Ash 3.37 (`lib/ash/changeset/changeset.ex` and `lib/ash/actions/*`):

    * `Ash.Changeset.around_action/3` wraps the before-action hooks, the data-layer call and the after-action hooks.
      The around hook adds one more `before_action`, so that it is the last of them and sees the changeset as every
      other hook left it.
    * That hook builds the record with `Ash.Changeset.apply_attributes/2`, which also applies defaults, and calls
      `Ash.Changeset.set_result/2`. The create, update and destroy actions skip the data layer when a result is set
      and carry on with relationship management and the after-action hooks.
    * An update runs `fully_atomic_changeset` first and, when it succeeds, updates the row in the database without
      calling any hook. `atomic/3` therefore reports `{:not_atomic, reason}` while a branch is current, and
      the resource transformer sets `require_atomic? false` so Ash falls back to the path above.
    * Bulk actions call the data layer directly and never look at the result, so they are refused. Upserts too:
      the branch cannot know whether the row exists in the base.

  A failed action leaves the branch as it found it: the writes of the action and of the actions its hooks ran are
  taken back. A write made by a hook of another captured action is logged with `nested?: true`, because replaying the
  outer action runs the hook again.

  ## Example

      {:ok, branch} = Ramal.branch(MyApp.Farm)

      Ramal.run!(branch, fn ->
        herd = Ash.create!(MyApp.Farm.Herd, %{name: "R7", head: 40})
        Ash.destroy!(herd)
      end)
      # The database was not written; the branch log holds the create and the destroy.
  """
  use Ash.Resource.Change

  alias Ash.Error.Changes.StaleRecord
  alias Ash.Resource.Info
  alias Ramal.{Branch, Current, Error, Resource, Telemetry}
  alias Ramal.Branch.Server

  @frame :ramal_capture_frame
  @bulk_markers [:bulk_create, :bulk_update, :bulk_destroy]

  @impl true
  def change(changeset, _opts, _context) do
    case Current.bind(changeset.context) do
      :none ->
        guard(changeset)

      {:ok, id, origin} ->
        capture(changeset, id, origin)

      {:conflict, process, carried} ->
        Ash.Changeset.add_error(changeset, Current.conflict(what(changeset), process, carried))
    end
  end

  # The branch is decided here, when the changeset is built, so a changeset built outside a branch and run inside one
  # would write to the database. The hook costs one process dictionary read when no branch is current (ADR 0026).
  defp guard(changeset) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Current.verify(nil, nil, what(changeset)) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  defp what(changeset),
    do:
      "the #{changeset.action.name} #{changeset.action_type} changeset of #{inspect(changeset.resource)}"

  @impl true
  def atomic(changeset, _opts, _context) do
    case Current.resolve(changeset.context) do
      nil ->
        {:ok, changeset}

      _id ->
        {:not_atomic,
         "a Ramal branch is current, so the write is captured instead of run in the database"}
    end
  end

  defp capture(changeset, id, origin) do
    cond do
      Enum.any?(@bulk_markers, &Map.has_key?(changeset.context, &1)) ->
        Ash.Changeset.add_error(changeset, bulk_error(changeset))

      changeset.context[:private][:upsert?] ->
        Ash.Changeset.add_error(changeset, upsert_error(changeset))

      true ->
        install(changeset, id, origin)
    end
  end

  defp install(changeset, id, origin) do
    case Resource.ensure_untenanted(changeset.resource, changeset.tenant) do
      :ok ->
        changeset
        |> Ash.Changeset.set_context(Current.shared_context(id))
        |> Ash.Changeset.around_action(&around(&1, &2, id, origin))

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # The frame counts how deeply captured actions nest in this process and keeps the undo records of their writes.
  defp around(changeset, callback, id, origin) do
    with :ok <- Current.verify(id, origin, what(changeset)),
         :ok <- ensure_not_in_task(changeset) do
      run_captured(changeset, callback, id)
    end
  end

  # A task started by a hook of a captured action runs while that action is open in its parent. Its write would be
  # logged on its own, and replaying the outer action runs the hook, and so the task, a second time (ADR 0026).
  defp ensure_not_in_task(changeset) do
    case {Process.get(@frame), Current.inherited(@frame)} do
      {nil, %{depth: depth}} when depth > 0 ->
        {:error,
         Error.new(
           :task_in_action,
           "#{what(changeset)} runs in a task started inside another captured action; replaying that action would run " <>
             "the task again, so write from the hook itself, not from a task it starts",
           %{resource: changeset.resource, action: changeset.action.name}
         )}

      _ ->
        :ok
    end
  end

  defp run_captured(changeset, callback, id) do
    frame = Process.get(@frame, %{depth: 0, undos: []})
    nested? = frame.depth > 0
    mark = length(frame.undos)
    Process.put(@frame, %{frame | depth: frame.depth + 1})
    changeset = Ash.Changeset.before_action(changeset, &write(&1, id, nested?))

    try do
      result = callback.(changeset)
      if succeeded?(result), do: result, else: rollback(id, mark, result)
    catch
      kind, reason ->
        rollback(id, mark, :raised)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      leave(id)
    end
  end

  defp succeeded?(result), do: is_tuple(result) and elem(result, 0) == :ok

  defp rollback(id, mark, result) do
    frame = Process.get(@frame)
    {mine, rest} = Enum.split(frame.undos, length(frame.undos) - mark)
    Process.put(@frame, %{frame | undos: rest})
    if mine != [], do: Server.undo(id, mine)
    result
  end

  # The outermost action ended: the branch process holds its writes as running until told (`Server.capture/3`). A
  # frame whose writes were all taken back has none left to end.
  defp leave(id) do
    case Process.get(@frame) do
      %{depth: 1, undos: undos} ->
        Process.delete(@frame)
        if undos != [], do: Server.release(id)

      frame ->
        Process.put(@frame, %{frame | depth: frame.depth - 1})
    end
  end

  defp write(changeset, id, nested?) do
    with {:ok, held} <- held_record(changeset, id),
         {:ok, changeset} <- complete(changeset, held, id),
         {:ok, kind, record, base_row} <- written(changeset, held) do
      resource = changeset.resource
      key = Resource.key(resource, record)
      entry = log_entry(changeset, key, nested?)

      # If the call times out the process may still carry the write out, with no one left to remember how to undo it, so
      # the write sends its undo to this process as well; see `settle_late_write/2`.
      tag = make_ref()
      caller = self()

      put = fn branch ->
        {reply, branch} = put_write(branch, kind, {resource, key}, record, base_row, entry)
        send(caller, {tag, reply})
        {reply, branch}
      end

      result = Server.capture(id, {resource, key}, put)
      settle_late_write(result, id, tag)

      case result do
        {:ok, {:ok, undo}, summary} ->
          remember(undo)
          emit(summary, changeset, nested?)

          changeset
          |> Ash.Changeset.set_result({:ok, result_record(kind, record, resource)})
          |> settle_foreign_keys(id, {resource, key})

        {:ok, {:error, :destroyed}, _summary} ->
          Ash.Changeset.add_error(changeset, stale_error(changeset, key))

        {:error, %Error{} = error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    else
      {:error, %Error{} = error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # A write that timed out is taken back. The process handles requests in order, so once it answers a later request it
  # has handled the write too, and the undo it sent is in the mailbox if it was made. After a write that was answered
  # the message is only discarded.
  defp settle_late_write({:error, %Error{reason: :timeout}}, id, tag) do
    with :ok <- Server.settle(id) do
      receive do
        {^tag, {:ok, undo}} -> Server.undo(id, [undo])
        {^tag, _refused} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp settle_late_write(_result, _id, tag) do
    receive do
      {^tag, _reply} -> :ok
    after
      0 -> :ok
    end
  end

  # A create sets the foreign key of a managed `belongs_to` after the before-action hooks (`setup_managed_belongs_to_
  # relationships` in `lib/ash/actions/create/create.ex`, Ash 3.37), which is after the record was built here. The
  # after-action hooks get the changeset as it stands then, so the key is read from it and copied onto the record the
  # action returns and onto the overlay's. An update registers that step as a before-action hook before this one
  # (`lib/ash/actions/update/update.ex`), so it needs nothing.
  defp settle_foreign_keys(%{action_type: :create} = changeset, id, ref) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      case changed_foreign_keys(changeset, result) do
        keys when keys == %{} -> {:ok, result}
        keys -> put_foreign_keys(id, ref, result, keys)
      end
    end)
  end

  defp settle_foreign_keys(changeset, _id, _ref), do: changeset

  defp changed_foreign_keys(changeset, result) do
    {:ok, built} = Ash.Changeset.apply_attributes(changeset)

    for %{type: :belongs_to, source_attribute: attribute} <-
          Info.relationships(changeset.resource),
        Map.get(built, attribute) != Map.get(result, attribute),
        into: %{},
        do: {attribute, Map.get(built, attribute)}
  end

  defp put_foreign_keys(id, ref, result, keys) do
    patch = fn branch ->
      case Map.get(branch.overlay, ref) do
        {kind, held} ->
          {:ok, %{branch | overlay: Map.put(branch.overlay, ref, {kind, Map.merge(held, keys)})}}

        _gone ->
          {:ok, branch}
      end
    end

    with {:ok, _ok, _summary} <- Server.write(id, patch), do: {:ok, Map.merge(result, keys)}
  end

  # The row as the branch holds it, for an update. The record an update is called with is often older than the branch's
  # copy (a struct read before an earlier update in the same branch), and the data layer would write only the changed
  # attributes onto the row that is there, so the changes go onto the branch's copy and not onto the stale struct.
  defp held_record(%{action_type: :update} = changeset, id) do
    ref = {changeset.resource, Resource.key(changeset.resource, changeset.data)}

    case Server.write(id, fn branch -> {Map.get(branch.overlay, ref), branch} end) do
      {:ok, {_kind, record}, _summary} -> {:ok, record}
      {:ok, _none_or_deleted, _summary} -> {:ok, nil}
      {:error, %Error{}} = error -> error
    end
  end

  defp held_record(_changeset, _id), do: {:ok, nil}

  # An update or destroy called with a struct that was read with `Ash.Query.select/2` has attributes that are not
  # loaded. Stored as it is, the overlay would hold a partial record (later reads return `NotLoaded` attributes) and its
  # base row would have no fingerprint (ADR 0006), so the staleness check would skip it. When the branch holds no copy
  # the full row is read through the patched read, as the data layer would have it, and the action goes on with that.
  # A row that cannot be found is left as it is: the destroyed-row check in `put_write/6` answers it.
  defp complete(%{action_type: type} = changeset, nil, id) when type in [:update, :destroy] do
    if Resource.fingerprint(changeset.data) do
      {:ok, changeset}
    else
      resource = changeset.resource
      key = changeset.data |> Map.take(Info.primary_key(resource))

      case Ash.get(resource, key,
             authorize?: false,
             tenant: changeset.tenant,
             context: Current.shared_context(id),
             not_found_error?: false
           ) do
        {:ok, %{} = full} -> {:ok, %{changeset | data: full}}
        {:ok, nil} -> {:ok, changeset}
        {:error, error} -> {:error, partial_error(changeset, error)}
      end
    end
  end

  defp complete(changeset, _held, _id), do: {:ok, changeset}

  # Updating or destroying a row the branch already destroyed is what the data layer refuses on the real base:
  # AshPostgres answers `StaleRecord` when its UPDATE or DELETE touches no row (`update/2` and `destroy/2` in
  # `lib/data_layer.ex`, AshPostgres 2.15). Taking it would bring the row back (an update) or log a second destroy,
  # and a merge replays both against a row that is not there.
  defp put_write(branch, kind, ref, record, base_row, entry) do
    if kind != :created and Map.get(branch.overlay, ref) == :deleted do
      {{:error, :destroyed}, branch}
    else
      {branch, undo} = Branch.put_write(branch, kind, ref, record, base_row, entry)
      {{:ok, undo}, branch}
    end
  end

  defp written(%{action_type: :create} = changeset, _held) do
    {:ok, record} = Ash.Changeset.apply_attributes(changeset)

    if Enum.all?(Info.primary_key(changeset.resource), &(Map.get(record, &1) != nil)) do
      {:ok, :created, record, nil}
    else
      {:error, key_error(changeset)}
    end
  end

  # An update that changes no attribute is still logged: its hooks and managed relationships can write other rows, and
  # those writes are logged as nested, so only replaying this action brings them back. The overlay keeps the row as it
  # was (Ash does not write it either, so `updated_at` stays) and `Ramal.diff/1` leaves it out.
  defp written(%{action_type: :update} = changeset, held) do
    original = changeset.data
    changeset = if held, do: %{changeset | data: held}, else: changeset

    record =
      if Ash.Changeset.changing_attributes?(changeset) do
        {:ok, record} = Ash.Changeset.apply_attributes(changeset)
        record
      else
        changeset.data
      end

    with {:ok, record} <- apply_atomics(changeset, record) do
      {:ok, :updated, record, base_row(original)}
    end
  end

  defp written(%{action_type: :destroy} = changeset, _held) do
    {:ok, :deleted, changeset.data, base_row(changeset.data)}
  end

  # `atomic_update` (the change, or `Ash.Changeset.atomic_update/3`) leaves an expression in `changeset.atomics` that
  # the data layer evaluates against the row, and `apply_attributes/2` does not look at it. Evaluating it here, against
  # the row with the attribute changes applied, is what `Ash.DataLayer.Ets` does (`make_atomics/4` in
  # `lib/ash/data_layer/ets/ets.ex`, Ash 3.37). An expression that needs the database (`:unknown`) fails the action
  # instead of being dropped, because a dropped one makes the branch disagree with the merge.
  defp apply_atomics(%{atomics: []}, record), do: {:ok, record}

  defp apply_atomics(%{atomics: atomics} = changeset, record) do
    Enum.reduce_while(atomics, {:ok, record}, fn {name, expr}, {:ok, acc} ->
      case evaluate(changeset, expr, record) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        :error -> {:halt, {:error, atomic_error(changeset, name)}}
      end
    end)
  end

  defp evaluate(changeset, expr, record) do
    case Ash.Expr.eval(expr,
           resource: changeset.resource,
           record: record,
           domain: changeset.domain,
           unknown_on_unknown_refs?: true
         ) do
      {:ok, value} -> {:ok, value}
      _unknown_or_error -> :error
    end
  end

  defp base_row(record) do
    %{fingerprint: Resource.fingerprint(record), snapshot: record}
  end

  defp result_record(:deleted, record, resource), do: put_state(record, resource, :deleted)
  defp result_record(_kind, record, resource), do: put_state(record, resource, :loaded)

  defp put_state(record, resource, state) do
    Ash.Resource.set_meta(record, %Ecto.Schema.Metadata{state: state, schema: resource})
  end

  # Log order is capture order, and the opts carry what replay needs to find the row again.
  defp log_entry(changeset, key, nested?) do
    {changeset.action_type, changeset.resource, changeset.action.name, changeset.params,
     changeset.context[:private][:actor], [key: key, tenant: changeset.tenant, nested?: nested?],
     DateTime.utc_now()}
  end

  defp remember(undo) do
    frame = Process.get(@frame)
    Process.put(@frame, %{frame | undos: [undo | frame.undos]})
  end

  defp emit(summary, changeset, nested?) do
    Telemetry.write(:capture, summary, %{
      action_type: changeset.action_type,
      resource: changeset.resource,
      action: changeset.action.name,
      nested?: nested?
    })
  end

  defp stale_error(changeset, key) do
    StaleRecord.exception(
      resource: changeset.resource,
      filter: Enum.zip(Info.primary_key(changeset.resource), key_values(key))
    )
  end

  defp key_values(key) when is_tuple(key), do: Tuple.to_list(key)
  defp key_values(key), do: [key]

  defp key_error(changeset) do
    Error.new(
      :database_generated_key,
      "#{inspect(changeset.resource)} has no value for its primary key after the #{changeset.action.name} action, " <>
        "so it is generated by the database and a branch cannot create the row; give the key a default such as uuid_primary_key",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end

  defp partial_error(changeset, cause) do
    Error.new(
      :partial_record,
      "#{inspect(changeset.resource)}.#{changeset.action.name} was called with a record that has attributes that are not " <>
        "loaded, and the full row could not be read inside the branch (#{Exception.message(cause)}); " <>
        "read the record without Ash.Query.select/2 and try again",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end

  defp bulk_error(changeset) do
    Error.new(
      :bulk_unsupported,
      "#{inspect(changeset.resource)}.#{changeset.action.name} ran as a bulk action inside a branch; bulk actions " <>
        "write through the data layer without calling the capture hook, so call the action once per record instead",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end

  defp atomic_error(changeset, attribute) do
    Error.new(
      :atomic_unsupported,
      "#{inspect(changeset.resource)}.#{changeset.action.name} sets #{attribute} with an atomic expression that cannot " <>
        "be evaluated without the database, so a branch cannot apply it; set the attribute with a plain change instead",
      %{resource: changeset.resource, action: changeset.action.name, attribute: attribute}
    )
  end

  defp upsert_error(changeset) do
    Error.new(
      :upsert_unsupported,
      "#{inspect(changeset.resource)}.#{changeset.action.name} is an upsert; a branch cannot know whether the row " <>
        "exists in the base, so create or update the row explicitly",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end
end
