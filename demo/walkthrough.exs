# A guided tour of Ramal on a small farm. Run it from the repository root:
#
#     docker compose -f demo/docker-compose.yml up -d     # Postgres on localhost:5436
#     elixir demo/walkthrough.exs                         # press Enter between chapters, or add --fast
#
# Read demo/README.md first if you want to know what to expect. This file is meant to be read next to the output: every
# chapter prints the line it starts on.
#
# Ramal comes from Hex (`~> 0.2.0`), the same package your app would install. Set RAMAL_DEMO_SOURCE=path to run against
# this checkout instead. The database is `ramal_demo` on the Postgres above; its three tables are dropped and recreated
# on every run, and nothing else is touched.

source =
  case System.get_env("RAMAL_DEMO_SOURCE", "hex") do
    "path" -> {:ramal, path: Path.expand("..", __DIR__), override: true}
    "hex" -> {:ramal, "~> 0.2.0"}
  end

Mix.install(
  [
    source,
    # The versions Ramal's own tests run against.
    {:ash, "~> 3.36.0"},
    {:ash_postgres, "~> 2.15.0"},
    {:simple_sat, "~> 0.1"}
  ],
  consolidate_protocols: false,
  config: [
    ash: [sat_solver: {SimpleSat, []}, missed_notifications: :ignore, default_string_length_count: :codepoints],
    logger: [level: :warning]
  ]
)

Logger.configure(level: :warning)

Code.require_file("farm.exs", __DIR__)
Code.require_file("ui.exs", __DIR__)

Code.require_file("tour.exs", __DIR__)
