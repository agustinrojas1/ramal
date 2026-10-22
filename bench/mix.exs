defmodule Bench.MixProject do
  use Mix.Project

  def project do
    [
      app: :bench,
      version: "0.0.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Ramal is used from the parent directory so that the benchmark always measures the code next to it. Nothing here is
  # ever a dependency of the library.
  defp deps do
    [
      {:ramal, path: ".."},
      {:ash, "~> 3.36"},
      {:ash_postgres, "~> 2.15"},
      {:simple_sat, "~> 0.1"},
      {:jason, "~> 1.4"}
    ]
  end
end
