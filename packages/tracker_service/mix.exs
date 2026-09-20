defmodule WotexTrackerService.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_tracker_service,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      description: "Explicitly started durable service components for WoTEx Tracker",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      docs: [main: "readme", extras: ["README.md"]],
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/wotex-project/wotex-tracker"},
        files: ~w(lib priv mix.exs README.md LICENSE NOTICE)
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
  def cli, do: [preferred_envs: [check: :test, coveralls: :test]]

  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      tracker(),
      runtime(),
      http_binding(),
      ble(),
      {:bandit, "== 1.12.5"},
      {:thousand_island, "== 1.5.0"},
      {:plug, "== 1.20.3"},
      {:mint, "== 1.10.1"},
      {:exqlite, "== 0.40.0"},
      {:telemetry, "== 1.4.2"},
      {:stream_data, "~> 1.3", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :docs], runtime: false},
      {:doctest_formatter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp tracker do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} -> {:wotex_tracker, "~> 0.1.0"}
      {"1", env} when env in [:dev, :test, :docs] -> {:wotex_tracker, path: "../..", env: env}
      _ -> raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end

  defp runtime, do: sibling(:wotex_runtime, "../../../wotex/packages/wotex-runtime")

  defp http_binding,
    do: sibling(:wotex_binding_http, "../../../wotex/packages/wotex-binding-http")

  defp ble,
    do: sibling(:wotex_ble, "../../../wotex/packages/wotex-ble", optional: true)

  defp sibling(name, path, options \\ []) do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} ->
        if options == [], do: {name, "~> 0.1.0"}, else: {name, "~> 0.1.0", options}

      {"1", env} when env in [:dev, :test, :docs] ->
        {name, [path: Path.expand(path, __DIR__), env: :dev] ++ options}

      _ ->
        raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end
end
