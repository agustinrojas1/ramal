defmodule RamalLive.Column do
  @moduledoc false
  # What the inspector shows for one branch, as plain data: strings and numbers, no structs from Ash. Building it is the
  # only place a branch and its diff are looked at, so the templates stay free of logic and this module is tested
  # without Phoenix.

  alias Ash.Resource.Info
  alias Ramal.{Branch, Change}

  # A branch can hold thousands of changes; the page shows the first ones and says how many it left out.
  @max_changes 100
  @max_value_length 80

  @type row :: %{attribute: String.t(), before: String.t(), after: String.t()}
  @type change :: %{
          kind: Change.kind(),
          resource: String.t(),
          resource_title: String.t(),
          key: String.t(),
          rows: [row]
        }
  @typedoc "The outcome of the last action the person took on the column; it stays until the next action."
  @type notice :: %{kind: :error | :info, text: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          status: Branch.status(),
          inserted_at: DateTime.t(),
          overlay_size: non_neg_integer,
          write_count: non_neg_integer,
          forked_from: String.t() | nil,
          proposal: %{proposer: String.t(), reason: String.t() | nil} | nil,
          changes: [change],
          hidden_changes: non_neg_integer,
          busy: nil | :merge | :approve,
          problem: String.t() | nil,
          notice: notice | nil
        }

  @enforce_keys [:id, :status, :inserted_at]
  defstruct [
    :id,
    :name,
    :status,
    :inserted_at,
    :forked_from,
    :proposal,
    overlay_size: 0,
    write_count: 0,
    changes: [],
    hidden_changes: 0,
    busy: nil,
    problem: nil,
    notice: nil
  ]

  @doc "Builds the column of `branch`, whose diff is `changes` (`Ramal.diff/1`)."
  @spec build(Branch.t(), [Change.t()]) :: t
  def build(%Branch{} = branch, changes) when is_list(changes) do
    {shown, hidden} = Enum.split(changes, @max_changes)

    %__MODULE__{
      id: branch.id,
      name: branch.name,
      status: branch.status,
      inserted_at: branch.inserted_at,
      overlay_size: map_size(branch.overlay),
      write_count: length(branch.log),
      forked_from: Map.get(branch.metadata, :forked_from),
      proposal: proposal(branch.proposal),
      changes: Enum.map(shown, &change/1),
      hidden_changes: length(hidden)
    }
  end

  @doc """
  The column of a branch whose diff could not be computed: it keeps the branch's facts and shows the problem instead of
  the rows. Unlike a `notice`, which reports what the person just did and survives a refresh, a problem is recomputed
  with every refresh.
  """
  @spec build_unreadable(Branch.t(), String.t()) :: t
  def build_unreadable(%Branch{} = branch, message) do
    %{build(branch, []) | problem: message}
  end

  @doc """
  Columns in board order: open branches, then proposals, each oldest first.

  A column ranks by `{status, inserted_at, id}`, so the order is total and stable.
  """
  @spec sort([t]) :: [t]
  def sort(columns) do
    Enum.sort_by(
      columns,
      &{status_rank(&1.status), DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}
    )
  end

  defp status_rank(:open), do: 0
  defp status_rank(:proposed), do: 1
  defp status_rank(_other), do: 2

  @doc "How many changes the branch holds, shown or not."
  @spec change_count(t) :: non_neg_integer
  def change_count(%__MODULE__{changes: changes, hidden_changes: hidden}),
    do: length(changes) + hidden

  @doc "The first eight characters of an id, enough to tell branches apart on screen."
  @spec short_id(String.t()) :: String.t()
  def short_id(id), do: String.slice(id, 0, 8)

  @doc """
  How long ago `at` was, as one number and one unit: `"12s"`, `"4m"`, `"3h"`, `"2d"`. A time in the future reads `"0s"`.
  """
  @spec age(DateTime.t(), DateTime.t()) :: String.t()
  def age(%DateTime{} = at, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  @doc """
  A value as it appears in a before/after cell: strings as they are, everything else as `inspect/2` prints it, cut to
  80 characters.
  """
  @spec format_value(term) :: String.t()
  def format_value(value) when is_binary(value) do
    if String.printable?(value), do: truncate(value), else: truncate(inspect(value))
  end

  def format_value(value),
    do: value |> inspect(limit: 8, printable_limit: @max_value_length) |> truncate()

  defp truncate(string) do
    if String.length(string) > @max_value_length do
      String.slice(string, 0, @max_value_length - 1) <> "…"
    else
      string
    end
  end

  defp change(%Change{} = change) do
    %{
      kind: change.kind,
      resource: change.resource |> Module.split() |> List.last(),
      resource_title: inspect(change.resource),
      key: format_value(change.key),
      rows:
        change.changes
        |> Enum.sort_by(fn {attribute, _} -> attribute end)
        |> Enum.map(fn {attribute, {before, after_value}} ->
          show(change.resource, attribute, before, after_value)
        end)
    }
  end

  # An attribute marked `sensitive?` (a password hash, a token) is never printed: the row stays, so the reviewer sees
  # that it changed, without its values. The diff is for people to review, and a page that shows secrets to everyone
  # allowed to merge is a new place for them to leak from.
  @redacted "[redacted]"

  defp show(resource, attribute, before, after_value) do
    {before, after_value} =
      if sensitive?(resource, attribute),
        do: {@redacted, @redacted},
        else: {format_value(before), format_value(after_value)}

    %{attribute: Atom.to_string(attribute), before: before, after: after_value}
  end

  defp sensitive?(resource, attribute) do
    Info.resource?(resource) and
      match?(%{sensitive?: true}, Info.field(resource, attribute))
  end

  defp proposal(nil), do: nil

  defp proposal(%{proposer: proposer, reason: reason}) do
    %{proposer: if(proposer, do: format_value(proposer), else: "unknown"), reason: reason}
  end
end
