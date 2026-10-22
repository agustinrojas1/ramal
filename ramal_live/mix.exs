defmodule RamalLive.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agustinrojas1/ramal"

  def project do
    [
      app: :ramal_live,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "RamalLive",
      description: "A LiveView inspector for Ramal branches, mounted by the host's router.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Ramal is used from the parent directory so that the inspector is always built against the code next to it. Ramal
  # itself never depends on this project.
  defp deps do
    [
      {:ramal, path: ".."},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md)
    ]
  end
end
