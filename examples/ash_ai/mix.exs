defmodule RamalAshAiExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :ramal_ash_ai_example,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      aliases: aliases()
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

  # The version of AshAi is pinned: what docs/agents.md says about it is what this suite checks against that version.
  # Ramal itself never depends on this project.
  defp deps do
    [
      {:ramal, path: "../.."},
      {:ash_ai, "== 1.4.0"},
      {:plug, "~> 1.17"},
      {:jason, "~> 1.4"},
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
end
