defmodule Ramal.Resource do
  @moduledoc """
  The Spark extension that makes an Ash resource branchable.

  Add it to a resource and every read action of that resource is patched with the current branch's changes:

      defmodule MyApp.Farm.Herd do
        use Ash.Resource,
          domain: MyApp.Farm,
          data_layer: AshPostgres.DataLayer,
          extensions: [Ramal.Resource]

        # ...
      end

  A resource opts out with a `ramal` section. A table that must never be branched, such as the one Ramal stores
  branches in, should do so:

      ramal do
        branchable? false
      end

  The extension only installs hooks. They do nothing unless the calling process is inside `Ramal.run/2`, so a
  resource behaves exactly as before outside a branch.

  What the transformer installs, confirmed against the locked Ash 3.37 source:

    * a global preparation, appended with `Ash.Resource.Builder.add_preparation/2`, which Ash applies to every read
      action of the resource;
    * a global change, `Ramal.Capture`, appended with `Ash.Resource.Builder.add_change/3` for create, update and
      destroy actions;
    * `require_atomic? false` on update and destroy actions, so that Ash can fall back from its atomic path (which
      goes straight to the data layer) to the one `Ramal.Capture` hooks into when a branch is current. See
      `docs/adr/0005-write-capture.md`.

  ## Example

      iex> Ramal.Resource.branchable?(Ramal.Test.Farm.Herd)
      true
  """

  @ramal %Spark.Dsl.Section{
    name: :ramal,
    describe: "Controls how this resource takes part in Ramal branches.",
    schema: [
      branchable?: [
        type: :boolean,
        default: true,
        doc:
          "Whether reads of this resource are patched with a branch's changes. Set to `false` to opt out."
      ],
      notify_in_branch?: [
        type: :boolean,
        default: false,
        doc:
          "Whether notifications for writes to this resource are sent when `Ramal.run/2` returns. Off by default: " <>
            "a notifier that sends an email for \"herd moved\" must not fire for a what-if."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@ramal],
    transformers: [Ramal.Resource.Transformer]

  alias Spark.Dsl.Extension

  @doc """
  Whether `resource` uses `Ramal.Resource` and has not opted out with `branchable? false`.

  ## Example

      iex> Ramal.Resource.branchable?(Ramal.Test.Farm.Herd)
      true
  """
  @spec branchable?(module) :: boolean
  def branchable?(resource) when is_atom(resource) do
    extended?(resource) and Extension.get_opt(resource, [:ramal], :branchable?, true)
  end

  @doc """
  Whether notifications for writes to `resource` made inside a branch are sent when `Ramal.run/2` returns.

  ## Example

      iex> Ramal.Resource.notify_in_branch?(Ramal.Test.Farm.Herd)
      false
  """
  @spec notify_in_branch?(module) :: boolean
  def notify_in_branch?(resource) when is_atom(resource) do
    extended?(resource) and Extension.get_opt(resource, [:ramal], :notify_in_branch?, false)
  end

  @doc """
  The resources of `domain` that are branchable.

  ## Example

      iex> Ramal.Resource.branchable_resources(Ramal.Test.Farm) |> Enum.sort()
      [
        Ramal.Test.Farm.Herd,
        Ramal.Test.Farm.HerdVet,
        Ramal.Test.Farm.Move,
        Ramal.Test.Farm.Paddock,
        Ramal.Test.Farm.Vet
      ]
  """
  @spec branchable_resources(module) :: [module]
  def branchable_resources(domain) when is_atom(domain) do
    if Code.ensure_loaded?(domain) and function_exported?(domain, :spark_is, 0) and
         domain.spark_is() == Ash.Domain do
      domain |> Ash.Domain.Info.resources() |> Enum.filter(&branchable?/1)
    else
      []
    end
  end

  @doc """
  Refuses a tenant: `{:error, %Ramal.Error{reason: :multitenancy_unsupported}}` when `resource` uses multitenancy and
  `tenant` is set, `:ok` otherwise.

  The overlay is keyed by `{resource, primary key}`, so two tenants' rows would share one entry, and the staleness read
  of `Ramal.merge/2` has no tenant to read with (`docs/adr/0009-multitenancy-refused.md`). A resource that is
  multitenant but `global? true` can still be used without a tenant.

  ## Example

      iex> Ramal.Resource.ensure_untenanted(Ramal.Test.Farm.Herd, "acme")
      :ok
      iex> {:error, error} = Ramal.Resource.ensure_untenanted(Ramal.Test.Tenanted.Task, "acme")
      iex> error.reason
      :multitenancy_unsupported
  """
  @spec ensure_untenanted(module, term) :: :ok | {:error, Ramal.Error.t()}
  def ensure_untenanted(_resource, nil), do: :ok

  def ensure_untenanted(resource, tenant) do
    if Ash.Resource.Info.multitenancy_strategy(resource) do
      {:error,
       Ramal.Error.new(
         :multitenancy_unsupported,
         "#{inspect(resource)} is multitenant and was used with a tenant inside a branch; a branch does not partition " <>
           "its overlay by tenant, so use the resource without a tenant or outside Ramal.run/2",
         %{resource: resource, tenant: tenant}
       )}
    else
      :ok
    end
  end

  @doc """
  The overlay key of `record`: the value of its primary key attribute, or a tuple of the values for a composite key.

  ## Example

      iex> Ramal.Resource.key(Ramal.Test.Farm.Herd, %{id: "r7"})
      "r7"
  """
  @spec key(module, map) :: term
  def key(resource, record) do
    case Ash.Resource.Info.primary_key(resource) do
      [field] -> Map.fetch!(record, field)
      fields -> fields |> Enum.map(&Map.fetch!(record, &1)) |> List.to_tuple()
    end
  end

  @doc """
  The attribute values of an Ash record as a plain map, leaving out relationships, calculations, aggregates and any
  attribute that was not loaded (a read with `select` leaves the others as `%Ash.NotLoaded{}`).

  ## Example

      iex> herd = struct(Ramal.Test.Farm.Herd, id: "r7", name: "R7", head: 30)
      iex> Ramal.Resource.attributes(herd) |> Map.take([:id, :name, :head])
      %{id: "r7", name: "R7", head: 30}
  """
  @spec attributes(struct) :: %{optional(atom) => term}
  def attributes(%resource{} = record) do
    record
    |> Map.take(attribute_names(resource))
    |> Map.reject(fn {_name, value} ->
      match?(%Ash.NotLoaded{}, value) or match?(%Ash.ForbiddenField{}, value)
    end)
  end

  @doc """
  The fingerprint of a record: `:erlang.phash2/1` of its attributes, or `nil` when some attribute is not loaded,
  because a hash of part of a row cannot be compared with a hash of the whole row.

  ## Example

      iex> a = struct(Ramal.Test.Farm.Herd, id: "r7", name: "R7", head: 30)
      iex> b = struct(Ramal.Test.Farm.Herd, id: "r7", name: "R7", head: 31)
      iex> Ramal.Resource.fingerprint(a) == Ramal.Resource.fingerprint(a)
      true
      iex> Ramal.Resource.fingerprint(a) == Ramal.Resource.fingerprint(b)
      false
  """
  @spec fingerprint(struct) :: non_neg_integer | nil
  def fingerprint(%resource{} = record) do
    attributes = attributes(record)

    if map_size(attributes) == length(attribute_names(resource)) do
      :erlang.phash2(attributes)
    end
  end

  defp attribute_names(resource),
    do: resource |> Ash.Resource.Info.attribute_names() |> Enum.to_list()

  defp extended?(resource) do
    Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0) and
      __MODULE__ in Spark.extensions(resource)
  end
end
