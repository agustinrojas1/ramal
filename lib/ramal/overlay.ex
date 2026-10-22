defmodule Ramal.Overlay do
  @moduledoc """
  The overlay: what a branch changed, as a plain map.

  Keys are `{resource, key}` pairs, called refs here, where `key` is the row's primary key. Values are
  `{:created, record}`, `{:updated, record}` or `:deleted`. The record is whatever the caller stores, normally the
  full Ash struct as the action left it.

  Everything in this module is a pure function over maps and lists. It never calls Ash, so it is tested with plain
  maps. The pieces that need Ash (running the filter, sorting by Ash expressions, listing attributes) arrive as
  functions from the caller.

  ## How entries combine

  The overlay only records the net effect on the base, so putting a second entry for a ref follows these rules:

  | existing | `put_created` | `put_updated` | `put_deleted` |
  |---|---|---|---|
  | none | `:created` | `:updated` | `:deleted` |
  | `:created` | `:created` (replaced) | `:created` (record replaced) | no entry: the base never had the row |
  | `:updated` | `:updated` | `:updated` | `:deleted` |
  | `:deleted` | `:updated`: the base row is replaced | `:updated` | `:deleted` |

  A `:deleted` entry therefore always means the base had the row. Rejecting a duplicate primary key or an update of
  a missing row is the write layer's job (the data layer would do it on the real base); the overlay does not police it.

  ## Example

      iex> ref = {MyApp.Herd, "R7"}
      iex> overlay = Ramal.Overlay.new() |> Ramal.Overlay.put_updated(ref, %{id: "R7", name: "R7b"})
      iex> Ramal.Overlay.slice(overlay, MyApp.Herd)
      %{"R7" => {:updated, %{id: "R7", name: "R7b"}}}
  """

  alias Ramal.{Change, Error}

  @type resource :: module
  @type key :: term
  @type ref :: {resource, key}
  @type record :: map
  @type entry :: {:created, record} | {:updated, record} | :deleted
  @type t :: %{optional(ref) => entry}
  @type slice :: %{optional(key) => entry}

  @doc """
  An empty overlay.

  ## Example

      iex> Ramal.Overlay.new()
      %{}
  """
  @spec new() :: t
  def new, do: %{}

  @doc """
  Records that the branch created the row `ref` with `record`.

  See the table in the module doc for how it combines with an existing entry.

  ## Example

      iex> Ramal.Overlay.put_created(%{}, {MyApp.Herd, 1}, %{id: 1})
      %{{MyApp.Herd, 1} => {:created, %{id: 1}}}
  """
  @spec put_created(t, ref, record) :: t
  def put_created(overlay, ref, record) do
    case Map.get(overlay, ref) do
      :deleted -> Map.put(overlay, ref, {:updated, record})
      {:updated, _} -> Map.put(overlay, ref, {:updated, record})
      _none_or_created -> Map.put(overlay, ref, {:created, record})
    end
  end

  @doc """
  Records that the branch updated the row `ref`; `record` is the row as the update left it.

  A row the branch created stays `:created`, with the new record.

  ## Example

      iex> overlay = Ramal.Overlay.put_created(%{}, {MyApp.Herd, 1}, %{id: 1, v: 1})
      iex> Ramal.Overlay.put_updated(overlay, {MyApp.Herd, 1}, %{id: 1, v: 2})
      %{{MyApp.Herd, 1} => {:created, %{id: 1, v: 2}}}
  """
  @spec put_updated(t, ref, record) :: t
  def put_updated(overlay, ref, record) do
    case Map.get(overlay, ref) do
      {:created, _} -> Map.put(overlay, ref, {:created, record})
      _none_updated_or_deleted -> Map.put(overlay, ref, {:updated, record})
    end
  end

  @doc """
  Records that the branch deleted the row `ref`.

  Deleting a row the branch itself created removes the entry: the base never had that row, so there is nothing to hide.

  ## Example

      iex> overlay = Ramal.Overlay.put_deleted(%{}, {MyApp.Herd, 1})
      iex> overlay
      %{{MyApp.Herd, 1} => :deleted}
      iex> overlay |> Ramal.Overlay.put_created({MyApp.Herd, 2}, %{id: 2}) |> Ramal.Overlay.put_deleted({MyApp.Herd, 2})
      %{{MyApp.Herd, 1} => :deleted}
  """
  @spec put_deleted(t, ref) :: t
  def put_deleted(overlay, ref) do
    case Map.get(overlay, ref) do
      {:created, _} -> Map.delete(overlay, ref)
      _none_updated_or_deleted -> Map.put(overlay, ref, :deleted)
    end
  end

  @doc """
  The entries for one resource, keyed by primary key.

  ## Example

      iex> overlay = %{{MyApp.Herd, 1} => :deleted, {MyApp.Paddock, 9} => {:created, %{id: 9}}}
      iex> Ramal.Overlay.slice(overlay, MyApp.Herd)
      %{1 => :deleted}
  """
  @spec slice(t, resource) :: slice
  def slice(overlay, resource) do
    for {{^resource, key}, entry} <- overlay, into: %{}, do: {key, entry}
  end

  @doc """
  Applies a resource's overlay slice to the rows the base returned for a query.

  `base_rows` are the rows the data layer returned for the query's filter, without limit and offset. The result is
  what the same query would return on a base that already held the branch's changes:

  1. a base row whose key is `:deleted` in the slice is dropped;
  2. a base row whose key is `:updated` is replaced by the overlay record, or dropped when that record no longer
     satisfies `predicate`;
  3. an overlay record the base did not return is added when it satisfies `predicate`. This covers created rows and
     updated rows that only match the filter after the update;
  4. the rows are sorted, then `offset` and `limit` are applied. Doing that last is what lets a row created in the
     branch appear in a limited query.

  `predicate` is called only on overlay records, since the base already applied the filter to its own rows. Callers
  evaluate the query's filter in it, for example with `Ash.Filter.Runtime`.

  ## Options

    * `:key` (required) - a function returning the primary key of a row, the same keys the slice uses
    * `:sort` - a comparator `(a, b -> boolean)` as `Enum.sort/2` takes it; return `true` when `a` goes before or
      equal to `b`, which keeps the sort stable. Without it, base order is kept and added rows follow in key order
    * `:offset` - rows to skip after sorting, default `0`
    * `:limit` - the maximum number of rows, default no limit
    * `:replace` - a function `(base_row, overlay_record -> record)` that builds the row that takes a base row's place,
      for state the base row carries and the overlay record cannot, default the overlay record itself

  ## Example

      iex> base = [%{id: 1, n: 10}, %{id: 2, n: 20}]
      iex> slice = %{2 => :deleted, 3 => {:created, %{id: 3, n: 30}}}
      iex> Ramal.Overlay.patch(base, slice, fn _ -> true end, key: & &1.id, sort: &(&1.n >= &2.n), limit: 2)
      [%{id: 3, n: 30}, %{id: 1, n: 10}]
  """
  @spec patch([record], slice, (record -> as_boolean(term)), keyword) :: [record]
  def patch(base_rows, slice, predicate, opts) when is_function(predicate, 1) do
    key_fun = Keyword.fetch!(opts, :key)
    replace = Keyword.get(opts, :replace, fn _row, record -> record end)

    {kept, seen} =
      Enum.flat_map_reduce(base_rows, MapSet.new(), fn row, seen ->
        key = key_fun.(row)
        {patch_base_row(row, Map.get(slice, key), predicate, replace), MapSet.put(seen, key)}
      end)

    added =
      slice
      |> Enum.reject(fn {key, _entry} -> MapSet.member?(seen, key) end)
      |> Enum.sort_by(fn {key, _entry} -> key end)
      |> Enum.flat_map(fn
        {_key, {_kind, record}} -> if predicate.(record), do: [record], else: []
        {_key, :deleted} -> []
      end)

    (kept ++ added)
    |> sort(opts[:sort])
    |> Enum.drop(Keyword.get(opts, :offset, 0))
    |> take(opts[:limit])
  end

  defp patch_base_row(row, nil, _predicate, _replace), do: [row]
  defp patch_base_row(_row, :deleted, _predicate, _replace), do: []

  defp patch_base_row(row, {_kind, record}, predicate, replace) do
    if predicate.(record), do: [replace.(row, record)], else: []
  end

  defp sort(rows, nil), do: rows
  defp sort(rows, comparator) when is_function(comparator, 2), do: Enum.sort(rows, comparator)

  defp take(rows, nil), do: rows
  defp take(rows, limit) when is_integer(limit) and limit >= 0, do: Enum.take(rows, limit)

  @doc """
  The overlay as a list of `Ramal.Change` structs, computed against the base rows as the branch first saw them.

  `base` maps each ref the branch touched on an existing row to that row's snapshot. It never queries anything: the
  snapshot is what the branch kept at first touch. Created rows need no snapshot. Rows whose updates netted out to
  no difference are left out.

  The result is sorted by ref so it is deterministic. The overlay is a map and does not remember the order of writes;
  `Ramal.diff/1` orders changes by the branch log.

  Returns `{:error, %Ramal.Error{reason: :missing_snapshot}}` when an updated or deleted entry has no snapshot, which
  means the write layer forgot to record one.

  ## Options

    * `:attributes` - a function from a record to a `%{atom => value}` map. Defaults to the record's own keys without
      the `__meta__`-style ones. The Ash-aware caller passes one built from the resource's attributes.

  ## Example

      iex> overlay = %{{MyApp.Herd, 1} => {:updated, %{id: 1, name: "b"}}}
      iex> base = %{{MyApp.Herd, 1} => %{id: 1, name: "a"}}
      iex> {:ok, [change]} = Ramal.Overlay.diff(overlay, base)
      iex> {change.kind, change.changes}
      {:updated, %{name: {"a", "b"}}}
  """
  @spec diff(t, %{optional(ref) => record}, keyword) :: {:ok, [Change.t()]} | {:error, Error.t()}
  def diff(overlay, base, opts \\ []) do
    attributes = Keyword.get(opts, :attributes, &plain_attributes/1)

    overlay
    |> Enum.sort_by(fn {ref, _entry} -> ref end)
    |> Enum.reduce_while({:ok, []}, fn {ref, entry}, {:ok, acc} ->
      case change(ref, entry, Map.fetch(base, ref), attributes) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, change} -> {:cont, {:ok, [change | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      error -> error
    end
  end

  defp change({resource, key}, {:created, record}, _snapshot, attributes) do
    changes = Map.new(attributes.(record), fn {name, value} -> {name, {nil, value}} end)
    {:ok, %Change{resource: resource, key: key, kind: :created, changes: changes}}
  end

  defp change({resource, key}, {:updated, record}, {:ok, snapshot}, attributes) do
    before = attributes.(snapshot)
    after_attributes = attributes.(record)

    changes =
      before
      |> Map.keys()
      |> Enum.concat(Map.keys(after_attributes))
      |> Enum.uniq()
      |> Enum.flat_map(fn name ->
        old = Map.get(before, name)
        new = Map.get(after_attributes, name)
        if old == new, do: [], else: [{name, {old, new}}]
      end)
      |> Map.new()

    if changes == %{} do
      {:ok, nil}
    else
      {:ok, %Change{resource: resource, key: key, kind: :updated, changes: changes}}
    end
  end

  defp change({resource, key}, :deleted, {:ok, snapshot}, attributes) do
    changes = Map.new(attributes.(snapshot), fn {name, value} -> {name, {value, nil}} end)
    {:ok, %Change{resource: resource, key: key, kind: :deleted, changes: changes}}
  end

  defp change({resource, key}, _entry, :error, _attributes) do
    {:error,
     Error.new(
       :missing_snapshot,
       "the branch changed #{inspect(resource)} #{inspect(key)} but kept no copy of the row as it first saw it",
       %{resource: resource, key: key}
     )}
  end

  # Ash structs carry bookkeeping under keys such as __meta__ and __metadata__; they are not row data.
  defp plain_attributes(record) do
    record
    |> Map.delete(:__struct__)
    |> Enum.reject(fn {name, _value} -> internal?(name) end)
    |> Map.new()
  end

  defp internal?(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.starts_with?("__")

  defp internal?(_name), do: false

  @doc """
  Applies `other`'s entries on top of `overlay`, as if each had been put in turn.

  Forking uses it: a fork starts as `merge_into(new(), parent)`. Because overlays are immutable maps, the fork and
  the parent never see each other's later changes. The combination rules are the ones in the module doc, so merging
  a `:deleted` entry over a `:created` one removes the row from the result.

  ## Example

      iex> parent = %{{MyApp.Herd, 1} => {:created, %{id: 1}}}
      iex> Ramal.Overlay.merge_into(Ramal.Overlay.new(), parent) == parent
      true
  """
  @spec merge_into(t, t) :: t
  def merge_into(overlay, other) do
    Enum.reduce(other, overlay, fn
      {ref, {:created, record}}, acc -> put_created(acc, ref, record)
      {ref, {:updated, record}}, acc -> put_updated(acc, ref, record)
      {ref, :deleted}, acc -> put_deleted(acc, ref)
    end)
  end
end
