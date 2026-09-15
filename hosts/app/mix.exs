defmodule WotexTrackerHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :wotex_tracker_host,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      docs: [main: "readme", extras: ["README.md"]],
      releases: [
        wotex_tracker: [
          include_erts: true,
          include_executables_for: [:unix],
          steps: [:assemble, &copy_cli/1, :tar]
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssl], mod: {Wotex.Tracker.Host.Application, []}]

  def cli, do: [preferred_envs: [check: :test, coveralls: :test]]

  defp deps do
    [
      service(),
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: [:dev, :test, :docs], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
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

  defp copy_cli(release) do
    destination = Path.join([release.path, "bin", "trackerctl"])
    File.cp!("bin/trackerctl", destination)
    File.chmod!(destination, 0o755)
    release
  end
end
