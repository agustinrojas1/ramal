# A runnable demo of the Ramal inspector, for a screen recording.
#
#     docker compose up -d db        # from the repository root; Postgres on port 5435
#     elixir ramal_live/examples/farm_demo.exs
#
# Open http://localhost:4000 and press "Explore 4 alternatives". Four branches open on the same farm, each moves herd R7
# to a different paddock, and the columns fill in live. Merge one: the others read R7 before it moved, so a merge of
# them is refused as stale, which is the point of the staleness check.
#
# It uses a `ramal_dev` database on the same server as the test database, creates it when it is missing, and drops and
# recreates its tables on every start. Do not point it at data you want to keep. Override the server with RAMAL_PG_HOST,
# RAMAL_PG_PORT, RAMAL_PG_USER and RAMAL_PG_PASSWORD, and the HTTP port with PORT.
#
# Why a script with `Mix.install` and `phoenix_playground` and not a dev app: the demo needs a router with one
# `ramal_inspector` line, a LiveView with a button, and a repo, and nothing else. The lock file of `ramal_live` keeps the
# versions of Ash and AshPostgres that the tests run against.

repo_root = Path.expand("../..", __DIR__)
live_root = Path.expand("..", __DIR__)

Mix.install(
  [
    {:ramal, path: repo_root, override: true},
    {:ramal_live, path: live_root},
    {:ash_postgres, "~> 2.15"},
    {:simple_sat, "~> 0.1"},
    {:phoenix_playground, "~> 0.1"}
  ],
  lockfile: Path.join(live_root, "mix.lock"),
  consolidate_protocols: false,
  config: [
    ash: [
      sat_solver: {SimpleSat, []},
      missed_notifications: :ignore,
      default_string_length_count: :codepoints
    ],
    logger: [level: :warning]
  ]
)

Logger.configure(level: :warning)

defmodule FarmDemo.Repo do
  use AshPostgres.Repo, otp_app: :farm_demo

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
  def installed_extensions, do: ["ash-functions"]
end

defmodule FarmDemo.Paddock do
  use Ash.Resource,
    domain: FarmDemo.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("paddocks")
    repo(FarmDemo.Repo)
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

defmodule FarmDemo.Herd do
  use Ash.Resource,
    domain: FarmDemo.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("herds")
    repo(FarmDemo.Repo)
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:head, :integer, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:paddock, FarmDemo.Paddock, public?: true, attribute_writable?: true)
  end
end

