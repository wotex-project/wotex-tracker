defmodule WotexTrackerUI.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_tracker_ui,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Shared authorized LiveView workflows for WoTEx Tracker",
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      docs: [main: "readme", extras: ["README.md"]],
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/wotex-project/wotex-tracker"},
        files: ~w(lib priv mix.exs README.md LICENSE NOTICE)
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto, :public_key, :ssl]]
  def cli, do: [preferred_envs: [check: :test, coveralls: :test]]

  defp deps do
    [
      service(),
      runtime(),
      {:phoenix, "== 1.8.14"},
      {:phoenix_live_view, "== 1.2.11"},
      {:phoenix_html, "== 4.3.0"},
      {:jason, "== 1.4.5"},
      {:mint, "== 1.10.0"},
      {:lazy_html, "~> 0.1", only: :test},
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

  defp service do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} ->
        {:wotex_tracker_service, "~> 0.1.0"}

      {"1", env} when env in [:dev, :test, :docs] ->
        {:wotex_tracker_service, path: "../tracker_service", env: env}

      _ ->
        raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end

  defp runtime do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} ->
        {:wotex_runtime, "~> 0.1.0"}

      {"1", env} when env in [:dev, :test, :docs] ->
        {:wotex_runtime, path: "../../../wotex/packages/wotex-runtime", env: :dev}

      _ ->
        raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end
end
