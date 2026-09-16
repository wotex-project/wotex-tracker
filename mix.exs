defmodule WotexTracker.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_tracker,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Pure evidence-backed tracking and sensing values for WoTEx",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/wotex-project/wotex-tracker"},
        files:
          ~w(lib priv mix.exs .formatter.exs README.md LICENSE NOTICE SECURITY.md CONTRIBUTING.md docs)
      ],
      source_url: "https://github.com/wotex-project/wotex-tracker",
      docs: [
        main: "readme",
        extras: ~w(README.md CONTRIBUTING.md SECURITY.md) ++ Path.wildcard("docs/**/*.md"),
        formatters: ["html"]
      ],
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  def cli, do: [preferred_envs: [check: :test, coveralls: :test]]

  def application, do: [extra_applications: [:crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      wotex(),
      {:stream_data, "~> 1.3", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test], runtime: false},
      {:doctest_formatter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:yamerl, "~> 0.10", only: [:dev, :test], runtime: false}
    ]
  end

  defp wotex do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} -> {:wotex, "~> 0.1.0"}
      {"1", env} when env in [:dev, :test, :docs] -> {:wotex, path: "../wotex"}
      _ -> raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end
end
