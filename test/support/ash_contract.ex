alias Ramal.AshContract.Report

defmodule Ramal.AshContract.Report do
  @moduledoc false
  # The hooks of the Ash contract tests report to the test process by its registered name, not by `self()`: a stream or
  # a relationship read can run in a task of its own, and a message from that task would be lost (see
  # `Ramal.AshContractTest`). The test registers itself in its setup, and nothing is sent when no test is running.

  @name :ramal_ash_contract_test

  @doc "Registers the calling process as the one the hooks report to."
  def register, do: Process.register(self(), @name)

  @doc "Sends `message` to the registered test process, if there is one."
  def tell(message) do
    case Process.whereis(@name) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end
end

defmodule Ramal.AshContract.Domain do
  @moduledoc false
  # The resources of the Ash contract tests (Ramal.AshContractTest). None of them uses Ramal.Resource: these tests check
  # Ash, not what Ramal adds to it. They live here, not in the test file, because a resource defined in a test file is
  # compiled after Elixir consolidates protocols, which prints a warning for each one.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ramal.AshContract.Note)
    resource(Ramal.AshContract.Plot)
    resource(Ramal.AshContract.Ordered)
    resource(Ramal.AshContract.Roll)
    resource(Ramal.AshContract.Pasture)
    resource(Ramal.AshContract.Cow)
  end
end

defmodule Ramal.AshContract.Recorder do
  @moduledoc false
  # Reports the changeset's private context and a tag, then changes nothing.
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Report.tell({:recorded, opts[:tag], changeset.context[:private] || %{}})
    changeset
  end
end

defmodule Ramal.AshContract.Mark do
  @moduledoc false
  # Reports a tag, then changes nothing. Used to read the order in which changes run.
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Report.tell({:mark, opts[:tag]})
    changeset
  end
end

defmodule Ramal.AshContract.Markers do
  @moduledoc false
  # Reports which bulk markers (`bulk_create`, `bulk_update`, `bulk_destroy`) the changeset's context carries in
  # change/3.
  use Ash.Resource.Change

  @markers [:bulk_create, :bulk_update, :bulk_destroy]

  @impl true
  def change(changeset, _opts, _context) do
    Report.tell({:markers, Enum.filter(@markers, &Map.has_key?(changeset.context, &1))})
    changeset
  end
end

defmodule Ramal.AshContract.Around do
  @moduledoc false
  # An around_action hook that reports each time Ash runs it.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.around_action(changeset, fn changeset, callback ->
      Report.tell(:around_action)
      callback.(changeset)
    end)
  end
end

defmodule Ramal.AshContract.SetResult do
  @moduledoc false
  # Sets the action's result in a before_action hook, with a title no row has, and reports the after_action hook.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.after_action(fn _changeset, record ->
      Report.tell(:after_action_ran)
      {:ok, record}
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      {:ok, record} = Ash.Changeset.apply_attributes(changeset, force?: true)
      Ash.Changeset.set_result(changeset, {:ok, %{record | title: "from the hook"}})
    end)
  end
end

defmodule Ramal.AshContract.NotAtomic do
  @moduledoc false
  # A change whose atomic/3 refuses the atomic path. Its change/3 and its before_action hook report.
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Report.tell({:change, opts[:tag]})

    changeset =
      Ash.Changeset.before_action(changeset, fn changeset ->
        Report.tell({:before_action, opts[:tag]})
        changeset
      end)

    if changeset.action_type == :update,
      do: Ash.Changeset.change_attribute(changeset, :title, "changed by the change"),
      else: changeset
  end

  @impl true
  def atomic(_changeset, opts, _context),
    do: {:not_atomic, "the contract test refuses the atomic path (#{opts[:tag]})"}
end

defmodule Ramal.AshContract.Probe do
  @moduledoc false
  # A read preparation that reports the query's context when the read runs, and the rows it returns.
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.before_action(fn query ->
      Report.tell({:probe, :before_action, query.context})
      query
    end)
    |> Ash.Query.after_action(fn _query, rows ->
      Report.tell({:probe, :rows, rows})
      {:ok, rows}
    end)
  end
end

defmodule Ramal.AshContract.Cut do
  @moduledoc false
  # Gives the read the rows of the `fixture` context key as its result, and a full count of 7, in a before_action hook.
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      query
      |> Ash.Query.set_result(query.context[:fixture])
      |> Ash.Query.set_context(%{full_count: 7})
    end)
  end
end

