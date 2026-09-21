defmodule WotexTrackerNerves.MixProject do
  use Mix.Project

  @app :wotex_tracker_nerves
  @device_targets [:rpi5, :qemu_aarch64]

  def project do
    [
      app: @app,
      version: "0.1.0",
      elixir: "~> 1.18",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: code_paths(),
      test_paths: if(ui?(), do: ["test", "ui_test"], else: ["test"]),
      lockfile: profile_path("mix.lock", "mix.ui.lock", "mix.qemu.lock", "mix.qemu-ui.lock"),
      build_path: profile_path("_build", "_build/ui", "_build/qemu", "_build/qemu-ui"),
      deps_path:
        profile_path("deps", "_build/ui_deps", "_build/qemu_deps", "_build/qemu-ui-deps"),
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
      {:doctest_formatter, "~> 0.4", only: [:dev, :test], runtime: false},
      {:nerves_runtime, "~> 0.13.13", targets: @device_targets},
      {:shoehorn, "~> 0.9.1", targets: @device_targets},
      {:ring_logger, "~> 0.11.0", targets: @device_targets},
      {:vintage_net, "~> 0.13.12", targets: @device_targets},
      {:vintage_net_ethernet, "~> 0.11.2", targets: @device_targets},
      {:nerves_time, "~> 0.4.12", targets: @device_targets},
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

  defp profile_path(headless, ui, qemu, qemu_ui) do
    case {Mix.target(), ui?()} do
      {:qemu_aarch64, true} -> qemu_ui
      {:qemu_aarch64, false} -> qemu
      {_, true} -> ui
      _ -> headless
    end
  end

  defp code_paths do
    case {ui?(), Mix.target()} do
      {true, :rpi5} -> ["lib", "ui", "target_ui"]
      {true, :qemu_aarch64} -> ["lib", "ui", "qemu"]
      {false, :qemu_aarch64} -> ["lib", "qemu"]
      {true, _} -> ["lib", "ui"]
      _ -> ["lib"]
    end
  end

  defp system do
    case {Mix.target(), ui?()} do
      {:qemu_aarch64, _ui} ->
        {:nerves_system_qemu_aarch64, "== 0.4.2", runtime: false, targets: :qemu_aarch64}

      {_, true} ->
        {:kiosk_system_rpi5, "== 2.1.2", runtime: false, targets: :rpi5}

      _ ->
        {:nerves_system_rpi5, "== 2.1.2", runtime: false, targets: :rpi5}
    end
  end

  defp ui_deps do
    if ui?() do
      [
        ui(),
        {:muontrap, "~> 1.8", targets: @device_targets},
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
      strip_beams: Mix.env() == :prod or Mix.target() == :qemu_aarch64 or [keep: ["Docs"]]
    ]
  end
end
