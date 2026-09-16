defmodule WotexTrackerNerves.MixProject do
  use Mix.Project

  @app :wotex_tracker_nerves

  def project do
    [
      app: @app,
      version: "0.1.0",
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :inets],
      mod: {Wotex.Tracker.Nerves.Application, []}
    ]
  end

  def cli, do: [preferred_targets: [run: :host, test: :host]]

  defp deps do
    [
      service(),
      {:nerves, "~> 1.15", runtime: false},
      {:nerves_runtime, "~> 0.13.13", targets: :rpi5},
      {:shoehorn, "~> 0.9.1", targets: :rpi5},
      {:ring_logger, "~> 0.11.0", targets: :rpi5},
      {:vintage_net, "~> 0.13.12", targets: :rpi5},
      {:vintage_net_ethernet, "~> 0.11.2", targets: :rpi5},
      {:nerves_time, "~> 0.4.12", targets: :rpi5},
      {:nerves_system_rpi5, "== 2.1.2", runtime: false, targets: :rpi5}
    ]
  end

  defp service do
    case {System.get_env("WOTEX_PATH_DEPS"), Mix.env()} do
      {nil, _} ->
        {:wotex_tracker_service, "~> 0.1.0"}

      {"1", env} when env in [:dev, :test, :docs] ->
        {:wotex_tracker_service, path: "../../packages/tracker_service", env: env}

      _ ->
        raise "WOTEX_PATH_DEPS accepts only 1 in dev/test/docs; production requires artifacts"
    end
  end

  defp release do
    [
      overwrite: true,
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
