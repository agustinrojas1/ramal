defmodule Ramal.Test.Farm.Commands do
  @moduledoc false
  # A host's command layer above Ash (#208): a plain module that validates across resources, calls Ash actions and
  # returns what is needed to undo the command. Run inside a branch it is captured as Ash writes; run in the base after
  # `Ramal.stale/2` it is the host's own commit.
  alias Ramal.Test.Farm.{Herd, Paddock}

  @spec move_herd(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{herd_id: Ecto.UUID.t(), from_paddock_id: Ecto.UUID.t()}} | {:error, atom}
  def move_herd(herd_id, to_paddock_id) do
    herd = Ash.get!(Herd, herd_id, authorize?: false)
    paddock = Ash.get!(Paddock, to_paddock_id, authorize?: false)

    if herd.paddock_id == paddock.id do
      {:error, :already_there}
    else
      herd
      |> Ash.Changeset.for_update(:move, %{to_paddock_id: paddock.id}, authorize?: false)
      |> Ash.update!()

      {:ok, %{herd_id: herd.id, from_paddock_id: herd.paddock_id}}
    end
  end
end
