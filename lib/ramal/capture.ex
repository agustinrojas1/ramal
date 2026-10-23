defmodule Ramal.Capture do
  @moduledoc """
  The change `Ramal.Resource` installs on every create, update and destroy action.

  Inside `Ramal.run/2` it replaces "write this row to the data layer" with "put this row in the branch's overlay".
  Everything else about the action still happens: argument casting, validations, policies, defaults, timestamps and
  the action's own `before_action` and `after_action` hooks. Outside a branch it does nothing.

  What the action returns is what the action would have returned: a created or updated record, or the destroyed one.
  The write is also appended to the branch log so that `Ramal.merge/2` can replay the action later. The entry records
  what the replay cannot get from the action's input: the `root` it shares with the writes of its hooks and the
  attributes the caller set on the changeset after building it (`forced`), both in ADR 0041.

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
    * A bulk action runs a changeset that has an `around_action` hook one record at a time, through the same create,
      update or destroy as a single action (`split_and_run_simple/7` in `lib/ash/actions/helpers.ex`, called from
      `lib/ash/actions/{create,update,destroy}/bulk.ex`). The hook above is that `around_action`, so inside a branch
      every record of `Ash.bulk_create/4`, `Ash.bulk_update/4` and `Ash.bulk_destroy/4` is captured and logged as its
      own action, and the data layer's bulk call gets no records. A bulk update or destroy of a query picks its
      strategy before that: the atomic ones are refused through `atomic/3`, so the caller must allow `:stream`.
    * An upsert is decided in the branch's view (ADR 0038). `Ash.Actions.Create.do_run/4` sets
      `context.private.upsert?` to `true` for every create (`lib/ash/actions/create/create.ex`, Ash 3.37), so by the time
      a `before_action` hook runs the flag says nothing; `change/3` runs while the changeset is built, where the flag
      is the action's own `upsert?`, an `upsert?: true` given to `Ash.Changeset.for_create/4`, or the one the bulk
      path sets for each changeset. The write hook then looks the row up by the upsert identity with a patched read.
      A row found is updated with the upsert fields (`upsert/4` in AshPostgres 2.15 `lib/data_layer.ex`: the attributes
      the changeset set, without defaults and conflict keys, plus the update defaults); with none found the create goes
      on as it is. An `upsert_condition` is a filter the database evaluates against the existing row, which a branch
      cannot, so it is refused. A call-time `Ash.create(changeset, upsert?: true)` reaches only `do_run/4`'s options,
      which no hook sees, and acts as a plain create.
    * A create whose single `generated? true` primary key is `nil` after `apply_attributes/2` (the `INSERT` would give
      it) gets a placeholder key from `Ramal.Branch.placeholder/2`, and its log entry says `generated_key?: true`; the
      merge renames the placeholder to the key the database gives the row (ADR 0042).

  A failed action leaves the branch as it found it: the writes of the action and of the actions its hooks ran are
  taken back. A write made by a hook of another captured action is logged with `nested?: true`, because replaying the
  outer action runs the hook again.

  In a durable branch (ADR 0048) the outermost action's end is a call: the branch process appends the writes of the
  action to the storage's write log and the action returns once they are stored. An append that fails fails the action
  with `:storage`, and its writes are taken back like those of any failed action. An action that failed or raised
  appends nothing.

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
  @key_plan :ramal_key_plan
  @learned_keys :ramal_learned_keys
  @wrapped :ramal_wrapped

  @impl true
  def change(changeset, _opts, _context) do
    case Current.bind(changeset.context) do
      :none ->
        guard(changeset)

      {:ok, id, origin} ->
        # The replay of a nested fork's entries runs in a branch (a scratch copy of the parent), so its hooks' creates
        # take their planned keys here as they do when the merge writes to the database (ADR 0043).
        capture(planned_key(changeset), id, origin)

      {:conflict, process, carried} ->
        Ash.Changeset.add_error(changeset, Current.conflict(what(changeset), process, carried))
    end
  end

  # The branch is decided here, when the changeset is built, so a changeset built outside a branch and run inside one
  # would write to the database. The hook costs one process dictionary read when no branch is current (ADR 0026).
  defp guard(changeset) do
    changeset = planned_key(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case Current.verify(nil, nil, what(changeset)) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  @doc false
  # Runs `fun` with the keys the branch gave the rows that the entry being replayed made its hooks create, in the order
  # it made them (`Ramal.Merge`). The next create of the plan's resource takes the next key, so a later entry that names
  # the row by key finds it. A create of another resource ends the plan: the hook does not do what it did in the
  # branch, and the rows get the keys they are given.
  @spec with_key_plan([{module, term}], (-> result)) :: result when result: var
  def with_key_plan([], fun), do: fun.()

  def with_key_plan(plan, fun) do
    Process.put(@key_plan, plan)
    Process.delete(@learned_keys)

    try do
      fun.()
    after
      Process.delete(@key_plan)
    end
  end

  @doc false
  # The real keys that the creates of a key plan got for the placeholders they were planned with, as
  # `{resource, placeholder, real_key}` in the order they were created, and forgets them (ADR 0042).
  @spec take_learned_keys() :: [{module, term, term}]
  def take_learned_keys, do: @learned_keys |> Process.delete() |> List.wrap() |> Enum.reverse()

  defp planned_key(%{action_type: :create} = changeset) do
    case Process.get(@key_plan) do
      [{resource, {:generated, placeholder}} | rest] when resource == changeset.resource ->
        Process.put(@key_plan, rest)
        learn_key(changeset, placeholder)

      [{resource, :keep} | rest] when resource == changeset.resource ->
        Process.put(@key_plan, rest)
        changeset

      [{resource, key} | rest] when resource == changeset.resource ->
        Process.put(@key_plan, rest)
        Resource.force_key(changeset, key)

      [_other | _rest] ->
        Process.delete(@key_plan)
        changeset

      _no_plan ->
        changeset
    end
  end

  defp planned_key(changeset), do: changeset

  # The key is the database's to give, so nothing is forced; once the row is created its key is the placeholder's.
  defp learn_key(changeset, placeholder) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      real = Resource.key(record.__struct__, record)

      Process.put(@learned_keys, [
        {record.__struct__, placeholder, real} | Process.get(@learned_keys, [])
      ])

      {:ok, record}
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
         "a Ramal branch is current, so the write is captured instead of run in the database; " <>
           "a bulk update or destroy inside a branch runs record by record, so allow `strategy: [:atomic, :stream]`"}
    end
  end

  defp capture(changeset, id, origin) do
    if upsert?(changeset) and changeset.context[:private][:upsert_condition] != nil do
      Ash.Changeset.add_error(changeset, upsert_condition_error(changeset))
    else
      install(changeset, id, origin)
    end
  end

  defp upsert?(changeset),
    do: changeset.action_type == :create and changeset.context[:private][:upsert?] == true

  defp install(changeset, id, origin) do
    case Resource.ensure_tenant(changeset.resource, changeset.tenant, id) do
      :ok ->
        upsert? = upsert?(changeset)

        changeset
        |> Ash.Changeset.set_context(Current.shared_context(id))
        |> record_caller_changes()
        |> Ash.Changeset.around_action(&around(&1, &2, id, origin, upsert?))
        |> Ash.Changeset.before_action(&ensure_wrapped/1)

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  # This change is the last of the action's (global changes run after the action's own: `run_action_changes/6` in
  # `lib/ash/changeset/changeset.ex`, Ash 3.37), so the attributes now are what the action did with its input. Whatever
  # differs when the first `before_action` hook runs was set by the caller between `for_create` or `for_update` and
  # running the action (`Ash.Changeset.change_attribute/3`); replaying the entry with its input would not set it, so the
  # entry records it (`forced`). Prepended, the hook runs before the action's own hooks, so what those set is not
  # recorded and a replay computes it again, and neither are the defaults Ash applies when the action starts (the
  # timestamps): they are in `defaults` and were not in the attributes before. Nothing is recorded for a destroy,
  # which writes no attribute.
  defp record_caller_changes(%{action_type: type} = changeset) when type in [:create, :update] do
    given = changeset.attributes
    primary_key = Info.primary_key(changeset.resource)

    Ash.Changeset.before_action(
      changeset,
      fn changeset ->
        late_defaults = Enum.reject(changeset.defaults, &Map.has_key?(given, &1))

        forced =
          for {name, value} <- changeset.attributes,
              name not in primary_key,
              name not in late_defaults,
              Map.fetch(given, name) != {:ok, value},
              into: %{},
              do: {name, value}

        if forced == %{},
          do: changeset,
          else: Ash.Changeset.set_context(changeset, %{ramal_forced: forced})
      end,
      prepend?: true
    )
  end

  defp record_caller_changes(changeset), do: changeset

  # Fails closed: the write is captured only inside the `around_action` hook. Ash runs every changeset that has one
  # singly, bulk actions included; if a path ever ran the before-action hooks without it, the data layer would be next,
  # so the action is refused instead of written to the base.
  defp ensure_wrapped(changeset) do
    if changeset.context[@wrapped],
      do: changeset,
      else: Ash.Changeset.add_error(changeset, bulk_error(changeset))
  end

  # The frame counts how deeply captured actions nest in this process and keeps the undo records of their writes.
  defp around(changeset, callback, id, origin, upsert?) do
    with :ok <- Current.verify(id, origin, what(changeset)),
         :ok <- ensure_not_in_task(changeset) do
      run_captured(changeset, callback, id, upsert?)
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

  defp run_captured(changeset, callback, id, upsert?) do
    frame = Process.get(@frame, %{depth: 0, undos: [], root: new_root(), durable: false})
    nested? = frame.depth > 0
    mark = length(frame.undos)
    Process.put(@frame, %{frame | depth: frame.depth + 1})

    changeset =
      changeset
      |> Ash.Changeset.set_context(%{@wrapped => true})
      |> Ash.Changeset.before_action(&write(&1, id, nested?, upsert?))

    try do
      result = callback.(changeset)

      cond do
        not succeeded?(result) -> rollback(id, mark, result)
        nested? -> result
        true -> commit(result, id, mark)
      end
    catch
      kind, reason ->
        rollback(id, mark, :raised)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      leave(id)
    end
  end

  # Names the outermost action: every write it makes, its own and those of its hooks, carries it, so that a merge can
  # tell which hook-made rows belong to which action even when hooks run before the action's write and writes of
  # actions in other processes are interleaved. Random, because a counter would start again when the node does.
  defp new_root, do: :crypto.strong_rand_bytes(6) |> :binary.decode_unsigned()

  defp succeeded?(result), do: is_tuple(result) and elem(result, 0) == :ok

  # The outermost action of a durable branch has ended well: its writes are stored before it returns (ADR 0048). Writes
  # made by the hooks of an inner action are in the frame too, so they are stored with it, as one delta.
  defp commit(result, id, mark) do
    case Process.get(@frame) do
      %{durable: true, undos: [_ | _]} = frame ->
        case Server.commit(id) do
          :ok ->
            # The process has dropped the writes it held, so there is nothing left for `leave/1` to release.
            Process.put(@frame, %{frame | undos: []})
            result

          {:error, _error} = failed ->
            rollback(id, mark, failed)
        end

      _not_durable_or_nothing_written ->
        result
    end
  end

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

  defp write(changeset, id, nested?, upsert?) do
    with {:ok, held} <- held_record(changeset, id),
         {:ok, changeset} <- complete(changeset, held, id),
         {:ok, kind, record, base_row, extra} <- written(changeset, held, id, upsert?) do
      resource = changeset.resource
      key = Resource.key(resource, record)
      entry = log_entry(changeset, key, nested?, extra)

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
          remember(undo, summary.durable)
          emit(summary, changeset, nested?)

          changeset
          |> keep_generated_key(record, extra)
          |> Ash.Changeset.set_result({:ok, result_record(kind, record, resource)})
          |> settle_foreign_keys(id, {resource, key}, extra[:upsert])

        {:ok, {:error, :destroyed}, _summary} ->
          Ash.Changeset.add_error(changeset, stale_error(changeset, key))

        {:error, %Error{} = error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  # The after-action hooks of a create read the key from the changeset as well as from the record.
  defp keep_generated_key(changeset, record, extra) do
    if extra[:generated_key?] do
      [field] = Info.primary_key(changeset.resource)
      Ash.Changeset.force_change_attribute(changeset, field, Map.get(record, field))
    else
      changeset
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
  #
  # An upsert that found its row takes only its upsert fields from the input, so the key of a relationship outside them
  # stays what the row had.
  defp settle_foreign_keys(%{action_type: :create} = changeset, id, ref, upsert) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      case changed_foreign_keys(changeset, result, upsert) do
        keys when keys == %{} -> {:ok, result}
        keys -> put_foreign_keys(id, ref, result, keys)
      end
    end)
  end

  defp settle_foreign_keys(changeset, _id, _ref, _upsert), do: changeset

  defp changed_foreign_keys(changeset, result, upsert) do
    {:ok, built} = Ash.Changeset.apply_attributes(changeset)

    for %{type: :belongs_to, source_attribute: attribute} <-
          Info.relationships(changeset.resource),
        takes?(upsert, attribute),
        Map.get(built, attribute) != Map.get(result, attribute),
        into: %{},
        do: {attribute, Map.get(built, attribute)}
  end

  defp takes?({_identity, fields, true}, attribute), do: attribute in fields
  defp takes?(_upsert, _attribute), do: true

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

  defp written(%{action_type: :create} = changeset, _held, id, upsert?) do
    {:ok, built} = Ash.Changeset.apply_attributes(changeset)
    upsert = if upsert?, do: plan_upsert(changeset, built)

    with {:ok, upsert} <- find_conflict(upsert, changeset, built, id) do
      written_create(changeset, built, id, upsert)
    end
  end

  # An update that changes no attribute is still logged: its hooks and managed relationships can write other rows, and
  # those writes are logged as nested, so only replaying this action brings them back. The overlay keeps the row as it
  # was (Ash does not write it either, so `updated_at` stays) and `Ramal.diff/1` leaves it out.
  defp written(%{action_type: :update} = changeset, held, _id, _upsert?) do
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
      {:ok, :updated, record, base_row(original), []}
    end
  end

  defp written(%{action_type: :destroy} = changeset, _held, _id, _upsert?) do
    {:ok, :deleted, changeset.data, base_row(changeset.data), []}
  end

  defp written_create(changeset, built, id, nil) do
    resource = changeset.resource

    case Enum.filter(Info.primary_key(resource), &(Map.get(built, &1) == nil)) do
      [] -> {:ok, :created, built, nil, []}
      [field] -> placeholder_key(changeset, built, id, field)
      _several -> {:error, key_error(changeset)}
    end
  end

  # No row in the branch's view has the upsert's key, so it is an ordinary create that the merge replays as an upsert:
  # `found?: false` has it force the branch's primary key, and the fields keep the key out of what a row that appeared
  # in the base meanwhile would take.
  defp written_create(changeset, built, id, %{found: nil} = upsert) do
    with {:ok, :created, record, nil, extra} <- written_create(changeset, built, id, nil) do
      {:ok, :created, record, nil, [upsert: log_upsert(upsert, false)] ++ extra}
    end
  end

  # The row is there, in the base or created by the branch: the upsert updates it. The record copies the upsert fields
  # from the row Ash built, plus the update defaults unless `touch_update_defaults?: false` was given, and never the
  # primary key (AshPostgres leaves keys out of `DO UPDATE SET` as well).
  defp written_create(changeset, built, _id, %{found: found} = upsert) do
    resource = changeset.resource

    record =
      upsert.fields
      |> Enum.reduce(found, fn field, acc -> Map.put(acc, field, Map.get(built, field)) end)
      |> touch_update_defaults(resource, upsert)

    {:ok, :updated, record, base_row(found), upsert: log_upsert(upsert, true)}
  end

  # `{identity, fields, found?}`: a tuple, like the entry around it, so a stored branch needs no atom of Ramal's own.
  # The key is one the database generates (`generated? true`, such as `integer_primary_key`): the branch cannot know it,
  # so the row gets a placeholder that the merge renames to the key the database gives the replayed create (ADR 0042). A
  # key of a type with no placeholder, a composite key, or one that is not generated stays refused.
  defp placeholder_key(changeset, built, id, field) do
    resource = changeset.resource
    attribute = Info.attribute(resource, field)
    type = attribute.type

    with true <- attribute.generated? and Info.primary_key(resource) == [field],
         {:ok, {:ok, key}, _summary} <- Server.write(id, &next_placeholder(&1, type)) do
      {:ok, :created, Map.put(built, field, key), nil, [generated_key?: true]}
    else
      {:error, %Error{} = error} -> {:error, error}
      _no_placeholder -> {:error, key_error(changeset)}
    end
  end

  defp next_placeholder(branch, type) do
    case Branch.placeholder(branch, type) do
      {:ok, key, branch} -> {{:ok, key}, branch}
      :error -> {:error, branch}
    end
  end

  defp log_upsert(upsert, found?), do: {upsert.identity, upsert.fields, found?}

  # What the upsert does if the row exists: the identity it conflicts on, the keys and their values, and the fields
  # it takes. `upsert/4` in AshPostgres 2.15 uses the fields given to the action, or else what the changeset set that
  # is not a default, without the keys, and the update defaults come on top.
  defp plan_upsert(changeset, built) do
    resource = changeset.resource
    name = changeset.context[:private][:upsert_identity]
    identity = name && Info.identity(resource, name)
    keys = conflict_keys(resource, identity)

    given = changeset.context[:private][:upsert_fields]
    set = Map.keys(changeset.attributes) -- Map.get(changeset, :defaults, [])

    fields =
      ((given || set) -- keys) -- Info.primary_key(resource)

    %{
      identity: name,
      definition: identity,
      keys: keys,
      values: Enum.map(keys, &{&1, Map.get(built, &1)}),
      fields: fields,
      touch?: changeset.context[:private][:touch_update_defaults?] != false,
      found: nil
    }
  end

  # The columns of the unique index, as `commit/3` in `lib/ash/actions/create/create.ex` (Ash 3.37) names the
  # conflict target: the identity's keys, plus the tenant attribute of attribute multitenancy unless the identity spans
  # tenants, or else the primary key.
  defp conflict_keys(resource, nil), do: Info.primary_key(resource)

  defp conflict_keys(resource, identity) do
    if identity.all_tenants? or Info.multitenancy_strategy(resource) != :attribute do
      identity.keys
    else
      Enum.uniq([Info.multitenancy_attribute(resource) | identity.keys])
    end
  end

  defp find_conflict(nil, _changeset, _built, _id), do: {:ok, nil}

  defp find_conflict(upsert, changeset, built, id) do
    with {:ok, applies?} <- applies?(upsert.definition, changeset, built) do
      if applies? and not distinct_nil?(upsert) do
        lookup(upsert, changeset, id)
      else
        {:ok, upsert}
      end
    end
  end

  # With the default `nils_distinct?`, rows whose key has a nil in it never conflict.
  defp distinct_nil?(%{definition: definition, values: values}) do
    nils_distinct? = is_nil(definition) or definition.nils_distinct? != false
    nils_distinct? and Enum.any?(values, fn {_key, value} -> is_nil(value) end)
  end

  # A partial unique index (`where` on the identity) only holds the rows that satisfy it, the new one included.
  defp applies?(%{where: where}, changeset, built) when not is_nil(where) do
    case Ash.Expr.eval(where,
           resource: changeset.resource,
           record: built,
           domain: changeset.domain,
           unknown_on_unknown_refs?: true
         ) do
      {:ok, true} -> {:ok, true}
      {:ok, _no} -> {:ok, false}
      _unknown_or_error -> {:error, upsert_where_error(changeset)}
    end
  end

  defp applies?(_definition, _changeset, _built), do: {:ok, true}

  # A patched read: it sees the rows the branch created and changed, not the ones it destroyed, and fingerprints the
  # base row it returns.
  defp lookup(upsert, changeset, id) do
    filter =
      Enum.map(upsert.values, fn
        {key, nil} -> {key, [is_nil: true]}
        {key, value} -> {key, value}
      end)

    changeset.resource
    |> Ash.Query.do_filter(filter)
    |> add_where(upsert.definition)
    |> Ash.Query.limit(1)
    |> Ash.read_one(
      authorize?: false,
      tenant: changeset.tenant,
      context: Current.shared_context(id)
    )
    |> case do
      {:ok, found} -> {:ok, %{upsert | found: found}}
      {:error, error} -> {:error, error}
    end
  end

  defp add_where(query, %{where: where}) when not is_nil(where),
    do: Ash.Query.do_filter(query, where)

  defp add_where(query, _definition), do: query

  defp touch_update_defaults(record, _resource, %{touch?: false}), do: record

  defp touch_update_defaults(record, resource, %{fields: fields}) do
    resource
    |> Info.attributes()
    |> Enum.filter(&(&1.update_default != nil and &1.name not in fields))
    |> Enum.reduce(record, fn attribute, acc ->
      Map.put(acc, attribute.name, update_default(attribute.update_default))
    end)
  end

  defp update_default(fun) when is_function(fun, 0), do: fun.()
  defp update_default({module, function, args}), do: apply(module, function, args)
  defp update_default(value), do: value

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
  defp log_entry(changeset, key, nested?, extra) do
    opts =
      [key: key, tenant: changeset.tenant, nested?: nested?, root: Process.get(@frame).root] ++
        extra

    {changeset.action_type, changeset.resource, changeset.action.name, changeset.params,
     changeset.context[:private][:actor], with_forced(opts, changeset, nested?),
     DateTime.utc_now()}
  end

  # A nested entry is not replayed (the hook that made it runs again), so what its caller set is not needed.
  defp with_forced(opts, changeset, false = _nested?) do
    case changeset.context[:ramal_forced] do
      nil -> opts
      forced -> opts ++ [forced: forced]
    end
  end

  defp with_forced(opts, _changeset, true = _nested?), do: opts

  defp remember(undo, durable?) do
    frame = Process.get(@frame)
    Process.put(@frame, %{frame | undos: [undo | frame.undos], durable: durable?})
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
        "so it is generated by the database and a branch cannot create the row; a branch stands in for a single " <>
        "`generated? true` key of type integer or uuid, so give the key one of those types or a default such as uuid_primary_key",
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
      "#{inspect(changeset.resource)}.#{changeset.action.name} ran inside a branch without the capture hook around it, " <>
        "so it would have written to the database; call the action once per record instead",
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

  defp upsert_condition_error(changeset) do
    Error.new(
      :upsert_unsupported,
      "#{inspect(changeset.resource)}.#{changeset.action.name} is an upsert with an upsert_condition; the database " <>
        "evaluates a condition against the row that is there, which a branch cannot, so drop the condition or " <>
        "update the row explicitly",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end

  defp upsert_where_error(changeset) do
    Error.new(
      :upsert_unsupported,
      "#{inspect(changeset.resource)}.#{changeset.action.name} is an upsert on an identity with a `where` that cannot " <>
        "be evaluated for the new row without the database, so a branch cannot tell whether it conflicts",
      %{resource: changeset.resource, action: changeset.action.name}
    )
  end
end
