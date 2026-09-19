defmodule WotexTrackerMobile.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_tracker_mobile,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {Wotex.Tracker.Mobile.Application, []}
    ]
  end

  def cli, do: [preferred_envs: [check: :test, coveralls: :test]]

  defp deps do
    [
      ui(),
      {:mob, "== 0.9.1"},
      {:bandit, "== 1.12.5"},
      {:mint, "== 1.10.1"},
      {:phoenix, "== 1.8.14"},
      {:phoenix_live_view, "== 1.2.11"},
      {:phoenix_pubsub, "== 2.3.0"},
      {:plug, "== 1.20.3"},
      {:exqlite, "== 0.40.0"},
      {:jason, "== 1.4.5"},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :docs], runtime: false},
      {:doctest_formatter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp ui do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} ->
        {:wotex_tracker_ui, "~> 0.1.0"}

      {"1", env} when env in [:dev, :test, :docs] ->
        {:wotex_tracker_ui, path: "../../packages/tracker_ui", env: env}

      _ ->
        raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end
end
