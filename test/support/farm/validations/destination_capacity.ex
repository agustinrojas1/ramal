defmodule Ramal.Test.Farm.Validations.DestinationCapacity do
  @moduledoc false
  # Reads the destination's herds through Ash on purpose: inside a branch that read goes through
  # Ramal's preparation, so the validation sees moves made earlier in the same branch.
  use Ash.Resource.Validation

  require Ash.Query

  alias Ramal.Test.Farm.{Herd, Paddock}

  @impl true
  def validate(changeset, _opts, _context) do
    destination_id = Ash.Changeset.get_attribute(changeset, :paddock_id)
    herd_id = Ash.Changeset.get_attribute(changeset, :id)
    head = Ash.Changeset.get_attribute(changeset, :head)

    with destination_id when not is_nil(destination_id) <- destination_id,
         {:ok, paddock} <- Ash.get(Paddock, destination_id, authorize?: false),
         {:ok, herds} <-
           Herd |> Ash.Query.filter(paddock_id == ^destination_id) |> Ash.read(authorize?: false) do
      present = herds |> Enum.reject(&(&1.id == herd_id)) |> Enum.map(& &1.head) |> Enum.sum()

      if present + head <= paddock.capacity_head do
        :ok
      else
        {:error,
         field: :to_paddock_id,
         message:
           "paddock #{paddock.name} holds #{paddock.capacity_head} head and already has #{present}"}
      end
    else
      nil -> :ok
      {:error, error} -> {:error, error}
    end
  end
end
