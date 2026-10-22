defmodule Ramal.Resource.Transformer do
  @moduledoc false
  # Installs the global read preparation on resources that use Ramal.Resource and have not set `branchable? false`.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    if Transformer.get_option(dsl_state, [:ramal], :branchable?, true) do
      Builder.add_preparation(dsl_state, Ramal.Preparation)
    else
      {:ok, dsl_state}
    end
  end
end