defmodule FarmDemo.Move do
  use Ash.Resource,
    domain: FarmDemo.Farm,
    extensions: [Ramal.Resource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table("moves")
    repo(FarmDemo.Repo)
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
    attribute(:note, :string, public?: true)
  end
end

defmodule FarmDemo.Farm do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(FarmDemo.Paddock)
    resource(FarmDemo.Herd)
    resource(FarmDemo.Move)
  end
end

defmodule FarmDemo.Data do
  @moduledoc false
  # Creates the database when it is missing and the three tables from scratch, then seeds the farm. A demo has no use for
  # a migration history, so the tables are plain DDL; the columns are the ones the resources above declare.
  alias FarmDemo.{Herd, Move, Paddock, Repo}

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
      moved_on date NOT NULL,
      note text
    )
    """
  ]

  def setup! do
    config = Application.fetch_env!(:farm_demo, Repo)

    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "cannot create #{config[:database]}: #{inspect(reason)}"
    end

    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, pid} = Repo.start_link(pool_size: 2)
    Enum.each(@ddl, &Repo.query!/1)
    Supervisor.stop(pid)
  end

  # Also what the Reset button runs: it empties the tables and seeds them again.
  def seed! do
    for resource <- [Move, Herd, Paddock] do
      resource |> Ash.read!() |> Enum.each(&Ash.destroy!(&1))
    end

    [l07, l18, l22, l31, l40] =
      for {name, hectares, capacity} <- [
            {"L07", 40.0, 100},
            {"L18", 25.5, 60},
            {"L22", 31.0, 80},
            {"L31", 18.0, 45},
            {"L40", 52.5, 120}
          ] do
        Ash.create!(Paddock, %{name: name, hectares: hectares, capacity_head: capacity})
      end

    for {name, head, paddock} <- [{"R7", 30, l07}, {"R8", 35, l07}, {"R9", 25, l18}] do
      Ash.create!(Herd, %{name: name, head: head, paddock_id: paddock.id})
    end

    %{paddocks: [l07, l18, l22, l31, l40]}
  end

  def herd!(name), do: Herd |> Ash.read!() |> Enum.find(&(&1.name == name))
  def paddocks, do: Paddock |> Ash.read!() |> Enum.sort_by(& &1.name)
end

defmodule FarmDemo.Explore do
  @moduledoc false
  # The demo's one scenario: herd R7 could go to any of four paddocks, so fork four branches and try each. The pauses are
  # only there so a recording shows the columns filling in; the branches do not need them.
  alias FarmDemo.{Data, Farm, Move}

  @herd "R7"
  @pause 450

  def alternatives do
    herd = Data.herd!(@herd)
    {Data.paddocks() |> Enum.reject(&(&1.id == herd.paddock_id)) |> Enum.take(4), herd}
  end

  def run do
    {destinations, herd} = alternatives()
    from = Enum.find(Data.paddocks(), &(&1.id == herd.paddock_id))

    branches =
      for paddock <- destinations do
        {:ok, branch} = Ramal.branch(Farm, name: "#{@herd} to #{paddock.name}")
        Process.sleep(@pause)
        {branch, paddock}
      end

    Enum.each(branches, fn {branch, paddock} ->
      Ramal.run!(branch, fn ->
        Ash.update!(herd, %{paddock_id: paddock.id})
      end)

      Process.sleep(@pause)
    end)

    Enum.each(branches, fn {branch, paddock} ->
      Ramal.run!(branch, fn ->
        Ash.create!(Move, %{
          herd_id: herd.id,
          from_paddock_id: herd.paddock_id,
          to_paddock_id: paddock.id,
          moved_on: Date.utc_today(),
          note: "#{@herd} from #{from.name} to #{paddock.name}"
        })
      end)

      Process.sleep(@pause)
    end)

    :ok
  end

  def reset do
    {:ok, branches} = Ramal.list(Farm)
    Enum.each(branches, &Ramal.discard/1)
    Data.seed!()
    :ok
  end
end

defmodule FarmDemo.DemoLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Ramal farm demo", busy: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      html, body { margin: 0; height: 100%; }
      body { font-family: system-ui, sans-serif; background: #f4f1ec; color: #1e2a33; }
      .demo { display: grid; grid-template-rows: auto 1fr; height: 100vh; }
      @media (prefers-color-scheme: dark) { body { background: #141a1f; color: #e8e4dd; } }
      header { display: flex; align-items: center; gap: 12px; padding: 12px 20px; }
      header h1 { font-size: 1rem; margin: 0 auto 0 0; font-weight: 600; }
      button { font: inherit; padding: 8px 16px; border-radius: 6px; border: 1px solid #b4673a; cursor: pointer; }
      button.primary { background: #b4673a; color: #fff; }
      button.quiet { background: transparent; color: inherit; }
      button:disabled { opacity: 0.5; cursor: wait; }
      iframe { width: 100%; height: 100%; border: 0; }
    </style>
    <div class="demo">
      <header>
        <h1>Herd R7 is crowding paddock L07. Where should it go?</h1>
        <button class="primary" phx-click="explore" disabled={@busy}>Explore 4 alternatives</button>
        <button class="quiet" phx-click="reset" disabled={@busy}>Reset</button>
      </header>
      <iframe src="/ramal" title="Ramal inspector"></iframe>
    </div>
    """
  end

  @impl true
  def handle_event("explore", _params, socket) do
    {:noreply, socket |> assign(busy: true) |> start_async(:explore, &FarmDemo.Explore.run/0)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(busy: true) |> start_async(:explore, &FarmDemo.Explore.reset/0)}
  end

  @impl true
  def handle_async(:explore, _result, socket), do: {:noreply, assign(socket, busy: false)}
end

defmodule FarmDemo.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import RamalLive.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {PhoenixPlayground.Layout, :root})
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    live_session :demo do
      live("/", FarmDemo.DemoLive, :index)
      ramal_inspector("/ramal", domain: FarmDemo.Farm, pubsub: PhoenixPlayground.PubSub)
    end
  end
end

Application.put_env(:farm_demo, FarmDemo.Repo,
  username: System.get_env("RAMAL_PG_USER", "ramal"),
  password: System.get_env("RAMAL_PG_PASSWORD", "ramal"),
  hostname: System.get_env("RAMAL_PG_HOST", "localhost"),
  port: String.to_integer(System.get_env("RAMAL_PG_PORT", "5435")),
  database: "ramal_dev",
  pool_size: 10
)

FarmDemo.Data.setup!()

PhoenixPlayground.start(
  plug: FarmDemo.Router,
  port: String.to_integer(System.get_env("PORT", "4000")),
  live_reload: false,
  open_browser: false,
  child_specs: [
    FarmDemo.Repo,
    {Ramal.Supervisor, storage: Ramal.Storage.ETS},
    {RamalLive.Broadcaster, pubsub: PhoenixPlayground.PubSub}
  ]
)

FarmDemo.Data.seed!()
IO.puts("Farm demo on http://localhost:#{System.get_env("PORT", "4000")}")
Process.sleep(:infinity)
