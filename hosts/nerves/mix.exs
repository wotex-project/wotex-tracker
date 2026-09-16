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
      elixirc_paths: code_paths(),
      test_paths: if(ui?(), do: ["test", "ui_test"], else: ["test"]),
      lockfile: if(ui?(), do: "mix.ui.lock", else: "mix.lock"),
      build_path: if(ui?(), do: "_build/ui", else: "_build"),
      deps_path: if(ui?(), do: "_build/ui_deps", else: "deps"),
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
      system()
    ] ++ ui_deps()
  end

  defp ui? do
    case System.get_env("WOTEX_TRACKER_UI") do
      nil -> false
      "1" -> true
      _ -> raise "WOTEX_TRACKER_UI accepts only 1 when building a kiosk host"
    end
  end

  defp code_paths do
    case {ui?(), Mix.target()} do
      {true, :rpi5} -> ["lib", "ui", "target_ui"]
      {true, _} -> ["lib", "ui"]
      _ -> ["lib"]
    end
  end

  defp system do
    if ui?(),
      do: {:kiosk_system_rpi5, "== 2.1.2", runtime: false, targets: :rpi5},
      else: {:nerves_system_rpi5, "== 2.1.2", runtime: false, targets: :rpi5}
  end

  defp ui_deps do
    if ui?() do
      [
        ui(),
        {:muontrap, "~> 1.8", targets: :rpi5},
        {:myelin, "~> 0.1.1", targets: :rpi5}
      ]
    else
      []
    end
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
