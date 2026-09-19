defmodule Wotex.Tracker.Command do
  @moduledoc false

  @floor {"1.18.4-otp-27", "27.3.4.15"}

  def run!(arguments, directory, environment, lane \\ @floor) do
    {elixir, erlang} = lane
    command = ["exec", "elixir@#{elixir}", "erlang@#{erlang}", "--" | arguments]

    {output, status} =
      System.cmd("mise", command,
        cd: directory,
        env: environment,
        stderr_to_stdout: true
      )

    if status != 0 do
      tail = output |> String.slice(-16_000, 16_000) |> to_string()
      raise("#{Enum.take(arguments, 3) |> Enum.join(" ")} failed:\n#{tail}")
    end

    output
  end

  def plain!(executable, arguments, options \\ []) do
    {output, status} =
      System.cmd(executable, arguments, Keyword.put(options, :stderr_to_stdout, true))

    if status != 0, do: raise("#{executable} #{Enum.join(arguments, " ")} failed:\n#{output}")
    output
  end
end

System.put_env("WOTEX_TRACKER_RELEASE_QUALIFIER_NO_MAIN", "1")
Code.require_file(Path.join(__DIR__, "qualify_releases.exs"))
System.delete_env("WOTEX_TRACKER_RELEASE_QUALIFIER_NO_MAIN")
System.put_env("WOTEX_TRACKER_STATIC_SERVER_NO_MAIN", "1")
Code.require_file(Path.join(__DIR__, "static_server.exs"))
System.delete_env("WOTEX_TRACKER_STATIC_SERVER_NO_MAIN")

