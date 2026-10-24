defmodule Ramal.Preparation.Paged do
  @moduledoc false
  # A paginated read of a resource the branch changed is paged in Elixir, after the patch (ADR 0030).
  #
  # Ash adds a page's limit and offset, or its keyset filter, after the `before_action` hooks
  # (`paginate/3` in `lib/ash/actions/read/read.ex`, Ash 3.37), so the database would page the base and the patch would
  # add every overlay record to every page. It also counts in the database and decides `more?` from the rows the
  # database returned. None of that can be corrected afterwards, so the last `before_action` hook reads the whole
  # patched list, cuts the page out of it and hands Ash the rows with `Ash.Query.set_result/2`, which `run_query/4`
  # honours in place of the data layer, and the count with the `full_count` context key, which `fetch_count/5` honours
  # before it queries. Ash then does the rest as for a database page: `drop_pagination_extra/3` takes the extra row
  # this module leaves at the end and sets `more?`, `add_keysets/3` puts the cursors on the rows, loads, runtime
  # calculations, authorization of results and the `Ash.Page` value follow.
  #
  # This module is the pure part: whether a query is paged, and the cut. The read itself is in `Ramal.Preparation`.

  alias Ash.Page.Keyset
  alias Ash.Resource.Info
  alias Ramal.Preparation.Placeholders
  alias Ramal.Resource

  require Ash.Query

  @typedoc "The page a query asks for."
  @type plan :: %{
          required(:type) => :offset | :keyset,
          required(:limit) => pos_integer,
          required(:offset) => non_neg_integer,
          required(:after) => String.t() | nil,
          required(:before) => String.t() | nil,
          required(:filter) => term,
          required(:count?) => boolean
        }

  @doc """
  The page `query` asks for, or `nil` when the read is not one this module pages: a read without a page, a read of a
  relationship (Ash pages those per source record with a lateral join), a manual action, or a read that wants the whole
  list (see `unpaginated?/1`).
  """
  @spec plan(Ash.Query.t()) :: plan | nil
  def plan(query), do: plan(query, false)

  @doc """
  The page a lateral relationship load asks for, per source record (ADR 0038), or `nil` when the load has no page.
  """
  @spec lateral_plan(Ash.Query.t()) :: plan | nil
  def lateral_plan(query), do: plan(query, true)

  defp plan(%{page: page, action: %{pagination: %{} = pagination, manual: nil}} = query, lateral?)
       when is_list(page) do
    if is_integer(page[:limit]) and kind?(query, lateral?) and not unpaginated?(query) do
      %{
        type: type(page, pagination),
        limit: limit(query, page[:limit], pagination),
        offset: page[:offset] || 0,
        after: page[:after],
        before: page[:before],
        filter: page[:filter],
        count?: count?(page, pagination)
      }
    end
  end

  defp plan(_query, _lateral?), do: nil

  # Ash gives an unpaginated read (`Ash.Actions.Read.unpaginated_read/3`) the action's `default_limit` as its page and
  # skips the `paginate` step, and the query keeps no mark of it. The reads whose callers can be told apart are left
  # alone: Ramal's own (`Ramal.Resource.read_all/2`), the ones Ash makes for a policy or a filter on a relationship
  # (`internal?`), and the source read of a bulk update or destroy. A bulk action with the stream strategy reads its
  # source with `Ash.stream!/2` and so carries the same `query_for`; the pages of that stream are told apart by the
  # `bypass_max_page_size?` mark `do_stream/4` of `lib/ash/actions/read/stream.ex` sets, and are cut like any page.
  # Any other is caught after the data layer, where a query with no limit was not paginated: the preparation then
  # returns the whole list.
  defp unpaginated?(query) do
    query.context[:ramal][:whole?] == true or Ramal.Ash.internal_read?(query) or
      (Ramal.Ash.bulk_read_for(query) in [:bulk_update, :bulk_destroy] and
         not Ramal.Ash.bypass_max_page_size?(query))
  end

  # A relationship load is read with `accessing_from`; a many-to-many or limited has_many load carries the source
  # records of a lateral join (`lib/ash/actions/read/relationships.ex`). Ash pages the second kind per source record, a
  # page of the first is cut from the rows it reads (and never reaches the data layer as a page).
  defp kind?(query, true), do: Ramal.Ash.lateral_load?(query)

  defp kind?(query, false),
    do: not (Ramal.Ash.relationship_read?(query) or Ramal.Ash.lateral_load?(query))

  # `pagination_type/2` of `lib/ash/actions/read/read.ex`: a cursor means keyset, an offset means offset, otherwise the
  # first of the types the action allows.
  defp type(page, pagination) do
    cond do
      page[:before] || page[:after] -> :keyset
      page[:offset] -> :offset
      pagination.keyset? -> :keyset
      true -> :offset
    end
  end

  # `limit/4` of the same file: the page size, the query's own limit and the action's `max_page_size`, whichever is
  # smallest.
  defp limit(query, page_size, pagination) do
    max_page_size =
      if Ramal.Ash.bypass_max_page_size?(query), do: nil, else: pagination.max_page_size

    [page_size, query.limit, max_page_size] |> Enum.filter(&is_integer/1) |> Enum.min()
  end

  # `fetch_count/5` of the same file.
  defp count?(page, pagination) do
    page[:count] == true or (page[:count] != false and pagination.countable == :by_default)
  end

  @doc """
  `query` with the stable sort Ash appends to a paginated read (`do_paginate/3`), so that rows that tie on the sort
  keep one order from one page to the next.
  """
  @spec stable_sort(Ash.Query.t()) :: Ash.Query.t()
  def stable_sort(query) do
    if Ramal.Ash.sorting_on_identity?(query) do
      query
    else
      Ash.Query.sort(
        query,
        query.action.pagination.stable_sort || Info.primary_key(query.resource)
      )
    end
  end

  @doc """
  Cuts the page out of the patched and sorted `rows`: the rows Ash would have fetched from the database (one more than
  the page, so Ash can tell `more?`) and the count of the whole list.

  A `before` page comes back in the reversed order the database would have produced, because Ash reverses it again.
  """
  @spec cut(Ash.Query.t(), plan, [struct]) ::
          {:ok, [struct], non_neg_integer} | {:error, term}
  def cut(query, plan, rows) do
    count = length(rows)

    with {:ok, rows} <- narrow(query, rows, plan.filter),
         {:ok, rows} <- after_cursor(query, rows, plan) do
      {:ok, take(rows, plan), count}
    end
  end

  @doc """
  `cut/3` for a lateral relationship load: `rows` are tagged with the source record they belong to
  (`__lateral_join_source__`) and each source is paged on its own, as the database's lateral join does.
  """
  @spec cut_by_source(Ash.Query.t(), plan, [struct]) :: {:ok, [struct]} | {:error, term}
  def cut_by_source(query, plan, rows) do
    rows
    |> Enum.group_by(&Ramal.Ash.lateral_tag/1)
    |> Enum.reduce_while({:ok, []}, fn {_source, group}, {:ok, acc} ->
      case cut(query, plan, group) do
        {:ok, page, _count} -> {:cont, {:ok, acc ++ page}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp take(rows, %{type: :offset, offset: offset, limit: limit}),
    do: rows |> Enum.drop(offset) |> Enum.take(limit + 1)

  defp take(rows, %{before: before, limit: limit}) when is_binary(before),
    do: rows |> Enum.take(-(limit + 1)) |> Enum.reverse()

  defp take(rows, %{limit: limit}), do: Enum.take(rows, limit + 1)

  # The `filter` option of a page narrows the rows the page is cut from, not the count.
  defp narrow(_query, rows, nil), do: {:ok, rows}

  defp narrow(query, rows, filter) do
    keep(query, rows, Ash.Query.filter(Ash.Query.new(query.resource), ^filter).filter)
  end

  defp after_cursor(query, rows, %{type: :keyset} = plan) do
    {cursor, side} = if plan.before, do: {plan.before, :before}, else: {plan.after, :after}

    if is_nil(cursor) do
      {:ok, rows}
    else
      with {:ok, filter} <- Keyset.filter(query, cursor, query.sort, side) do
        # A placeholder key is compared as the key it becomes at the merge: after every real one (ADR 0042).
        {view, filter} = Placeholders.keyset_view(filter, query.resource)
        keep(query, rows, Ramal.Ash.do_filter(Ash.Query.new(query.resource), filter).filter, view)
      end
    end
  end

  defp after_cursor(_query, rows, _plan), do: {:ok, rows}

  # The same expression the database would have been given, judged by `Ash.Filter.Runtime` on the patched rows, in
  # their order.
  # `view` is how a row is shown to the filter, which is not how it is returned.
  defp keep(query, rows, filter, view \\ & &1) do
    with {:ok, matches} <- Ramal.Ash.filter_matches(query.domain, Enum.map(rows, view), filter) do
      keys = MapSet.new(matches, &Resource.key(query.resource, &1))
      {:ok, Enum.filter(rows, &MapSet.member?(keys, Resource.key(query.resource, view.(&1))))}
    end
  end
end
