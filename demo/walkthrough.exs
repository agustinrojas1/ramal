# A guided tour of Ramal on a small farm. Run it from the repository root:
#
#     docker compose -f demo/docker-compose.yml up -d     # Postgres on localhost:5436
#     elixir demo/walkthrough.exs                         # press Enter between chapters, or add --fast
#
# Read demo/README.md first if you want to know what to expect. This file is meant to be read next to the output: every
# chapter prints the line it starts on.
#
# Ramal comes from Hex (`~> 0.4.0`), the same package your app would install. If that version is not published yet and you run
# this from a checkout, the checkout is used instead. Set RAMAL_DEMO_SOURCE=path to use the checkout on purpose. The database
# is `ramal_demo` on the Postgres above; its three tables are dropped and recreated on every run, and nothing else is touched.

checkout = Path.expand("..", __DIR__)
from_checkout = {:ramal, path: checkout, override: true}

install = fn ramal ->
  Mix.install(
    [
      ramal,
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
end

in_checkout? =
  File.regular?(Path.join(checkout, "mix.exs")) and
    String.contains?(File.read!(Path.join(checkout, "mix.exs")), "app: :ramal,")

case System.get_env("RAMAL_DEMO_SOURCE", "hex") do
  "path" ->
    install.(from_checkout)

  "hex" ->
    try do
      install.({:ramal, "~> 0.4.0"})
    rescue
      error in Mix.Error ->
        if in_checkout? do
          IO.puts("ramal ~> 0.4.0 is not on Hex yet (#{Exception.message(error)}); using the checkout at #{checkout}")
          install.(from_checkout)
        else
          reraise error, __STACKTRACE__
        end
    end
end

Logger.configure(level: :warning)

Code.require_file("farm.exs", __DIR__)
Code.require_file("ui.exs", __DIR__)

Code.require_file("tour.exs", __DIR__)
