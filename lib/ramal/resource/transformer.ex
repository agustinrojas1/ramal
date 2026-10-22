defmodule Ramal.Resource.Transformer do
  @moduledoc false
  # Installs the global read preparation and the write change on resources that use Ramal.Resource and have not set
  # `branchable? false`, and relaxes `require_atomic?` on their update and destroy actions (ADR 0005).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  # The actions section is only complete once Ash has expanded `defaults` and chosen primary actions.
  @impl true
  def after?(Ash.Resource.Transformers.DefaultAccept), do: true
  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    if Transformer.get_option(dsl_state, [:ramal], :branchable?, true) do
      with {:ok, dsl_state} <- Builder.add_preparation(dsl_state, Ramal.Preparation),
           {:ok, dsl_state} <-
             Builder.add_change(dsl_state, Ramal.Capture, on: [:create, :update, :destroy]) do
        {:ok, allow_non_atomic(dsl_state)}
      end
    else
      {:ok, dsl_state}
    end
  end

  # Ash tries an atomic update first, which updates the row in the database without running change/3 or any hook.
  # Ramal.Capture reports itself as not atomic when a branch is current; with `require_atomic? true` Ash would then
  # refuse the action instead of falling back to the non-atomic path.
  defp allow_non_atomic(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:update, :destroy] and Map.get(&1, :require_atomic?) == true))
    |> Enum.reduce(dsl_state, fn action, dsl_state ->
      Transformer.replace_entity(
        dsl_state,
        [:actions],
        %{action | require_atomic?: false},
        &(&1.type == action.type and &1.name == action.name)
      )
    end)
  end
end
