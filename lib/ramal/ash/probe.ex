defmodule Ramal.Ash.Probe.Domain do
  @moduledoc false
  # The domain of the probe resources (ADR 0049). It is not in any host's configuration, so the check that a domain is
  # included in the config is off.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Ramal.Ash.Probe.Note)
    resource(Ramal.Ash.Probe.Plot)
    resource(Ramal.Ash.Probe.Ordered)
    resource(Ramal.Ash.Probe.Roll)
    resource(Ramal.Ash.Probe.Pasture)
    resource(Ramal.Ash.Probe.Cow)
  end
end

defmodule Ramal.Ash.Probe.Guarded do
  @moduledoc false
  # A domain that requires an actor and authorizes every request, as a host's domain may. Ramal's collation loads are
  # made with `authorize?: false` and no actor, so they pass only when they are marked internal.
  use Ash.Domain, validate_config_inclusion?: false

  authorization do
    require_actor?(true)
    authorize(:always)
  end

  resources do
    resource(Ramal.Ash.Probe.Gated)
  end
end

defmodule Ramal.Ash.Probe.Report do
  @moduledoc false
  # A probe reports to the check that runs it. The check puts `{self(), ref}` under `ramal_probe` in the context of its
  # action, so a hook that runs in another process (a stream's task) still reaches it, and the ref keeps the messages of
  # two checks apart. Nothing is sent when a probe runs without a check.

  @doc false
  @spec tell(map, term) :: :ok
  def tell(context, message) do
    case context[:ramal_probe] do
      {pid, ref} -> send(pid, {ref, message})
      _none -> :ok
    end

    :ok
  end
end

defmodule Ramal.Ash.Probe.Watch do
  @moduledoc false
  # A read preparation that reports the query before the data layer runs and the rows after it, so a check can ask
  # Ramal's seams about the query Ash built.
  use Ash.Resource.Preparation

  alias Ramal.Ash.Probe.Report

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.before_action(fn query ->
      Report.tell(query.context, {:query, query})
      query
    end)
    |> Ash.Query.after_action(fn query, rows ->
      Report.tell(query.context, {:rows, rows})
      {:ok, rows}
    end)
  end
end

defmodule Ramal.Ash.Probe.Recorder do
  @moduledoc false
  # Reports the changeset it sees in change/3 and changes nothing, so a check reads what Ash put in the context.
  use Ash.Resource.Change

  alias Ramal.Ash.Probe.Report

  @impl true
  def change(changeset, opts, _context) do
    Report.tell(changeset.context, {:recorded, opts[:tag], changeset})
    changeset
  end
end

defmodule Ramal.Ash.Probe.BeforeRecorder do
  @moduledoc false
  # Reports the changeset it sees in a before_action hook, where Ramal's write hook reads what Ash put in the context
  # (`Ramal.Capture`), and changes nothing.
  use Ash.Resource.Change

  alias Ramal.Ash.Probe.Report

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Report.tell(changeset.context, {:before, opts[:tag], changeset})
      changeset
    end)
  end
end

defmodule Ramal.Ash.Probe.Mark do
  @moduledoc false
  # Reports a tag and changes nothing. Used to read the order in which changes run.
  use Ash.Resource.Change

  alias Ramal.Ash.Probe.Report

  @impl true
  def change(changeset, opts, _context) do
    Report.tell(changeset.context, {:mark, opts[:tag]})
    changeset
  end
end

defmodule Ramal.Ash.Probe.Around do
  @moduledoc false
  # An around_action hook that reports each time Ash runs it, so a check counts the records of a bulk action.
  use Ash.Resource.Change

  alias Ramal.Ash.Probe.Report

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.around_action(changeset, fn changeset, callback ->
      Report.tell(changeset.context, :around_action)
      callback.(changeset)
    end)
  end
end

