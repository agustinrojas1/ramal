# The farm the walkthrough runs on: three Ash resources, a domain, a repo, and the seed data.
#
# Nothing in here is specific to a demo. The only Ramal-related lines are the `extensions: [Ramal.Resource]` in each
# resource, which is how a resource opts in to being visible inside a branch. Everything else is an ordinary Ash app:
# a validation that reads other rows, a policy, an action that writes an audit row after it succeeds.

defmodule Farm.Repo do
  use AshPostgres.Repo, otp_app: :ramal_demo

  def min_pg_version, do: %Version{major: 14, minor: 0, patch: 0}
  def installed_extensions, do: ["ash-functions"]
end

defmodule Farm.CapacityCheck do
  @moduledoc false
  # Refuses a move when the destination paddock cannot hold the herd. It reads the destination's other herds through Ash,
  # so inside a branch it sees the moves that branch has already made, not only what is in Postgres.
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    destination_id = Ash.Changeset.get_attribute(changeset, :paddock_id)
    herd_id = Ash.Changeset.get_attribute(changeset, :id)
    head = Ash.Changeset.get_attribute(changeset, :head)

    with destination_id when not is_nil(destination_id) <- destination_id,
         {:ok, paddock} <- Ash.get(Farm.Paddock, destination_id, authorize?: false),
         {:ok, herds} <-
           Farm.Herd |> Ash.Query.filter(paddock_id == ^destination_id) |> Ash.read(authorize?: false) do
      present = herds |> Enum.reject(&(&1.id == herd_id)) |> Enum.map(& &1.head) |> Enum.sum()

      if present + head <= paddock.capacity_head do
        :ok
      else
        {:error,
         field: :to_paddock_id,
         message: "paddock #{paddock.name} holds #{paddock.capacity_head} head and already has #{present}"}
      end
    else
      nil -> :ok
      {:error, error} -> {:error, error}
    end
  end
end

defmodule Farm.Paddock do
  use Ash.Resource,
    domain: Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("paddocks")
    repo(Farm.Repo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:hectares, :float, public?: true)
    attribute(:capacity_head, :integer, allow_nil?: false, public?: true)
  end
end

defmodule Farm.Herd do
  use Ash.Resource,
    domain: Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("herds")
    repo(Farm.Repo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])

    update :move do
      description("Moves the herd to another paddock, refusing when the destination is too small, and logs the move.")

      # The capacity validation reads other herds, so Ash cannot run this action as one atomic SQL update.
      require_atomic?(false)
      accept([])

      argument(:to_paddock_id, :uuid, allow_nil?: false)

      change(set_attribute(:paddock_id, arg(:to_paddock_id)))
      validate(Farm.CapacityCheck)

      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn changeset, herd ->
          Ash.create!(
            Farm.Move,
            %{herd_id: herd.id, from_paddock_id: changeset.data.paddock_id, to_paddock_id: herd.paddock_id, moved_on: Date.utc_today()},
            authorize?: false
          )

          {:ok, herd}
        end)
      end)
    end
  end

  policies do
    # Only a manager may move a herd. Everything else is open, to keep the demo short.
    policy action(:move) do
      authorize_if(actor_attribute_equals(:role, :manager))
    end

    policy action([:read, :create, :update, :destroy]) do
      authorize_if(always())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:head, :integer, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:paddock, Farm.Paddock, public?: true, attribute_writable?: true)
  end
end

defmodule Farm.Move do
  use Ash.Resource,
    domain: Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("moves")
    repo(Farm.Repo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:herd_id, :uuid, allow_nil?: false, public?: true)
    attribute(:from_paddock_id, :uuid, public?: true)
    attribute(:to_paddock_id, :uuid, allow_nil?: false, public?: true)
    attribute(:moved_on, :date, allow_nil?: false, public?: true)
  end
end

defmodule Farm do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Farm.Paddock)
    resource(Farm.Herd)
    resource(Farm.Move)
  end
end

defmodule Farm.Data do
  @moduledoc false
  # A demo has no use for a migration history, so the tables are plain DDL, recreated on every run. The columns are the
  # ones the resources above declare. Only the `ramal_demo` database is touched.
  alias Farm.{Herd, Paddock, Repo}

  @ddl [
    "DROP TABLE IF EXISTS moves, herds, paddocks",
    """
    CREATE TABLE paddocks (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      hectares double precision,
      capacity_head bigint NOT NULL
    )
    """,
    """
    CREATE TABLE herds (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      head bigint NOT NULL,
      paddock_id uuid REFERENCES paddocks (id)
    )
    """,
    """
    CREATE TABLE moves (
      id uuid PRIMARY KEY,
      herd_id uuid NOT NULL,
      from_paddock_id uuid,
      to_paddock_id uuid NOT NULL,
      moved_on date NOT NULL
    )
    """
  ]

  def configure! do
    Application.put_env(:ramal_demo, Repo,
      username: System.get_env("RAMAL_PG_USER", "ramal"),
      password: System.get_env("RAMAL_PG_PASSWORD", "ramal"),
      hostname: System.get_env("RAMAL_PG_HOST", "localhost"),
      port: String.to_integer(System.get_env("RAMAL_PG_PORT", "5436")),
      database: System.get_env("RAMAL_PG_DATABASE", "ramal_demo"),
      pool_size: 10,
      log: false
    )
  end

  # Returns :ok, or {:error, message} when Postgres cannot be reached, so the walkthrough can say what to do about it.
  def setup! do
    config = Application.fetch_env!(:ramal_demo, Repo)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    # A plain TCP connect first: when nothing listens, Postgrex prints a long stack trace instead of one useful line.
    case :gen_tcp.connect(to_charlist(config[:hostname]), config[:port], [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        up(config)

      {:error, reason} ->
        {:error, "cannot reach Postgres at #{config[:hostname]}:#{config[:port]} (#{inspect(reason)})"}
    end
  end

  defp up(config) do
    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok -> create_tables(config)
      {:error, :already_up} -> create_tables(config)
      {:error, reason} -> {:error, "cannot open database #{config[:database]} as #{config[:username]}: #{inspect(reason)} (check RAMAL_PG_USER and RAMAL_PG_PASSWORD)"}
    end
  end

  defp create_tables(config) do
    {:ok, pid} = Repo.start_link(pool_size: 2)
    Enum.each(@ddl, &Repo.query!/1)
    Supervisor.stop(pid)
    :ok
  rescue
    error -> {:error, "cannot reach Postgres at #{config[:hostname]}:#{config[:port]}: #{Exception.message(error)}"}
  end

  def seed! do
    [l07, l18, l22, l31] =
      for {name, hectares, capacity} <- [{"L07", 40.0, 100}, {"L18", 25.5, 60}, {"L22", 31.0, 80}, {"L31", 18.0, 45}] do
        Ash.create!(Paddock, %{name: name, hectares: hectares, capacity_head: capacity})
      end

    for {name, head, paddock} <- [{"R7", 30, l07}, {"R8", 35, l07}, {"R9", 25, l18}, {"R10", 40, l31}] do
      Ash.create!(Herd, %{name: name, head: head, paddock_id: paddock.id})
    end

    %{l07: l07, l18: l18, l22: l22, l31: l31}
  end
end
