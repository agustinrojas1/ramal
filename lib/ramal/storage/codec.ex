defmodule Ramal.Storage.Codec do
  @moduledoc """
  Turns a branch into a JSON-safe map and back, for storage backends that keep text (`Ramal.Storage.Postgres` keeps it
  in a `jsonb` column).

  `encode_state/1` covers what the table has no column for: overlay, base (fingerprints and snapshots), log, metadata,
  the owner, the proposal and the count of placeholder keys. `decode_state/2` takes that map and the columns and gives the branch back, equal to the one encoded.

  How values are written, confirmed against Ash 3.37 (`lib/ash/type/type.ex`):

    * An attribute value goes through `Ash.Type.dump_to_embedded/3` and comes back through
      `Ash.Type.cast_from_embedded/3`, so types with a custom stored form (atoms, embedded resources, `Ash.Type.Term`)
      round-trip as their type defines. Unloaded attributes (a `select` read) are listed under `"unloaded"`.
    * The other fields of a record (`__meta__`, `__metadata__`, loaded relationships, calculations, aggregates) are
      kept only when they differ from a fresh `struct(resource)`, as plain terms.
    * Everything else (primary keys, action input, actors, metadata, options) is a plain term: strings, numbers,
      booleans and `nil` are themselves; a list is a list; a map with only string keys that do not start with `$` is an
      object; and everything else is a one-key object that says what it is: `$a` atom, `$t` tuple, `$m` map as pairs,
      `$s` struct, `$b` base64 of a binary that is not valid UTF-8, and for the structs that fill a record most often,
      `$dt` `DateTime` (UTC), `$ndt` `NaiveDateTime`, `$d` `Date` and `$tm` `Time`, each as its ISO 8601 text. They
      apply to the ISO calendar and to a `DateTime` in UTC, which the text reads back as the same value; any other is a
      `$s` struct. A `$s` struct lists only the fields that differ from the module's default struct.
    * The parts of a record's non-attribute fields (`__meta__`, `__metadata__`) that several records have in common are
      written once under `"extras"`, and the records refer to them (`{"$x": index}`).
    * A base row's snapshot is stored as what differs from the branch's record of the same row (`"like": "overlay"`),
      because an update changes a few attributes of the row it started from. A snapshot of a row the branch deleted, which
      has no record to compare with, is stored whole.
    * Atoms are read back with `String.to_existing_atom/1`, never created. Module names are found through the code
      path when the atom does not exist yet (a fresh VM has not loaded the host's modules), so a module that is not on
      the path is an error, not a new atom. Modules are loaded as they are named, before the values that follow them
      are read, which brings in the atoms they mention. An atom that no loaded module mentions (a metadata key that
      only a host controller uses, say, in a VM that has not loaded that controller) fails the load with
      `:storage` and names the atom; string keys never have this problem.

  Pids, references, ports and functions cannot be stored: encoding returns `{:error, %Ramal.Error{reason: :storage}}`
  naming the path of the offending value. The actor is stored as the term it is, with one exception: when it is an Ash
  resource record, the attributes marked `sensitive?` (password hashes, tokens) are stored as `nil`, so a stored branch
  never holds them (`docs/adr/0010-stored-actors.md`). The actor read back from storage therefore has those fields
  empty; pass `actor:` to `Ramal.merge/2` to replace the whole actor. Fields that are not attributes, such as a loaded
  relationship, are stored as they are.

  ## Example

      iex> branch = Ramal.Branch.new(Ramal.Test.Farm, name: "move R7")
      iex> {:ok, state} = Ramal.Storage.Codec.encode_state(branch)
      iex> columns = %{id: branch.id, domain: "Elixir.Ramal.Test.Farm", name: "move R7", status: "open"}
      iex> {:ok, ^branch} = Ramal.Storage.Codec.decode_state(columns, state)
  """

  alias Ash.Resource.Info
  alias Ramal.{Branch, Error}

  @version 2
  @readable_versions [1, 2]
  @statuses %{
    "open" => :open,
    "proposed" => :proposed,
    "merged" => :merged,
    "rejected" => :rejected,
    "discarded" => :discarded
  }
  @opt_names %{
    "key" => :key,
    "tenant" => :tenant,
    "nested?" => :nested?,
    "upsert" => :upsert,
    "generated_key?" => :generated_key?
  }

  @doc """
  The JSON-safe state of `branch`: overlay, base, log, metadata, owner, tenant and `inserted_at`.

  ## Example

      iex> {:ok, state} = Ramal.Storage.Codec.encode_state(Ramal.Branch.new(Ramal.Test.Farm))
      iex> {state["version"], state["overlay"], state["log"]}
      {2, [], []}
  """
  @spec encode_state(Branch.t()) :: {:ok, map} | {:error, Error.t()}
  def encode_state(%Branch{} = branch) do
    {:ok,
     dedupe_extras(%{
       "version" => @version,
       "overlay" => Enum.map(branch.overlay, &overlay_entry/1),
       "base" => Enum.map(branch.base, &base_entry(&1, branch.overlay)),
       "log" => Enum.map(branch.log, &log_entry/1),
       "metadata" => term(branch.metadata, ["metadata"]),
       "owner" => term(branch.owner, ["owner"]),
       "tenant" => term(branch.tenant, ["tenant"]),
       "inserted_at" => term(branch.inserted_at, ["inserted_at"]),
       "proposal" => proposal(branch.proposal),
       "next_placeholder" => branch.next_placeholder
     })}
  catch
    {:codec, message, path} ->
      {:error,
       Error.new(:storage, "branch #{branch.id} cannot be stored: #{message}", %{path: path})}
  end

  @doc """
  The JSON form of an owner, as `encode_state/1` writes it under `"owner"`, so that a storage can compare it in the
  database.

  ## Example

      iex> Ramal.Storage.Codec.encode_owner("user-7")
      {:ok, "user-7"}
      iex> Ramal.Storage.Codec.encode_owner({:user, 7})
      {:ok, %{"$t" => [%{"$a" => "user"}, 7]}}
  """
  @spec encode_owner(term) :: {:ok, term} | {:error, Error.t()}
  def encode_owner(owner) do
    {:ok, term(owner, ["owner"])}
  catch
    {:codec, message, path} ->
      {:error, Error.new(:storage, "the owner cannot be stored: #{message}", %{path: path})}
  end

  @doc """
  The branch for the stored `columns` (`id`, `domain` and `status` as stored, `name`) and the `state` map.

  Returns `{:error, %Ramal.Error{reason: :storage}}` when the state was written by a newer version, names a module or
  atom that is not available, or no longer matches a resource's attributes.

  ## Example

      iex> columns = %{id: "b1", domain: "Elixir.Ramal.Test.Farm", name: nil, status: "open"}
      iex> {:error, error} = Ramal.Storage.Codec.decode_state(columns, %{"version" => 99})
      iex> error.reason
      :storage
  """
  @spec decode_state(map, map) :: {:ok, Branch.t()} | {:error, Error.t()}
  def decode_state(columns, %{"version" => version} = state) when version in @readable_versions do
    state = expand_extras(state)
    overlay = Map.new(state["overlay"], &decode_overlay_entry/1)

    {:ok,
     %Branch{
       id: columns.id,
       name: columns.name,
       domain: module!(columns.domain),
       status: status!(columns.status),
       inserted_at: unterm(state["inserted_at"]),
       metadata: unterm(state["metadata"]),
       owner: unterm(state["owner"]),
       tenant: unterm(state["tenant"]),
       overlay: overlay,
       base: Map.new(state["base"], &decode_base_entry(&1, overlay)),
       log: Enum.map(state["log"], &decode_log_entry/1),
       proposal: decode_proposal(state["proposal"]),
       next_placeholder: state["next_placeholder"] || 0
     }}
  rescue
    # The state came out of a database column that anything with write access to it can change. A shape this module
    # never writes is an error for the caller to handle, not a crash of the branch process that asked. Only the kind of
    # exception is reported: its message can print the stored values.
    exception ->
      {:error,
       Error.new(
         :storage,
         "stored branch #{columns.id} cannot be loaded: its state is malformed (#{inspect(exception.__struct__)})"
       )}
  catch
    {:codec, message} ->
      {:error, Error.new(:storage, "stored branch #{columns.id} cannot be loaded: #{message}")}
  end

  def decode_state(columns, %{"version" => version}) do
    {:error,
     Error.new(
       :storage,
       "stored branch #{columns.id} has state version #{version}; this Ramal reads versions #{Enum.join(@readable_versions, " and ")}"
     )}
  end

  defp status!(status) do
    case Map.fetch(@statuses, status) do
      {:ok, atom} -> atom
      :error -> throw({:codec, "unknown status #{inspect(status)}"})
    end
  end

  # -- extras ------------------------------------------------------------------------------------------------------

  # The fields of a record that are not attributes (`__meta__`, `__metadata__`, loaded relationships) are the
  # same for most rows of a resource, and written out they are most of what a row costs. A part of them that more than
  # one record has, and that is larger than the reference to it, is written once under `"extras"` and the records hold
  # `{"$x": index}` in its place. A plain object never has a key that starts with `$`, so a reference cannot be data.
  @shared_weight 5

  defp dedupe_extras(state) do
    extras = for %{"record" => %{"extra" => extra}} <- state["overlay"], do: extra
    counts = Enum.reduce(extras, %{}, &count_parts/2)

    {overlay, shared} =
      Enum.map_reduce(state["overlay"], %{index: %{}, table: []}, fn
        %{"record" => %{"extra" => extra} = record} = entry, shared ->
          {extra, shared} = share_parts(extra, counts, shared)
          {%{entry | "record" => %{record | "extra" => extra}}, shared}

        entry, shared ->
          {entry, shared}
      end)

    case shared.table do
      [] -> state
      table -> state |> Map.put("overlay", overlay) |> Map.put("extras", Enum.reverse(table))
    end
  end

  defp count_parts(part, counts) when is_map(part) or is_list(part) do
    counts = Map.update(counts, part, 1, &(&1 + 1))
    children = if is_map(part), do: Map.values(part), else: part
    Enum.reduce(children, counts, &count_parts/2)
  end

  defp count_parts(_leaf, counts), do: counts

  defp share_parts(part, counts, shared) when is_map(part) or is_list(part) do
    if Map.get(counts, part, 0) > 1 and weight(part) >= @shared_weight do
      reference(part, shared)
    else
      descend(part, counts, shared)
    end
  end

  defp share_parts(leaf, _counts, shared), do: {leaf, shared}

  defp descend(part, counts, shared) when is_map(part) do
    {pairs, shared} =
      Enum.map_reduce(part, shared, fn {key, value}, shared ->
        {value, shared} = share_parts(value, counts, shared)
        {{key, value}, shared}
      end)

    {Map.new(pairs), shared}
  end

  defp descend(part, counts, shared),
    do: Enum.map_reduce(part, shared, &share_parts(&1, counts, &2))

  defp reference(part, %{index: index, table: table} = shared) do
    case index do
      %{^part => at} ->
        {%{"$x" => at}, shared}

      _new ->
        at = map_size(index)
        {%{"$x" => at}, %{shared | index: Map.put(index, part, at), table: [part | table]}}
    end
  end

  defp weight(part) when is_map(part), do: 1 + (part |> Map.values() |> weight_all())
  defp weight(part) when is_list(part), do: 1 + weight_all(part)
  defp weight(_leaf), do: 1

  defp weight_all(parts), do: parts |> Enum.map(&weight/1) |> Enum.sum()

  defp expand_extras(%{"extras" => table, "overlay" => overlay} = state) when is_list(table) do
    table = List.to_tuple(table)

    overlay =
      Enum.map(overlay, fn
        %{"record" => %{"extra" => extra} = record} = entry ->
          %{entry | "record" => %{record | "extra" => expand_parts(extra, table)}}

        entry ->
          entry
      end)

    %{state | "overlay" => overlay}
  end

  defp expand_extras(state), do: state

  defp expand_parts(%{"$x" => at}, table)
       when is_integer(at) and at >= 0 and at < tuple_size(table),
       do: elem(table, at)

  defp expand_parts(part, table) when is_map(part),
    do: Map.new(part, fn {key, value} -> {key, expand_parts(value, table)} end)

  defp expand_parts(part, table) when is_list(part), do: Enum.map(part, &expand_parts(&1, table))
  defp expand_parts(leaf, _table), do: leaf

  # -- encode -------------------------------------------------------------------------------------------------------

  # A proposal is written field by field, with string keys, so that reading it back never needs an atom that only this
  # module mentions. Actors lose their sensitive attributes like the actors in the log (ADR 0010).
  defp proposal(nil), do: nil

  defp proposal(proposal) do
    path = ["proposal"]

    %{
      "proposer" => proposal.proposer |> redact() |> term(["proposer" | path]),
      "reason" => proposal.reason,
      "proposed_at" => term(proposal.proposed_at, ["proposed_at" | path]),
      "decision" => decision(proposal.decision)
    }
  end

  defp decision(nil), do: nil

  defp decision(decision) do
    path = ["decision", "proposal"]

    %{
      "status" => Atom.to_string(decision.status),
      "by" => decision.by |> redact() |> term(["by" | path]),
      "reason" => decision.reason,
      "at" => term(decision.at, ["at" | path]),
      "replayed" => decision.replayed,
      "stale" => term(decision.stale, ["stale" | path])
    }
  end

  defp overlay_entry({{resource, key}, entry}) do
    {op, record} =
      case entry do
        {:created, record} -> {"created", record(record)}
        {:updated, record} -> {"updated", record(record)}
        :deleted -> {"deleted", nil}
      end

    %{
      "resource" => Atom.to_string(resource),
      "key" => term(key, [{:resource, resource}, "overlay"]),
      "op" => op,
      "record" => record
    }
  end

  defp base_entry({{resource, key} = ref, row}, overlay) do
    %{
      "resource" => Atom.to_string(resource),
      "key" => term(key, [{:resource, resource}, "base"]),
      "fingerprint" => row.fingerprint,
      "snapshot" => row.snapshot && snapshot(row.snapshot, Map.get(overlay, ref))
    }
  end

  # An update leaves most of a row as it was, so the snapshot is stored as what differs from the record.
  defp snapshot(%resource{} = snapshot, {_kind, %resource{} = record}) do
    Map.put(record(snapshot, record), "like", "overlay")
  end

  defp snapshot(snapshot, _overlay_entry), do: record(snapshot)

  defp log_entry({type, resource, action, params, actor, opts, at}) do
    path = [Atom.to_string(action), {:resource, resource}, "log"]

    %{
      "type" => Atom.to_string(type),
      "resource" => Atom.to_string(resource),
      "action" => Atom.to_string(action),
      "params" => term(params, ["params" | path]),
      "actor" => actor |> redact() |> term(["actor" | path]),
      "opts" =>
        Enum.map(opts, fn {name, value} ->
          [Atom.to_string(name), term(value, [Atom.to_string(name), "opts" | path])]
        end),
      "at" => term(at, ["at" | path])
    }
  end

  # With `against`, only what differs from that record of the same resource.
  defp record(%resource{} = record, against \\ nil) do
    attributes = Info.attributes(resource)
    names = MapSet.new(attributes, & &1.name)

    {unloaded, loaded} =
      attributes
      |> Enum.reject(&same_field?(record, against, &1.name))
      |> Enum.split_with(&unloaded?(Map.fetch!(record, &1.name)))

    %{
      "attrs" =>
        Map.new(
          loaded,
          &{Atom.to_string(&1.name), attribute(&1, Map.fetch!(record, &1.name), resource)}
        ),
      "unloaded" => Enum.map(unloaded, &Atom.to_string(&1.name)),
      "extra" => extra(record, resource, names, against)
    }
    |> Map.reject(fn {_name, stored} -> stored == [] or stored == %{} end)
  end

  defp same_field?(_record, nil, _name), do: false

  defp same_field?(record, against, name),
    do: Map.fetch!(record, name) === Map.fetch!(against, name)

  defp unloaded?(%Ash.NotLoaded{}), do: true
  defp unloaded?(_value), do: false

  defp attribute(_attribute, nil, _resource), do: nil

  defp attribute(attribute, value, resource) do
    case Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints) do
      {:ok, dumped} ->
        term(dumped, [Atom.to_string(attribute.name), {:resource, resource}, "record"])

      _error ->
        throw({:codec, "#{inspect(resource)}.#{attribute.name} does not dump as its type", []})
    end
  end

  # The fields that are not attributes. A full record lists the ones that differ from a fresh struct of the resource; a
  # record stored against another lists the ones that differ from that one, which can be a field at its default.
  defp extra(record, resource, names, against) do
    reference = Map.from_struct(against || struct(resource))

    extra =
      record
      |> Map.from_struct()
      |> Enum.reject(fn {field, value} ->
        field in names or Map.fetch!(reference, field) === value
      end)
      |> Map.new()

    term(extra, ["extra", {:resource, resource}, "record"])
  end

  # Only Ash resource records have attributes that can be sensitive; any other actor (a map, a tuple) is the host's own
  # shape and is stored as it is.
  defp redact(%module{} = actor) do
    if Info.resource?(module) do
      module
      |> Info.attributes()
      |> Enum.filter(& &1.sensitive?)
      |> Enum.reduce(actor, &Map.put(&2, &1.name, nil))
    else
      actor
    end
  end

  defp redact(actor), do: actor

  # `path` is where the value sits, innermost first, so that an error can name it. Its entries are strings or, for what
  # costs something to print (a resource module, a key that is not an atom), a tuple that `path_label/1` prints only
  # when an error needs the path, not for every value that is stored.
  defp term(value, _path) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp term(value, _path) when is_atom(value), do: %{"$a" => Atom.to_string(value)}

  defp term(value, _path) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$b" => Base.encode64(value)}
  end

  defp term(value, path) when is_list(value) do
    if proper?(value), do: Enum.map(value, &term(&1, path)), else: unstorable(value, path)
  end

  defp term(value, path) when is_tuple(value) do
    %{"$t" => value |> Tuple.to_list() |> Enum.map(&term(&1, path))}
  end

  # The text of a date or time reads back as the same value only in the ISO calendar, and a `DateTime` only in UTC.
  # The years of ISO 8601 are four digits. Anything else falls through to the struct clause below.
  defp term(
         %DateTime{calendar: Calendar.ISO, year: year, time_zone: "Etc/UTC", zone_abbr: "UTC"} =
           value,
         _path
       )
       when year in 0..9999 and value.utc_offset == 0 and value.std_offset == 0,
       do: %{"$dt" => DateTime.to_iso8601(value)}

  defp term(%NaiveDateTime{calendar: Calendar.ISO, year: year} = value, _path)
       when year in 0..9999,
       do: %{"$ndt" => NaiveDateTime.to_iso8601(value)}

  defp term(%Date{calendar: Calendar.ISO, year: year} = value, _path) when year in 0..9999,
    do: %{"$d" => Date.to_iso8601(value)}

  defp term(%Time{calendar: Calendar.ISO} = value, _path), do: %{"$tm" => Time.to_iso8601(value)}

  # Only the fields that differ from the module's default struct are written; `unterm/1` starts from that struct.
  defp term(%module{} = value, path) do
    defaults = defaults(module)

    fields =
      value
      |> Map.from_struct()
      |> Enum.reject(fn {k, v} -> Map.fetch(defaults, k) === {:ok, v} end)
      |> Map.new(fn {k, v} -> {Atom.to_string(k), term(v, [Atom.to_string(k) | path])} end)

    %{"$s" => Atom.to_string(module), "f" => fields}
  end

  defp term(value, path) when is_map(value) do
    if plain_keys?(value) do
      Map.new(value, fn {k, v} -> {k, term(v, [k | path])} end)
    else
      %{"$m" => for({k, v} <- value, do: [term(k, path), term(v, [label(k) | path])])}
    end
  end

  defp term(value, path), do: unstorable(value, path)

  # A module the VM has not loaded yet still has structs in memory (a literal needs no loaded module).
  defp defaults(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0),
      do: Map.from_struct(module.__struct__()),
      else: %{}
  end

  defp label(key) when is_atom(key), do: Atom.to_string(key)
  defp label(key), do: {:inspect, key}

  defp plain_keys?(map) do
    Enum.all?(map, fn {key, _} ->
      is_binary(key) and String.valid?(key) and not String.starts_with?(key, "$")
    end)
  end

  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_improper), do: false

  defp unstorable(value, path) do
    throw(
      {:codec, "#{inspect(value)} (a #{type_name(value)}) cannot be stored",
       path |> Enum.reverse() |> Enum.map(&path_label/1)}
    )
  end

  defp path_label({:resource, resource}), do: inspect(resource)
  defp path_label({:inspect, key}), do: inspect(key)
  defp path_label(label), do: label

  defp type_name(value) when is_pid(value), do: "pid"
  defp type_name(value) when is_reference(value), do: "reference"
  defp type_name(value) when is_function(value), do: "function"
  defp type_name(value) when is_port(value), do: "port"
  defp type_name(_value), do: "improper list"

  # -- decode -------------------------------------------------------------------------------------------------------

  defp decode_overlay_entry(%{
         "resource" => resource,
         "key" => key,
         "op" => op,
         "record" => record
       }) do
    resource = module!(resource)
    ref = {resource, unterm(key)}

    case op do
      "created" -> {ref, {:created, decode_record(resource, record)}}
      "updated" -> {ref, {:updated, decode_record(resource, record)}}
      "deleted" -> {ref, :deleted}
    end
  end

  defp decode_base_entry(%{"resource" => resource, "key" => key} = row, overlay) do
    resource = module!(resource)
    ref = {resource, unterm(key)}

    snapshot =
      row["snapshot"] && decode_snapshot(resource, row["snapshot"], Map.get(overlay, ref))

    {ref, %{fingerprint: row["fingerprint"], snapshot: snapshot}}
  end

  defp decode_snapshot(resource, %{"like" => "overlay"} = stored, entry) do
    case entry do
      {_kind, %^resource{} = record} ->
        decode_record(resource, stored, record)

      _no_record ->
        throw(
          {:codec,
           "the snapshot of a #{inspect(resource)} row refers to a record the branch lacks"}
        )
    end
  end

  defp decode_snapshot(resource, stored, _entry), do: decode_record(resource, stored)

  defp decode_proposal(nil), do: nil

  defp decode_proposal(stored) do
    %{
      proposer: unterm(stored["proposer"]),
      reason: stored["reason"],
      proposed_at: unterm(stored["proposed_at"]),
      decision: decode_decision(stored["decision"])
    }
  end

  defp decode_decision(nil), do: nil

  defp decode_decision(stored) do
    %{
      status: decision_status!(stored["status"]),
      by: unterm(stored["by"]),
      reason: stored["reason"],
      at: unterm(stored["at"]),
      replayed: stored["replayed"],
      stale: unterm(stored["stale"])
    }
  end

  defp decision_status!("approved"), do: :approved
  defp decision_status!("rejected"), do: :rejected
  defp decision_status!(other), do: throw({:codec, "unknown decision status #{inspect(other)}"})

  defp decode_log_entry(entry) do
    resource = module!(entry["resource"])

    {atom!(entry["type"]), resource, atom!(entry["action"]), unterm(entry["params"]),
     unterm(entry["actor"]), decode_opts(entry["opts"]), unterm(entry["at"])}
  end

  # The names the capture writes are Ramal's own, so they are matched here rather than read as atoms: a fresh VM has
  # not loaded `Ramal.Capture`, the module that mentions them.
  defp decode_opts(opts) do
    for [name, value] <- opts do
      {Map.get_lazy(@opt_names, name, fn -> atom!(name) end), unterm(value)}
    end
  end

  # `like` is the record that the stored fields are changes to, for a snapshot stored against the overlay.
  defp decode_record(resource, stored, like \\ nil)

  defp decode_record(resource, stored, like) do
    attrs = Map.get(stored, "attrs", %{})
    unloaded = Map.get(stored, "unloaded", [])
    extra = Map.get(stored, "extra", %{})
    attributes = Info.attributes(resource)
    known = MapSet.new(attributes, &Atom.to_string(&1.name))

    for name <- Map.keys(attrs) ++ unloaded, name not in known do
      throw({:codec, "#{inspect(resource)} no longer has the attribute #{name}"})
    end

    record =
      Enum.reduce(attributes, like || struct(resource), fn attribute, record ->
        name = Atom.to_string(attribute.name)

        cond do
          name in unloaded ->
            Map.put(record, attribute.name, %Ash.NotLoaded{
              type: :attribute,
              field: attribute.name,
              resource: resource
            })

          Map.has_key?(attrs, name) ->
            Map.put(record, attribute.name, cast(resource, attribute, attrs[name]))

          true ->
            record
        end
      end)

    Map.merge(record, unterm(extra))
  end

  defp cast(_resource, _attribute, nil), do: nil

  defp cast(resource, attribute, stored) do
    case Ash.Type.cast_from_embedded(attribute.type, unterm(stored), attribute.constraints) do
      {:ok, value} ->
        value

      _error ->
        throw(
          {:codec, "#{inspect(resource)}.#{attribute.name} no longer casts from its stored form"}
        )
    end
  end

  defp unterm(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: value

  defp unterm(value) when is_list(value), do: Enum.map(value, &unterm/1)
  defp unterm(%{"$a" => name}), do: atom!(name)
  defp unterm(%{"$b" => encoded}), do: Base.decode64!(encoded)
  defp unterm(%{"$dt" => text}), do: iso8601!(text, &DateTime.from_iso8601/1)
  defp unterm(%{"$ndt" => text}), do: iso8601!(text, &NaiveDateTime.from_iso8601/1)
  defp unterm(%{"$d" => text}), do: iso8601!(text, &Date.from_iso8601/1)
  defp unterm(%{"$tm" => text}), do: iso8601!(text, &Time.from_iso8601/1)
  defp unterm(%{"$t" => items}), do: items |> Enum.map(&unterm/1) |> List.to_tuple()
  defp unterm(%{"$m" => pairs}), do: Map.new(pairs, fn [k, v] -> {unterm(k), unterm(v)} end)

  defp unterm(%{"$s" => name, "f" => fields}) do
    module = module!(name)

    unless function_exported?(module, :__struct__, 0) do
      throw({:codec, "#{name} is not a struct"})
    end

    template = Map.from_struct(struct(module))
    known = Map.new(template, fn {field, _} -> {Atom.to_string(field), field} end)

    values =
      Map.new(fields, fn {field, value} ->
        case Map.fetch(known, field) do
          {:ok, atom} -> {atom, unterm(value)}
          :error -> throw({:codec, "#{name} no longer has the field #{field}"})
        end
      end)

    struct(module, values)
  end

  defp unterm(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, unterm(v)} end)

  defp iso8601!(text, parse) when is_binary(text) do
    case parse.(text) do
      {:ok, value} -> value
      {:ok, value, _offset} -> value
      {:error, _reason} -> throw({:codec, "#{inspect(text)} is not an ISO 8601 date or time"})
    end
  end

  defp iso8601!(text, _parse),
    do: throw({:codec, "#{inspect(text)} is not an ISO 8601 date or time"})

  defp atom!("Elixir." <> _ = name), do: module!(name)

  defp atom!(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      throw(
        {:codec,
         "the atom #{inspect(name)} is not known; is the module that defines it on the code path?"}
      )
  end

  # A fresh VM has not loaded the host's modules, so their atoms do not exist yet. A module that has a beam file on the
  # code path is a module of the host, not data, so creating its atom is bounded by what the host compiled. Loading the
  # module also brings in the atoms it mentions (attribute names, roles in its policies), which the atoms stored in
  # action input and actors usually are.
  defp module!(name) do
    # `:code.where_is_file/1` joins the name onto each code path directory, so a stored `Elixir.../../x` would probe
    # files outside of them. A module name has no separators.
    unless name =~ ~r/\AElixir(\.[A-Za-z_][A-Za-z0-9_]*)+\z/ do
      throw({:codec, "#{inspect(name)} is not a module name"})
    end

    module =
      try do
        String.to_existing_atom(name)
      rescue
        ArgumentError ->
          if :code.where_is_file(String.to_charlist(name <> ".beam")) == :non_existing do
            throw({:codec, "the module #{name} is not on the code path"})
          else
            String.to_atom(name)
          end
      end

    Code.ensure_loaded(module)
    module
  end
end
