defmodule RamalLive.MixProject do
  use Mix.Project

  @version "0.10.0"
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
      docs: docs(),
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
  # itself never depends on this project. Hex only accepts Hex dependencies, so a release sets RAMAL_LIVE_HEX=1 to
  # depend on the published ramal of the same version (`mix hex.build` fails on the path dependency otherwise). It is
  # the same patch version because the inspector uses `Ramal.Change.redact/1`, added in 0.4.3.
  defp ramal_dep do
    if System.get_env("RAMAL_LIVE_HEX") == "1" do
      %Version{major: major, minor: minor, patch: patch} = Version.parse!(@version)
      {:ramal, "~> #{major}.#{minor}.#{patch}"}
    else
      {:ramal, path: ".."}
    end
  end

  defp deps do
    [
      ramal_dep(),
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry, "~> 1.3"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
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

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url_pattern: "#{@source_url}/blob/v#{@version}/ramal_live/%{path}#L%{line}",
      assets: %{"../assets" => "assets"},
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
