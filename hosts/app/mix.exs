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
          steps: [:assemble, &copy_assets/1, :tar]
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

  defp copy_assets(release) do
    destination = Path.join([release.path, "bin", "trackerctl"])
    File.cp!("bin/trackerctl", destination)
    File.chmod!(destination, 0o755)
    libexec = Path.join(release.path, "libexec")
    File.mkdir_p!(libexec)
    File.cp!("scripts/trackerctl.exs", Path.join(libexec, "trackerctl.exs"))
    licenses = Path.join(release.path, "licenses")
    File.cp_r!("priv/licenses", licenses)
    copy_notices(File.cwd!(), Path.join(licenses, "wotex_tracker_host"))

    elixir =
      :elixir
      |> :code.lib_dir()
      |> to_string()
      |> Path.expand()
      |> Path.dirname()
      |> Path.dirname()

    elixir_source =
      if Path.wildcard(Path.join(elixir, "LICENSE*")) == [],
        do: Path.join("priv/licenses", "elixir-" <> System.version()),
        else: elixir

    copy_notices(elixir_source, Path.join(licenses, "elixir"))

    for {app, path} <- Mix.Project.deps_paths(), Map.has_key?(release.applications, app) do
      destination = Path.join(licenses, Atom.to_string(app))

      if app == :db_connection do
        # This dependency ships its copyright/Apache notice inside README.md.
        File.mkdir_p!(destination)
        File.cp!(Path.join(path, "README.md"), Path.join(destination, "README.md"))
        File.cp!("LICENSE", Path.join(destination, "LICENSE"))
      else
        copy_notices(path, destination)
      end
    end

    release
  end

  defp copy_notices(source, destination) do
    files =
      ["LICENSE*", "NOTICE*", "COPYING*"]
      |> Enum.flat_map(&Path.wildcard(Path.join(source, &1)))
      |> Enum.filter(&File.regular?/1)

    if files == [], do: Mix.raise("Missing release license files for #{Path.basename(source)}")
    File.mkdir_p!(destination)
    Enum.each(files, &File.cp!(&1, Path.join(destination, Path.basename(&1))))
  end
end
