defmodule Ramal.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/agustinrojas1/ramal"

  def project do
    [
      app: :ramal,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Ramal",
      description:
        "Data branches as BEAM processes: Git-style branches of Ash application data that you fork, diff and merge.",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  # `mix ci` runs the tests, which need the test environment (the Farm domain lives in test/support).
  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.36"},
      {:spark, "~> 2.7"},
      # Already in the tree through Ash. Declared because Ramal.Error implements Splode.Error: Ash turns any other
      # exception raised inside an action into a string, which would lose the `reason` a host matches on.
      {:splode, "~> 0.3"},
      {:telemetry, "~> 1.3"},
      {:jason, "~> 1.4"},
      # Optional for users: only the Postgres storage backend and the test suite need it.
      {:ash_postgres, "~> 2.15", optional: true},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      # Ash needs it at runtime, so it cannot be restricted to :test here (Mix refuses the conflicting :only). Ramal itself
      # only uses it in the property tests.
      {:stream_data, "~> 1.1"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ash.setup --quiet", "test"],
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo/ramal-mark.svg",
      source_ref: "v#{@version}",
      extras:
        [
          "README.md",
          "docs/DESIGN.md",
          "docs/ROADMAP.md",
          "docs/agents.md",
          "usage-rules.md",
          "CONTRIBUTING.md",
          "CHANGELOG.md"
        ] ++
          Path.wildcard("docs/adr/0*.md"),
      groups_for_extras: [Guides: ~r/docs\/.*/]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib mix.exs README.md LICENSE CHANGELOG.md assets/logo usage-rules.md usage-rules docs/agents.md)
    ]
  end
end
