defmodule WotexTrackerService.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_tracker_service,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: deps(),
      description: "Explicitly started durable service components for WoTEx Tracker",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
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

  defp deps do
    [
      tracker(),
      {:bandit, "== 1.12.5"},
      {:plug, "== 1.20.3"},
      {:exqlite, "== 0.40.0"},
      {:stream_data, "~> 1.3", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test], runtime: false},
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
end