defmodule Ramal.AshContract.Note do
  @moduledoc false
  # ETS: no database, so the hook and bulk assumptions do not depend on AshPostgres.
  use Ash.Resource,
    domain: Ramal.AshContract.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    create :hooked_create do
      accept([:title])
      change(Ramal.AshContract.SetResult)
    end

    update :hooked_update do
      require_atomic?(false)
      accept([:title])
      change(Ramal.AshContract.SetResult)
    end

    destroy :hooked_destroy do
      require_atomic?(false)
      change(Ramal.AshContract.SetResult)
    end

    create :around_create do
      accept([:title])
      change(Ramal.AshContract.Around)
    end

    update :around_update do
      require_atomic?(false)
      accept([:title])
      change(Ramal.AshContract.Around)
    end

    destroy :around_destroy do
      require_atomic?(false)
      change(Ramal.AshContract.Around)
    end

    update :not_atomic_update do
      require_atomic?(false)
      accept([])
      change({Ramal.AshContract.NotAtomic, tag: :update})
    end

    update :strict_not_atomic_update do
      accept([])
      change({Ramal.AshContract.NotAtomic, tag: :strict_update})
    end

    destroy :not_atomic_destroy do
      require_atomic?(false)
      change({Ramal.AshContract.NotAtomic, tag: :destroy})
    end

    create :markers do
      accept([:title])
      change(Ramal.AshContract.Markers)
    end

    update :markers_update do
      require_atomic?(false)
      accept([:title])
      change(Ramal.AshContract.Markers)
    end

    destroy :markers_destroy do
      require_atomic?(false)
      change(Ramal.AshContract.Markers)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
  end
end

defmodule Ramal.AshContract.Plot do
  @moduledoc false
  # ETS. Its creates record the changeset context they see in change/3, and it has an identity for the upserts.
  use Ash.Resource,
    domain: Ramal.AshContract.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults([:read, :destroy, update: :*])

    create :plain do
      accept([:name, :size])
      change({Ramal.AshContract.Recorder, tag: :plain})
    end

    create :upsert do
      accept([:name, :size])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_fields([:size])
      change({Ramal.AshContract.Recorder, tag: :upsert})
    end

    create :conditional do
      accept([:name, :size])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_condition(expr(size < upsert_conflict(:size)))
      change({Ramal.AshContract.Recorder, tag: :conditional})
    end
  end

  identities do
    identity(:unique_name, [:name], pre_check_with: Ramal.AshContract.Domain)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:size, :integer, public?: true)
  end
end

defmodule Ramal.AshContract.Ordered do
  @moduledoc false
  # ETS. A global change, declared on the resource, next to an action's own change.
  use Ash.Resource,
    domain: Ramal.AshContract.Domain,
    data_layer: Ash.DataLayer.Ets

  changes do
    change({Ramal.AshContract.Mark, tag: :global}, on: [:create])
  end

  actions do
    defaults([:read, :destroy, update: :*])

    create :with_own_change do
      accept([:name])
      change({Ramal.AshContract.Mark, tag: :action})
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end
end

defmodule Ramal.AshContract.Roll do
  @moduledoc false
  # ETS. `:read` pages by default with a small default_limit, as a Phoenix app often declares. `:cut` is a paginated
  # read whose page a before_action hook gives it.
  use Ash.Resource,
    domain: Ramal.AshContract.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults([:destroy, create: :*, update: :*])

    read :read do
      primary?(true)
      pagination(required?: true, default_limit: 2, offset?: true, countable: true)
    end

    read :cut do
      pagination(offset?: true, countable: true, required?: false)
      prepare(Ramal.AshContract.Cut)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:n, :integer, public?: true)
  end
end

defmodule Ramal.AshContract.Pasture do
  @moduledoc false
  # Postgres, on the table of Ramal.Test.Farm.Paddock, without Ramal.Resource.
  use Ash.Resource,
    domain: Ramal.AshContract.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("paddocks")
    repo(Ramal.TestRepo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:capacity_head, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:cows, Ramal.AshContract.Cow, destination_attribute: :paddock_id, public?: true)
  end
end

defmodule Ramal.AshContract.Cow do
  @moduledoc false
  # Postgres, on the table of Ramal.Test.Farm.Herd, without Ramal.Resource. Its primary read reports through Probe.
  use Ash.Resource,
    domain: Ramal.AshContract.Domain,
    data_layer: AshPostgres.DataLayer,
    primary_read_warning?: false

  postgres do
    table("herds")
    repo(Ramal.TestRepo)
  end

  actions do
    # Pagination that is not required, so a bulk action can stream the query (Ash needs keyset or offset to stream).
    read :read do
      primary?(true)
      pagination(offset?: true, keyset?: true, countable: true, required?: false)
      prepare(Ramal.AshContract.Probe)
    end

    defaults([:destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:head, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:pasture, Ramal.AshContract.Pasture,
      source_attribute: :paddock_id,
      public?: true,
      attribute_writable?: true
    )
  end
end