defmodule Wotex.Tracker.SourceQualifier do
  @moduledoc false

  alias Wotex.Tracker.{Command, ReleaseQualifier, StaticServer}

  @root Path.expand("..", __DIR__)
  @wotex_workspace Path.expand("../wotex", @root)
  @lanes [{"1.18.4-otp-27", "27.3.4.15"}, {"1.20.4-otp-29", "29.0.4"}]
  @base_packages ~w(jason-1.4.5 ex_json_schema-0.11.5 decimal-3.1.1 jason-1.4.0 ex_json_schema-0.11.0 decimal-2.0.0)
  @service_packages ~w(exqlite-0.40.0 db_connection-2.10.2 telemetry-1.4.2 elixir_make-0.10.0 cc_precompiler-0.1.11 bandit-1.12.5 plug-1.20.3 thousand_island-1.5.0 hpax-1.0.4 mime-2.0.7 plug_crypto-2.2.0 websock-0.5.3 mint-1.10.0)

  def main(arguments) do
    {options, rest, invalid} =
      OptionParser.parse(arguments, strict: [service: :boolean, host: :boolean, ui: :boolean])

    if rest != [] or invalid != [],
      do: raise("usage: qualify_source.exs [--service|--host|--ui]")

    ui? = options[:ui] == true
    host? = options[:host] == true or ui?
    service? = options[:service] == true or host?

    suffix = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    workspace = Path.join(System.tmp_dir!(), "wtr-source-cohort-#{suffix}")

    File.mkdir_p!(workspace)

    try do
      qualify(workspace, service?, host?, ui?)
    after
      File.rm_rf!(workspace)
    end
  end

  defp qualify(workspace, service?, host?, ui?) do
    environment = clean_environment()
    registry = Path.join(workspace, "registry")
    tarballs = Path.join(registry, "tarballs")
    File.mkdir_p!(tarballs)
    ensure_clean_source!(service?)
    source_root = Path.join(workspace, "wotex")
    revision = snapshot(@wotex_workspace, source_root)
    source = Path.join(source_root, "packages/wotex")
    IO.puts("Checking immutable upstream source snapshot #{revision}")
    core_environment = Map.put(environment, "MIX_ENV", "test")
    core_lock = File.read!(Path.join(source, "mix.lock"))

    for command <- [
          ~w(mix deps.get),
          ~w(mix format --check-formatted),
          ~w(mix compile --warnings-as-errors),
          ~w(mix test),
          ~w(mix docs --warnings-as-errors)
        ] do
      IO.puts("Upstream: #{Enum.join(command, " ")}")
      Command.run!(command, source, core_environment)
    end

    if File.read!(Path.join(source, "mix.lock")) != core_lock,
      do: raise("upstream lock changed during snapshot verification")

    Command.run!(
      ["mix", "hex.build", "--output", Path.join(tarballs, "wotex-0.1.0.tar")],
      source,
      environment
    )

    {revisions, packages} =
      if service?,
        do: service_archives(source_root, tarballs, environment, core_environment, revision),
        else: {%{"wotex" => revision}, @base_packages}

    Command.run!(
      ["mix", "hex.build", "--output", Path.join(tarballs, "wotex_tracker-0.1.0.tar")],
      @root,
      environment
    )

    if ui? do
      Command.run!(
        ["mix", "hex.build", "--output", Path.join(tarballs, "wotex_tracker_ui-0.1.0.tar")],
        Path.join(@root, "packages/tracker_ui"),
        environment
      )
    end

    lockfile = if ui?, do: "mix.ui.lock", else: "mix.lock"
    packages = if host?, do: packages ++ locked_packages(lockfile), else: packages
    fetch_packages(Enum.uniq(packages), workspace, tarballs, environment)
    key = Path.join(workspace, "registry-key.pem")
    Command.plain!("openssl", ["genrsa", "-out", key, "2048"])

    Command.run!(
      ["mix", "hex.registry", "build", registry, "--name", "hexpm", "--private-key", key],
      @root,
      environment
    )

    {:ok, server, port} = StaticServer.start_link(registry)

    try do
      url = "http://127.0.0.1:#{port}"
      results = consumers(workspace, registry, url, environment, service?, ui?)
      host_result = if host?, do: qualify_host(workspace, registry, url, environment, ui?)
      write_report(tarballs, revisions, results, host_result, service?, host?, ui?)
    after
      Process.exit(server, :shutdown)
    end
  end

  defp service_archives(source_root, tarballs, environment, core_environment, revision) do
    revisions = %{"wotex" => revision}

    revisions =
      Enum.reduce(
        [{"wotex-runtime", "wotex_runtime"}, {"wotex-binding-http", "wotex_binding_http"}],
        revisions,
        fn {repository, package}, result ->
          target = Path.join([source_root, "packages", repository])
          head = revision
          lock = File.read!(Path.join(target, "mix.lock"))
          snapshot_environment = Map.put(core_environment, "WOTEX_PATH_DEPS", "1")

          for command <- [
                ~w(mix deps.get),
                ~w(mix check --no-retry),
                ~w(mix docs --warnings-as-errors),
                ~w(elixir bin/check_boundary.exs)
              ] do
            IO.puts("Upstream #{package}@#{head}: #{Enum.join(command, " ")}")
            Command.run!(command, target, snapshot_environment)
          end

          if File.read!(Path.join(target, "mix.lock")) != lock,
            do: raise("#{package} lock changed during snapshot verification")

          Command.run!(
            ["mix", "hex.build", "--output", Path.join(tarballs, "#{package}-0.1.0.tar")],
            target,
            environment
          )

          Map.put(result, package, head)
        end
      )

    Command.run!(
      [
        "mix",
        "hex.build",
        "--output",
        Path.join(tarballs, "wotex_tracker_service-0.1.0.tar")
      ],
      Path.join(@root, "packages/tracker_service"),
      environment
    )

    {revisions, @base_packages ++ @service_packages}
  end

  defp consumers(workspace, registry, url, environment, service?, ui?) do
    for lane <- @lanes, mode <- ~w(fresh locked minimum) do
      {elixir, otp} = lane
      consumer = Path.join(workspace, "consumer-#{elixir}-#{mode}")
      File.mkdir!(consumer)
      consumer_environment = Map.put(environment, "HEX_HOME", Path.join(consumer, "hex-home"))

      Command.run!(
        [
          "mix",
          "hex.repo",
          "set",
          "hexpm",
          "--url",
          url,
          "--public-key",
          Path.join(registry, "public_key")
        ],
        @root,
        consumer_environment,
        lane
      )

      write_consumer(consumer, mode, service?, ui?)

      if mode == "locked" do
        floor = Path.join(workspace, "consumer-#{elixir}-fresh/mix.lock")
        File.cp!(floor, Path.join(consumer, "mix.lock"))
      end

      IO.puts("Consumer #{inspect(lane)}: #{mode}")
      Command.run!(~w(mix deps.get), consumer, consumer_environment, lane)
      lock = File.read!(Path.join(consumer, "mix.lock"))
      Command.run!(~w(mix compile --warnings-as-errors), consumer, consumer_environment, lane)

      output =
        Command.run!(
          [
            "mix",
            "run",
            Path.join(
              @root,
              if(ui?, do: "scripts/ui_consumer.exs", else: "scripts/source_consumer.exs")
            )
          ],
          consumer,
          consumer_environment,
          lane
        )

      expected = if ui?, do: "UI_COHORT_PASS", else: "SOURCE_COHORT_PASS"

      unless String.contains?(output, expected) and
               File.read!(Path.join(consumer, "mix.lock")) == lock,
             do: raise("consumer contract or immutable lock check failed")

      IO.puts(String.trim(output))

      if service? and not ui?,
        do: verify_service_consumer!(consumer, consumer_environment, lane)

      %{
        "elixir" => elixir,
        "otp" => otp,
        "mode" => mode,
        "result" => "pass",
        "lock_sha256" => digest(lock)
      }
    end
  end

  defp verify_service_consumer!(consumer, environment, lane) do
    output =
      Command.run!(
        ["mix", "run", Path.join(@root, "scripts/service_consumer.exs")],
        consumer,
        environment,
        lane
      )

    unless String.contains?(output, "SERVICE_COHORT_PASS"),
      do: raise("service consumer contract failed")

    IO.puts(String.trim(output))
  end

  defp write_consumer(directory, mode, service?, ui?) do
    dependency =
      cond do
        ui? -> "wotex_tracker_ui"
        service? -> "wotex_tracker_service"
        true -> "wotex_tracker"
      end

    dependencies =
      if mode == "minimum" do
        ~s([{:#{dependency}, "~> 0.1.0"}, {:jason, "1.4.0"}, ) <>
          ~s({:ex_json_schema, "0.11.0"}, {:decimal, "2.0.0"}])
      else
        ~s([{:#{dependency}, "~> 0.1.0"}])
      end

    File.write!(
      Path.join(directory, "mix.exs"),
      """
      defmodule ArchiveConsumer.MixProject do
        use Mix.Project
        def project, do: [app: :archive_consumer, version: "0.0.0", elixir: "~> 1.18", deps: #{dependencies}]
        def application, do: []
      end
      """
    )

    if service? do
      File.mkdir!(Path.join(directory, "config"))

      File.write!(
        Path.join(directory, "config/config.exs"),
        "import Config\nconfig :exqlite, force_build: true\n"
      )
    end
  end

  defp fetch_packages(packages, workspace, tarballs, environment) do
    downloads = Path.join(workspace, "downloads")
    File.mkdir_p!(downloads)

    Enum.each(packages, fn package ->
      [_, name, version] = Regex.run(~r/\A(.+)-([0-9][0-9A-Za-z.\-+]*)\z/, package)

      Command.run!(
        ["mix", "hex.package", "fetch", name, version, "--output", downloads],
        @root,
        environment
      )

      File.cp!(Path.join(downloads, package <> ".tar"), Path.join(tarballs, package <> ".tar"))
    end)
  end

  defp locked_packages(lockfile) do
    lock = File.read!(Path.join(@root, "hosts/app/#{lockfile}"))

    packages =
      Regex.scan(~r/"([a-z0-9_]+)": \{:hex, :[a-z0-9_]+, "([^"]+)"/, lock,
        capture: :all_but_first
      )
      |> Enum.map(fn [name, version] -> "#{name}-#{version}" end)

    if packages == [], do: raise("host lock has no recognized Hex records")
    packages
  end

  defp qualify_host(workspace, registry, url, environment, ui?) do
    ReleaseQualifier.verify(workspace, registry, url, environment, ui?)
  end

  defp write_report(tarballs, revisions, results, host_result, service?, host?, ui?) do
    archives =
      tarballs
      |> Path.join("*.tar")
      |> Path.wildcard()
      |> Enum.sort()
      |> Map.new(&{Path.basename(&1), file_digest(&1)})

    report = %{
      "scope" => "local-source-cohort-not-public-release",
      "upstream_revision" => revisions["wotex"],
      "upstream_revisions" => revisions,
      "archives" => archives,
      "consumers" => results
    }

    report = if host_result, do: Map.put(report, "host", host_result), else: report
    destination = Path.join(@root, "_build/verification")
    File.mkdir_p!(destination)

    name =
      cond do
        ui? -> "ui-consumer.json"
        host? -> "host-consumer.json"
        service? -> "service-consumer.json"
        true -> "source-consumer.json"
      end

    File.write!(Path.join(destination, name), Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("Recorded _build/verification/#{name}; temporary registry and keys removed on exit")
  end

  defp snapshot(repository, destination) do
    revision = Command.plain!("git", ["-C", repository, "rev-parse", "HEAD"]) |> String.trim()

    Command.plain!(
      "git",
      ["clone", "--quiet", "--local", "--no-hardlinks", "--no-checkout", repository, destination]
    )

    Command.plain!("git", ["-C", destination, "checkout", "--quiet", "--detach", revision])
    revision
  end

  defp ensure_clean_source!(service?) do
    paths =
      ["packages/wotex", "docs/packages/wotex"] ++
        if service? do
          [
            "packages/wotex-runtime",
            "docs/packages/wotex-runtime",
            "packages/wotex-binding-http",
            "docs/packages/wotex-binding-http"
          ]
        else
          []
        end

    changed =
      Command.plain!("git", ["-C", @wotex_workspace, "status", "--porcelain", "--" | paths])

    if String.trim(changed) != "",
      do: raise("required WoTEx monorepo packages have uncommitted changes:\n#{changed}")
  end

  defp clean_environment do
    System.get_env()
    |> Map.merge(%{
      "WOTEX_PATH_DEPS" => nil,
      "WOTEX_TRACKER_UI" => nil,
      "WOTEX_TRACKER_UI_CONFIG" => nil,
      "MIX_BUILD_PATH" => nil,
      "MIX_DEPS_PATH" => nil,
      "MIX_ENV" => nil
    })
    |> Map.put("MIX_ENV", "prod")
  end

  defp file_digest(path), do: path |> File.read!() |> digest()
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end

unless System.get_env("WOTEX_TRACKER_SOURCE_QUALIFIER_NO_MAIN") == "1" do
  Wotex.Tracker.SourceQualifier.main(System.argv())
end