defmodule Ramal.Ash.Probe.SetResult do
  @moduledoc false
  # Sets the action's result in a before_action hook, through the seam Ramal uses (`Ramal.Ash.skip_data_layer/2`),
  # with a title no row has, and reports the after_action hook. The result must be what the caller gets, and the data
  # layer must not be written.
  use Ash.Resource.Change

  alias Ramal.Ash.Probe.Report

  @impl true
  def change(changeset, _opts, _context) do
    context = changeset.context

    changeset
    |> Ash.Changeset.after_action(fn _changeset, record ->
      Report.tell(context, :after_action_ran)
      {:ok, record}
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      {:ok, record} = Ash.Changeset.apply_attributes(changeset, force?: true)
      Ramal.Ash.skip_data_layer(changeset, {:ok, %{record | title: "from the hook"}})
    end)
  end
end

defmodule Ramal.Ash.Probe.NotAtomic do
  @moduledoc false
  # A change whose `atomic/3` refuses the atomic path, so Ash runs its `change/3` and the hook it adds. Both report.
  use Ash.Resource.Change

  alias Ramal.Ash.Probe.Report

  @impl true
  def change(changeset, opts, _context) do
    context = changeset.context
    Report.tell(context, {:change, opts[:tag]})

    changeset =
      Ash.Changeset.before_action(changeset, fn changeset ->
        Report.tell(context, {:before_action, opts[:tag]})
        changeset
      end)

    if changeset.action_type == :update,
      do: Ash.Changeset.change_attribute(changeset, :title, "changed by the change"),
      else: changeset
  end

  @impl true
  def atomic(_changeset, opts, _context),
    do: {:not_atomic, "the probe refuses the atomic path (#{opts[:tag]})"}
end

defmodule Ramal.Ash.Probe.Cut do
  @moduledoc false
  # Gives a read the rows of the `fixture` context key as its page, and a full count of 7, in a before_action hook, the
  # way Ramal's paged reads do (`Ramal.Ash.set_page/2` and `Ramal.Ash.put_full_count/2`).
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      query
      |> Ramal.Ash.set_page(query.context[:fixture])
      |> Ramal.Ash.put_full_count(7)
    end)
  end
end

defmodule Ramal.Ash.Probe.Note do
  @moduledoc false
  # ETS, with a private table per process: each check runs in a process of its own, so its rows are its own and are
  # gone when it ends. The actions cover the hooks, the bulk strategies and the atomic path the checks exercise.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  actions do
    # Pagination that is not required, so a bulk action can stream a query of this read (Ash needs keyset or offset
    # pagination to stream one).
    read :read do
      primary?(true)
      pagination(offset?: true, keyset?: true, countable: true, required?: false)
      prepare(Ramal.Ash.Probe.Watch)
    end

    create :create do
      primary?(true)
      accept([:title])
    end

    update :update do
      primary?(true)
      accept([:title])
    end

    destroy :destroy do
      primary?(true)
    end

    create :hooked_create do
      accept([:title])
      change(Ramal.Ash.Probe.SetResult)
    end

    update :hooked_update do
      require_atomic?(false)
      accept([:title])
      change(Ramal.Ash.Probe.SetResult)
    end

    destroy :hooked_destroy do
      require_atomic?(false)
      change(Ramal.Ash.Probe.SetResult)
    end

    create :around_create do
      accept([:title])
      change(Ramal.Ash.Probe.Around)
    end

    update :around_update do
      require_atomic?(false)
      accept([:title])
      change(Ramal.Ash.Probe.Around)
    end

    destroy :around_destroy do
      require_atomic?(false)
      change(Ramal.Ash.Probe.Around)
    end

    update :not_atomic_update do
      require_atomic?(false)
      accept([])
      change({Ramal.Ash.Probe.NotAtomic, tag: :update})
    end

    destroy :not_atomic_destroy do
      require_atomic?(false)
      change({Ramal.Ash.Probe.NotAtomic, tag: :destroy})
    end

    # Changes that report the changeset they see. A bulk action runs them with its bulk marker in the context.
    create :recorded_create do
      accept([:title])
      change({Ramal.Ash.Probe.Recorder, tag: :create})
    end

    update :recorded_update do
      require_atomic?(false)
      accept([:title])
      change({Ramal.Ash.Probe.Recorder, tag: :update})
    end

    destroy :recorded_destroy do
      require_atomic?(false)
      change({Ramal.Ash.Probe.Recorder, tag: :destroy})
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
  end
