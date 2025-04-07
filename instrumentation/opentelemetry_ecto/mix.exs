defmodule OpentelemetryEcto.MixProject do
  use Mix.Project

  @version "1.0.0-rc.0"

  def project do
    [
      app: :opentelemetrex_ecto,
      description: description(),
      version: @version,
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      source_url:
        "https://github.com/danschultzer/opentelemetrex-erlang-contrib/tree/main/instrumentation/opentelemetry_ecto",
      docs: [
        source_url_pattern:
          "https://github.com/danschultzer/opentelemetrex-erlang-contrib/blob/main/instrumentation/opentelemetry_ecto/%{path}#L%{line}",
        main: "OpentelemetryEcto",
        extras: ["README.md"]
      ]
    ]
  end

  defp description do
    "Trace Ecto queries with OpenTelemetry."
  end

  defp package do
    [
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" =>
          "https://github.com/danschultzer/opentelemetrex-erlang-contrib/tree/main/instrumentation/opentelemetry_ecto",
        "OpenTelemetry Erlang" => "https://github.com/open-telemetry/opentelemetry-erlang",
        "OpenTelemetry Erlang Contrib (OpenTelemetrex Fork)" =>
          "https://github.com/danschultzer/opentelemetrex-erlang-contrib",
        "OpenTelemetry.io" => "https://opentelemetry.io"
      }
    ]
  end

  def application do
    []
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases() do
    [test: ["ecto.drop -q", "ecto.create -q", "ecto.migrate --quiet", "test"]]
  end

  defp deps do
    [
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_process_propagator, "~> 0.3"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:opentelemetry, "~> 1.5", only: [:dev, :test]},
      {:opentelemetry_exporter, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.36", only: [:dev], runtime: false},
      {:ecto_sql, ">= 3.0.0", only: [:dev, :test]},
      {:postgrex, ">= 0.15.0", only: [:dev, :test]},
      {:dialyxir, "~> 1.1", only: [:dev, :test], runtime: false}
    ]
  end
end
