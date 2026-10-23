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

  alias Ramal.Branch.Server
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
  The resources of `domain` that a branch would not cover: they do not use `Ramal.Resource` and they have a create,
  update or destroy action, so a write to one inside a branch would reach the database.

  A resource that uses the extension with `branchable? false` is not listed: that is the explicit opt-out, and writes to
  it are real. `Ramal.branch/2` refuses a domain that has any of these (ADR 0027).

  ## Example

      iex> Ramal.Resource.uncovered(Ramal.Test.Farm)
      []
      iex> Ramal.Resource.uncovered(Ramal.Test.Uncovered)
      [Ramal.Test.Uncovered.Note]
  """
  @spec uncovered(module) :: [module]
  def uncovered(domain) when is_atom(domain) do
    if Code.ensure_loaded?(domain) and function_exported?(domain, :spark_is, 0) and
         domain.spark_is() == Ash.Domain do
      domain
      |> Ash.Domain.Info.resources()
      |> Enum.reject(&extended?/1)
      |> Enum.filter(fn resource ->
        Enum.any?(Ash.Resource.Info.actions(resource), &(&1.type in [:create, :update, :destroy]))
      end)
    else
      []
    end
  end

  @doc """
  Checks that `tenant`, the one a query or changeset on `resource` carries, is the tenant of branch `id` (ADR 0034).

  `:ok` when `tenant` is `nil`, when `resource` is not multitenant, or when it is the branch's tenant (compared as the
  data layer sees it, `Ash.ToTenant`). Otherwise `{:error, %Ramal.Error{reason: :tenant_mismatch}}` for a branch
  with a tenant, and `:multitenancy_unsupported` for a branch without one: the overlay is keyed by `{resource, primary
  key}`, so a branch can hold the rows of one tenant only.

  ## Example

      iex> Ramal.Resource.ensure_tenant(Ramal.Test.Farm.Herd, "acme", "no-such-branch")
      :ok
  """
  @spec ensure_tenant(module, term, String.t()) :: :ok | {:error, Ramal.Error.t()}
  def ensure_tenant(_resource, nil, _id), do: :ok

  def ensure_tenant(resource, tenant, id) do
    if Ash.Resource.Info.multitenancy_strategy(resource) do
      with {:ok, branch_tenant} <- Server.tenant(id) do
        check_tenant(resource, tenant, branch_tenant)
      end
    else
      :ok
    end
  end

  defp check_tenant(resource, tenant, nil) do
    {:error,
     Ramal.Error.new(
       :multitenancy_unsupported,
       "#{inspect(resource)} is multitenant and was used with a tenant inside a branch that has none; a branch holds " <>
         "the rows of one tenant, so create it with `Ramal.branch(domain, tenant: tenant)`",
       %{resource: resource, tenant: tenant}
     )}
  end

  defp check_tenant(resource, tenant, branch_tenant) do
    if Ash.ToTenant.to_tenant(tenant, resource) == Ash.ToTenant.to_tenant(branch_tenant, resource) do
      :ok
    else
      {:error,
       Ramal.Error.new(
         :tenant_mismatch,
         "#{inspect(resource)} was used with tenant #{inspect(tenant)} inside a branch that works in tenant " <>
           "#{inspect(branch_tenant)}; a branch holds the rows of one tenant, so use another branch for another tenant",
         %{resource: resource, tenant: tenant, branch_tenant: branch_tenant}
       )}
    end
  end

  @doc false
  # The tenant a read of `resource` made for `branch_tenant` carries: the staleness read of a merge fingerprints the
  # rows a tenanted resource holds for the branch's tenant only. A `global?` resource is read without one, since rows
  # written without a tenant belong to no tenant.
  @spec read_tenant(module, term) :: term
  def read_tenant(resource, tenant) do
    if Ash.Resource.Info.multitenancy_strategy(resource) &&
         !Ash.Resource.Info.multitenancy_global?(resource),
       do: tenant,
       else: nil
  end

  @doc """
  The overlay key of `record`: the value of its primary key attribute, or a tuple of the values for a composite key.

  ## Example

      iex> Ramal.Resource.key(Ramal.Test.Farm.Herd, %{id: "r7"})
      "r7"
  """
  @spec key(module, map) :: term
  def key(resource, record), do: key_of(record, Ash.Resource.Info.primary_key(resource))

  @doc false
  # `key/2` with the primary key looked up once. A read walks its rows several times by key, and the lookup is a Spark
  # persisted-term fetch, so a function per read costs less than a lookup per row.
  @spec key_fun(module) :: (map -> term)
  def key_fun(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [field] -> &Map.fetch!(&1, field)
      fields -> &key_of(&1, fields)
    end
  end

  @doc false
  # Sets the primary key of a create changeset to `key` (a scalar, or a tuple for a composite key), over whatever
  # default it got.
  @spec force_key(Ash.Changeset.t(), term) :: Ash.Changeset.t()
  def force_key(changeset, key) do
    values = if is_tuple(key), do: Tuple.to_list(key), else: [key]

    changeset.resource
    |> Ash.Resource.Info.primary_key()
    |> Enum.zip(values)
    |> Enum.reduce(changeset, fn {field, value}, changeset ->
      Ash.Changeset.force_change_attribute(changeset, field, value)
    end)
  end

  defp key_of(record, [field]), do: Map.fetch!(record, field)
  defp key_of(record, fields), do: fields |> Enum.map(&Map.fetch!(record, &1)) |> List.to_tuple()

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
    # One pass over the few attribute names, not `Map.take/2` then `Map.reject/2` over the result: the diff of a branch
    # calls this twice per updated row.
    Enum.reduce(attribute_names(resource), %{}, fn name, attributes ->
      case record do
        %{^name => %Ash.NotLoaded{}} -> attributes
        %{^name => %Ash.ForbiddenField{}} -> attributes
        %{^name => value} -> Map.put(attributes, name, value)
        %{} -> attributes
      end
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
  def fingerprint(%resource{} = record), do: fingerprint(record, attribute_names(resource))

  @doc false
  # The `{{resource, key}, fingerprint}` pairs of the rows a read returned, skipping rows with an attribute that was not
  # loaded. The attribute names and the primary key are looked up once for the whole list, not once per row, which is
  # most of what fingerprinting a wide read used to cost. Same fingerprints as `fingerprint/1`.
  @spec fingerprints(module, [struct]) :: [{{module, term}, non_neg_integer}]
  def fingerprints(resource, rows) do
    names = attribute_names(resource)
    primary_key = Ash.Resource.Info.primary_key(resource)

    for row <- rows, fingerprint = fingerprint(row, names) do
      {{resource, key_of(row, primary_key)}, fingerprint}
    end
  end

  # The hash is of the map of attribute values, exactly what `attributes/1` returns when every attribute is loaded, so a
  # fingerprint stored by an earlier version still compares equal. A single pass collects the values and gives up at the
  # first one that is not loaded.
  defp fingerprint(record, names) do
    case loaded_attributes(record, names, []) do
      :error -> nil
      pairs -> pairs |> :maps.from_list() |> :erlang.phash2()
    end
  end

  defp loaded_attributes(_record, [], pairs), do: pairs

  defp loaded_attributes(record, [name | names], pairs) do
    case record do
      %{^name => %Ash.NotLoaded{}} -> :error
      %{^name => %Ash.ForbiddenField{}} -> :error
      %{^name => value} -> loaded_attributes(record, names, [{name, value} | pairs])
      _missing -> :error
    end
  end

  @doc false
  # Every row `query` matches, whatever the read action's pagination. Ramal reads with it where it needs the whole set:
  # the staleness check of a merge and the rows of `Ramal.aggregate/4`. `Ash.read/2` returns a page, or fails with
  # `PaginationRequired`, for an action with `pagination required?: true`, and `page: false` fails the same way.
  # `Ramal.Ash.unpaginated_read/2` is what Ash itself reads relationships with: it skips the action's `paginate` step
  # and still runs the read preparations, so a branch patches the whole list once.
  @spec read_all(Ash.Query.t() | module, keyword) :: {:ok, [struct]} | {:error, term}
  def read_all(query, opts \\ []) do
    # Ash gives a read of an action with a `default_limit` that limit as its page even when the read skips pagination,
    # and `Ramal.Preparation` would cut it; the flag says this read wants the whole list.
    query = query |> Ash.Query.new() |> Ash.Query.set_context(%{ramal: %{whole?: true}})
    Ramal.Ash.unpaginated_read(query, opts)
  end

  defp attribute_names(resource),
    do: resource |> Ash.Resource.Info.attribute_names() |> MapSet.to_list()

  defp extended?(resource) do
    Code.ensure_loaded?(resource) and function_exported?(resource, :spark_is, 0) and
      __MODULE__ in Spark.extensions(resource)
  end
end
