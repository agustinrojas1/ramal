defmodule Bench.RamalSide do
  @moduledoc false
  # The Ramal calls the benchmark makes, written the way a host would write them.

  require Ash.Query

  alias Bench.Item

  def branch do
    {:ok, branch} = Ramal.branch(Bench.Domain)
    branch
  end

  def fork(branch) do
    {:ok, fork} = Ramal.fork(branch)
    fork
  end

  def update(branch, id, score) do
    Ramal.run!(branch, fn ->
      Item |> Ash.get!(id) |> Ash.update!(%{score: score})
    end)
  end

  def read(branch, bucket_bound) do
    Ramal.run!(branch, fn -> read_base(bucket_bound) end)
  end

  def read_note(branch), do: Ramal.run!(branch, fn -> Ash.read!(Bench.Note) end)

  def read_note_base, do: Ash.read!(Bench.Note)

  def sum(branch), do: Ramal.run!(branch, fn -> Ramal.aggregate!(Item, :sum, :score) || 0 end)

  def diff(branch) do
    {:ok, changes} = Ramal.diff(branch)
    changes
  end

  def merge(branch), do: {:ok, _} = Ramal.merge(branch, authorize?: false)

  def discard(branch), do: :ok = Ramal.discard(branch)

  # The same read with no branch: Ash and the data layer only.
  def read_base(bucket_bound) do
    Item |> Ash.Query.filter(bucket < ^bucket_bound) |> Ash.read!()
  end

  def sum_base, do: Ash.sum!(Item, :score) || 0
end
