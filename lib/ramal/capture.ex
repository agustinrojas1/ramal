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

  alias Ash.Resource.Info
  alias Ramal.{Branch, Current, Error, Resource, Telemetry}
  alias Ramal.Branch.Server

  @frame :ramal_capture_frame
  @bulk_markers [:bulk_create, :bulk_update, :bulk_destroy]

  @impl true
  def change(changeset, _opts, _context) do
    case Current.resolve(changeset.context) do
      nil -> changeset
      id -> capture(changeset, id)
    end
  end

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

  defp capture(changeset, id) do
    cond do
      Enum.any?(@bulk_markers, &Map.has_key?(changeset.context, &1)) ->
        Ash.Changeset.add_error(changeset, bulk_error(changeset))

      changeset.context[:private][:upsert?] ->
        Ash.Changeset.add_error(changeset, upsert_error(changeset))

      true ->
        changeset
        |> Ash.Changeset.set_context(Current.shared_context(id))
        |> Ash.Changeset.around_action(&around(&1, &2, id))
    end
  end

  # The frame counts how deeply captured actions nest in this process and keeps the undo records of their writes.
  defp around(changeset, callback, id) do
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
      leave()
    end
  end

  defp succeeded?(result), do: is_tuple(result) and elem(result, 0) == :ok

  defp rollback(id, mark, result) do
    frame = Process.get(@frame)
    {mine, rest} = Enum.split(frame.undos, length(frame.undos) - mark)
    Process.put(@frame, %{frame | undos: rest})
    if mine != [], do: Server.update(id, &Branch.undo(&1, mine))
    result
  end

  defp leave do
    case Process.get(@frame) do
      %{depth: 1} -> Process.delete(@frame)
      frame -> Process.put(@frame, %{frame | depth: frame.depth - 1})
    end
  end

  defp write(changeset, id, nested?) do
    case written(changeset) do
      {:skip, record} ->
        Ash.Changeset.set_result(changeset, {:ok, record})

      {:ok, kind, record, base_row} ->
        resource = changeset.resource
        key = Resource.key(resource, record)
        entry = log_entry(changeset, key, nested?)

        put = fn branch ->
          {branch, undo} =
            Branch.put_write(branch, kind, {resource, key}, record, base_row, entry)

          {undo, branch}
        end

        case Server.write(id, put) do
          {:ok, undo, summary} ->
            remember(undo)
            emit(summary, changeset, nested?)
            Ash.Changeset.set_result(changeset, {:ok, result_record(kind, record, resource)})

          {:error, %Error{} = error} ->
            Ash.Changeset.add_error(changeset, error)
        end

      {:error, %Error{} = error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp written(%{action_type: :create} = changeset) do
    {:ok, record} = Ash.Changeset.apply_attributes(changeset)

    if Enum.all?(Info.primary_key(changeset.resource), &(Map.get(record, &1) != nil)) do
      {:ok, :created, record, nil}
    else
      {:error, key_error(changeset)}
    end
  end

  defp written(%{action_type: :update} = changeset) do
    if Ash.Changeset.changing_attributes?(changeset) do
      {:ok, record} = Ash.Changeset.apply_attributes(changeset)
      {:ok, :updated, record, base_row(changeset.data)}
    else
      # Ash does not call the data layer for an update that changes nothing, and neither do we.
      {:skip, changeset.data}
    end
  end

  defp written(%{action_type: :destroy} = changeset) do
    {:ok, :deleted, changeset.data, base_row(changeset.data)}
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

  defp key_error(changeset) do
    Error.new(
      :database_generated_key,
      "#{inspect(changeset.resource)} has no value for its primary key after the #{changeset.action.name} action, " <>
        "so it is generated by the database and a branch cannot create the row; give the key a default such as uuid_primary_key",
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

  defp upsert_error(changeset) do
    Error.new(
      :upsert_unsupported,
      "#{inspect(changeset.resource)}.#{changeset.action.name} is an upsert; a branch cannot know whether the row " <>
        "exists in the base, so create or update the row explicitly",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end
end
