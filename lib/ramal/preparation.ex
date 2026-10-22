defmodule Ramal.Preparation do
  @moduledoc """
  The read preparation `Ramal.Resource` installs on every read action.

  Inside `Ramal.run/2` it makes a read see the base data patched with the branch's overlay. Outside a branch it
  returns the query untouched, so the action behaves as if the extension were absent.

  How it works, confirmed against Ash 3.37 (`lib/ash/actions/read/read.ex`):

    * `Ash.Query.before_action/2` hooks run after all preparations and before the data-layer query is built, so a hook
      there can still remove `limit` and `offset`. The base query keeps its filter, so Postgres still narrows the rows.
    * `Ash.Query.after_action/2` hooks receive the base rows after the data layer and before relationship loads,
      runtime calculations and the not-found check of `Ash.get/3`. Patching there means loads, calculations and
      `Ash.get/3` all see the patched rows.
    * A relationship load runs a read on the related resource through its own preparation, in a task that does not
      inherit the process dictionary. The branch id therefore also travels in the query's `shared` context, which
      Ash copies into related queries (`lib/ash/actions/read/relationships.ex`).
    * Filters are evaluated on overlay records with `Ash.Filter.Runtime.filter_matches/4` and sorting uses
      Ash.Actions.Sort.runtime_sort/3.

  Every base row the read returns is also fingerprinted (`Ramal.Resource.fingerprint/1`) for the staleness check at
  merge time, unless the query selected only some attributes.

  Known limits in 0.1, documented rather than hidden:

    * aggregates and calculations the data layer computes do not see the overlay; reading one emits
      `[:ramal, :read, :unpatched_aggregate]`;
    * overlay records are added without running the action's `authorize_results` checks, though the query's filter,
      including any policy filter, is applied to them;
    * paginated reads (`page:`) are paged by the database and patched afterwards, so pages can be short or miss rows
      created in the branch, and `count` is the database's.

  ## Example

      # With a branch current, the same call returns rows created in the branch.
      Ramal.run!(branch, fn -> Ash.read!(MyApp.Farm.Herd) end)
  """
  use Ash.Resource.Preparation

  alias Ash.Actions.Sort
  alias Ash.Filter.Runtime
  alias Ash.Resource.Info
  alias Ramal.Branch.Server
  alias Ramal.{Current, Overlay, Resource, Telemetry}

  @impl true
  def prepare(query, _opts, _context) do
    case Current.resolve(query.context) do
      nil ->
        query

      id ->
        query
        |> Ash.Query.set_context(Current.shared_context(id))
        |> Ash.Query.before_action(&before_data_layer(&1, id))
        |> Ash.Query.after_action(&after_data_layer(&1, &2, id))
    end
  end

  # Without overlay entries for this resource nothing changes, so the query keeps its limit and offset and Postgres
  # does the paging. Stripping them is only needed when the overlay may add or remove rows.
  defp before_data_layer(query, id) do
    warn_unpatched_aggregates(query, id)

    case Server.slice(id, query.resource) do
      {:ok, slice} when map_size(slice) == 0 ->
        Ash.Query.set_context(query, %{ramal: %{slice: slice, limit: nil, offset: nil}})

      {:ok, slice} ->
        query
        |> Ash.Query.set_context(%{
          ramal: %{slice: slice, limit: query.limit, offset: query.offset}
        })
        |> Ash.Query.unset([:limit, :offset])

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end

  defp after_data_layer(query, results, id) do
    %{slice: slice, limit: limit, offset: offset} = query.context.ramal
    record_fingerprints(query.resource, results, id)

    if map_size(slice) == 0 do
      {:ok, results}
    else
      started = System.monotonic_time()

      with {:ok, patched} <- patch(query, results, slice, limit, offset) do
        Telemetry.read(
          :patch,
          %{
            base_rows: length(results),
            overlay_rows: map_size(slice),
            result_rows: length(patched),
            duration: System.monotonic_time() - started
          },
          %{branch_id: id, resource: query.resource}
        )

        {:ok, patched}
      end
    end
  end

  # Staleness at merge time is measured from the first time the branch saw a row, so every base row a read returns is
  # fingerprinted before it is patched. Rows with an attribute that was not selected cannot be compared and are skipped.
  defp record_fingerprints(resource, results, id) do
    fingerprints =
      for row <- results,
          fingerprint = Resource.fingerprint(row),
          into: %{},
          do: {{resource, Resource.key(resource, row)}, fingerprint}

    if fingerprints != %{}, do: Server.fingerprints(id, fingerprints)
    :ok
  end

  defp patch(query, results, slice, limit, offset) do
    resource = query.resource

    with {:ok, matching} <- matching_keys(query, slice) do
      patched =
        results
        |> Overlay.patch(slice, &MapSet.member?(matching, Resource.key(resource, &1)),
          key: &Resource.key(resource, &1)
        )
        |> sort(query)
        |> Enum.drop(offset || 0)
        |> take(limit)
        |> Enum.map(&apply_select(&1, query, slice))

      {:ok, patched}
    end
  end

  # The keys of overlay records that satisfy the query's filter. Computed once for the whole slice, so a filter that
  # needs relationship data loads it in one batch.
  defp matching_keys(query, slice) do
    records = for {_key, {_kind, record}} <- slice, do: record

    with {:ok, matches} <-
           Runtime.filter_matches(query.domain, records, query.filter) do
      {:ok, MapSet.new(matches, &Resource.key(query.resource, &1))}
    end
  end

  # Base rows come back from Postgres with only the selected attributes loaded. Overlay records are whole structs, so
  # they are trimmed the same way after filtering and sorting, which need every attribute.
  defp apply_select(record, %{select: select} = query, slice) when is_list(select) do
    if match?({_kind, _record}, Map.get(slice, Resource.key(query.resource, record))) do
      keep = select ++ Info.primary_key(query.resource)

      query.resource
      |> Info.attributes()
      |> Enum.reject(&(&1.name in keep))
      |> Enum.reduce(record, fn attribute, record ->
        Map.put(record, attribute.name, %Ash.NotLoaded{
          type: :attribute,
          field: attribute.name,
          resource: query.resource
        })
      end)
    else
      record
    end
  end

  defp apply_select(record, _query, _slice), do: record

  defp sort(rows, %{sort: sort} = query) when sort not in [nil, []] do
    Sort.runtime_sort(rows, sort, resource: query.resource, domain: query.domain)
  end

  defp sort(rows, _query), do: rows

  defp take(rows, nil), do: rows
  defp take(rows, limit), do: Enum.take(rows, limit)

  defp warn_unpatched_aggregates(query, id) do
    if selects_aggregate?(query) do
      Telemetry.read(:unpatched_aggregate, %{count: 1}, %{branch_id: id, resource: query.resource})
    end
  end

  defp selects_aggregate?(query) do
    map_size(query.aggregates) > 0 or
      Enum.any?(List.wrap(query.load), fn
        name when is_atom(name) -> Info.aggregate(query.resource, name) != nil
        {name, _} when is_atom(name) -> Info.aggregate(query.resource, name) != nil
        _ -> false
      end)
  end
end