end

defmodule Ramal.Ash.Probe.Plot do
  @moduledoc false
  # ETS, private. Its creates report the changeset they see in change/3, and it has an identity for the upserts.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  actions do
    read :read do
      primary?(true)
    end

    destroy :destroy do
      primary?(true)
    end

    create :plain do
      accept([:name, :size])
      change({Ramal.Ash.Probe.Recorder, tag: :plain})
    end

    create :upsert do
      accept([:name, :size])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_fields([:size])
      change({Ramal.Ash.Probe.Recorder, tag: :upsert})
    end

    create :conditional do
      accept([:name, :size])
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_condition(expr(size < upsert_conflict(:size)))
      change({Ramal.Ash.Probe.Recorder, tag: :conditional})
    end

    # An upsert whose before_action reports what Ash put in the context, as Ramal's write hook does.
    create :hooked_upsert do
      accept([:name, :size])
      upsert?(true)
      upsert_identity(:unique_name)
      change({Ramal.Ash.Probe.BeforeRecorder, tag: :hooked_upsert})
    end
  end

  identities do
    identity(:unique_name, [:name], pre_check_with: Ramal.Ash.Probe.Domain)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:size, :integer, public?: true)
  end
end

defmodule Ramal.Ash.Probe.Ordered do
  @moduledoc false
  # ETS, private. A global change, declared on the resource, next to an action's own change.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  changes do
    change({Ramal.Ash.Probe.Mark, tag: :global}, on: [:create])
  end

  actions do
    read :read do
      primary?(true)
    end

    create :create do
      primary?(true)
      accept([:name])
    end

    create :with_own_change do
      accept([:name])
      change({Ramal.Ash.Probe.Mark, tag: :action})
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end
end

defmodule Ramal.Ash.Probe.Gated do
  @moduledoc false
  # ETS, private, in the domain that requires an actor. Its rows are made with an actor, which that domain requires.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Guarded,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  actions do
    read :read do
      primary?(true)
    end

    create :create do
      primary?(true)
      accept([:name])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
  end
end

defmodule Ramal.Ash.Probe.Roll do
  @moduledoc false
  # ETS, private. `:read` pages by default with a small default_limit, as a Phoenix app often declares. `:cut` is a
  # paginated read whose page a before_action hook gives it.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  actions do
    read :read do
      primary?(true)
      pagination(required?: true, default_limit: 2, offset?: true, countable: true)
    end

    read :cut do
      pagination(offset?: true, countable: true, required?: false)
      prepare(Ramal.Ash.Probe.Cut)
    end

    create :create do
      primary?(true)
      accept([:n])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:n, :integer, public?: true)
  end
end

defmodule Ramal.Ash.Probe.Pasture do
  @moduledoc false
  # ETS, private. Has many cows, so a has_many load with a limit is the lateral load the relationship-pages checks need.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  actions do
    read :read do
      primary?(true)
    end

    create :create do
      primary?(true)
      accept([:name])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
  end

  relationships do
    has_many(:cows, Ramal.Ash.Probe.Cow, destination_attribute: :paddock_id, public?: true)
  end
end

defmodule Ramal.Ash.Probe.Cow do
  @moduledoc false
  # ETS, private. Its primary read is paginated but not required, so a has_many load can carry a limit, and it reports
  # through Watch, so a check sees the lateral join the load gives its destination read.
  use Ash.Resource,
    domain: Ramal.Ash.Probe.Domain,
    data_layer: Ash.DataLayer.Ets,
    primary_read_warning?: false

  ets do
    private?(true)
  end

  actions do
    read :read do
      primary?(true)
      pagination(offset?: true, keyset?: true, countable: true, required?: false)
      prepare(Ramal.Ash.Probe.Watch)
    end

    create :create do
      primary?(true)
      accept([:name, :paddock_id])
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:paddock_id, :uuid, public?: true)
  end

  relationships do
    belongs_to(:pasture, Ramal.Ash.Probe.Pasture,
      source_attribute: :paddock_id,
      public?: true,
      attribute_writable?: true
    )
  end
end
