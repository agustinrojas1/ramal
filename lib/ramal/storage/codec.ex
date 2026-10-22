defmodule Ramal.Storage.Codec do
  @moduledoc """
  Turns a branch into a JSON-safe map and back, for storage backends that keep text (`Ramal.Storage.Postgres` keeps it
  in a `jsonb` column).

  `encode_state/1` covers what the table has no column for: overlay, base (fingerprints and snapshots), log and
  metadata. `decode_state/2` takes that map and the columns and gives the branch back, equal to the one encoded.

  How values are written, confirmed against Ash 3.37 (`lib/ash/type/type.ex`):

    * An attribute value goes through `Ash.Type.dump_to_embedded/3` and comes back through
      `Ash.Type.cast_from_embedded/3`, so types with a custom stored form (atoms, embedded resources, `Ash.Type.Term`)
      round-trip as their type defines. Unloaded attributes (a `select` read) are listed under `"unloaded"`.
    * The other fields of a record (`__meta__`, `__metadata__`, loaded relationships, calculations, aggregates) are
      kept only when they differ from a fresh `struct(resource)`, as plain terms.
    * Everything else (primary keys, action input, actors, metadata, options) is a plain term: strings, numbers,
      booleans and `nil` are themselves; a list is a list; a map with only string keys that do not start with `$` is an
      object; and everything else is a one-key object that says what it is: `$a` atom, `$t` tuple, `$m` map as pairs,
      `$s` struct, `$b` base64 of a binary that is not valid UTF-8.
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

  @version 1
  @statuses %{"open" => :open, "merged" => :merged, "discarded" => :discarded}
  @opt_names %{"key" => :key, "tenant" => :tenant, "nested?" => :nested?}

  @doc """
  The JSON-safe state of `branch`: overlay, base, log, metadata and `inserted_at`.

  ## Example

      iex> {:ok, state} = Ramal.Storage.Codec.encode_state(Ramal.Branch.new(Ramal.Test.Farm))
      iex> {state["version"], state["overlay"], state["log"]}
      {1, [], []}
  """
  @spec encode_state(Branch.t()) :: {:ok, map} | {:error, Error.t()}
  def encode_state(%Branch{} = branch) do
    {:ok,
     %{
       "version" => @version,
       "overlay" => Enum.map(branch.overlay, &overlay_entry/1),
       "base" => Enum.map(branch.base, &base_entry/1),
       "log" => Enum.map(branch.log, &log_entry/1),
       "metadata" => term(branch.metadata, ["metadata"]),
       "inserted_at" => term(branch.inserted_at, ["inserted_at"])
     }}
  catch
    {:codec, message, path} ->
      {:error,
       Error.new(:storage, "branch #{branch.id} cannot be stored: #{message}", %{path: path})}
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
  def decode_state(columns, %{"version" => @version} = state) do
    {:ok,
     %Branch{
       id: columns.id,
       name: columns.name,
       domain: module!(columns.domain),
       status: status!(columns.status),
       inserted_at: unterm(state["inserted_at"]),
       metadata: unterm(state["metadata"]),
       overlay: Map.new(state["overlay"], &decode_overlay_entry/1),
       base: Map.new(state["base"], &decode_base_entry/1),
       log: Enum.map(state["log"], &decode_log_entry/1)
     }}
  catch
    {:codec, message} ->
      {:error, Error.new(:storage, "stored branch #{columns.id} cannot be loaded: #{message}")}
  end

  def decode_state(columns, %{"version" => version}) do
    {:error,
     Error.new(
       :storage,
       "stored branch #{columns.id} has state version #{version}; this Ramal reads version #{@version}"
     )}
  end

  defp status!(status) do
    case Map.fetch(@statuses, status) do
      {:ok, atom} -> atom
      :error -> throw({:codec, "unknown status #{inspect(status)}"})
    end
  end

  # -- encode -------------------------------------------------------------------------------------------------------

  defp overlay_entry({{resource, key}, entry}) do
    {op, record} =
      case entry do
        {:created, record} -> {"created", record(record)}
        {:updated, record} -> {"updated", record(record)}
        :deleted -> {"deleted", nil}
      end

    %{
      "resource" => Atom.to_string(resource),
      "key" => term(key, [inspect(resource), "overlay"]),
      "op" => op,
      "record" => record
    }
  end

  defp base_entry({{resource, key}, row}) do
    %{
      "resource" => Atom.to_string(resource),
      "key" => term(key, [inspect(resource), "base"]),
      "fingerprint" => row.fingerprint,
      "snapshot" => row.snapshot && record(row.snapshot)
    }
  end

  defp log_entry({type, resource, action, params, actor, opts, at}) do
    path = [Atom.to_string(action), inspect(resource), "log"]

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

  defp record(%resource{} = record) do
    attributes = Info.attributes(resource)
    names = MapSet.new(attributes, & &1.name)
    {unloaded, loaded} = Enum.split_with(attributes, &unloaded?(Map.fetch!(record, &1.name)))

    %{
      "attrs" =>
        Map.new(
          loaded,
          &{Atom.to_string(&1.name), attribute(&1, Map.fetch!(record, &1.name), resource)}
        ),
      "unloaded" => Enum.map(unloaded, &Atom.to_string(&1.name)),
      "extra" => extra(record, resource, names)
    }
  end

  defp unloaded?(%Ash.NotLoaded{}), do: true
  defp unloaded?(_value), do: false

  defp attribute(_attribute, nil, _resource), do: nil

  defp attribute(attribute, value, resource) do
    case Ash.Type.dump_to_embedded(attribute.type, value, attribute.constraints) do
      {:ok, dumped} ->
        term(dumped, [Atom.to_string(attribute.name), inspect(resource), "record"])

      _error ->
        throw({:codec, "#{inspect(resource)}.#{attribute.name} does not dump as its type", []})
    end
  end

  defp extra(record, resource, names) do
    default = Map.from_struct(struct(resource))

    extra =
      record
      |> Map.from_struct()
      |> Enum.reject(fn {field, value} ->
        field in names or Map.fetch!(default, field) == value
      end)
      |> Map.new()

    term(extra, ["extra", inspect(resource), "record"])
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

  # `path` is where the value sits, innermost first, so that an error can name it.
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

  defp term(%module{} = value, path) do
    fields =
      value
      |> Map.from_struct()
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

  defp label(key) when is_atom(key), do: Atom.to_string(key)
  defp label(key), do: inspect(key)

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
      {:codec, "#{inspect(value)} (a #{type_name(value)}) cannot be stored", Enum.reverse(path)}
    )
  end

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

  defp decode_base_entry(%{"resource" => resource, "key" => key} = row) do
    resource = module!(resource)
    snapshot = row["snapshot"] && decode_record(resource, row["snapshot"])
    {{resource, unterm(key)}, %{fingerprint: row["fingerprint"], snapshot: snapshot}}
  end

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

  defp decode_record(resource, %{"attrs" => attrs, "unloaded" => unloaded, "extra" => extra}) do
    attributes = Info.attributes(resource)
    known = MapSet.new(attributes, &Atom.to_string(&1.name))

    for name <- Map.keys(attrs) ++ unloaded, name not in known do
      throw({:codec, "#{inspect(resource)} no longer has the attribute #{name}"})
    end

    record =
      Enum.reduce(attributes, struct(resource), fn attribute, record ->
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
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value), do: value

  defp unterm(value) when is_list(value), do: Enum.map(value, &unterm/1)
  defp unterm(%{"$a" => name}), do: atom!(name)
  defp unterm(%{"$b" => encoded}), do: Base.decode64!(encoded)
  defp unterm(%{"$t" => items}), do: items |> Enum.map(&unterm/1) |> List.to_tuple()
  defp unterm(%{"$m" => pairs}), do: Map.new(pairs, fn [k, v] -> {unterm(k), unterm(v)} end)

  defp unterm(%{"$s" => name, "f" => fields}) do
    module = module!(name)
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
