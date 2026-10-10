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
  @archive_byte_limit 128 * 1024 * 1024
  @decoded_byte_limit 256 * 1024 * 1024
  @member_byte_limit 16 * 1024 * 1024

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
    destination = Path.join(@root, "_build/verification/source-cohort-#{suffix}")

    File.mkdir_p!(Path.dirname(destination))
    File.mkdir!(destination)

    try do
      File.mkdir!(workspace)
      qualify(workspace, destination, service?, host?, ui?)
    rescue
      error ->
        stacktrace = __STACKTRACE__

        try do
          retain_failure(workspace, destination, error)
        rescue
          retention_error ->
            IO.warn(
              "Failure receipt could not be written: #{inspect(retention_error.__struct__)}"
            )
        end

        reraise error, stacktrace
    after
      File.rm_rf!(workspace)
    end
  end

  defp qualify(workspace, destination, service?, host?, ui?) do
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
      write_report(workspace, destination, revisions, results, host_result, service?, host?, ui?)
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

  defp write_report(workspace, destination, revisions, results, host_result, service?, host?, ui?) do
    evidence = retain_archives!(workspace, destination)

    archives =
      Map.new(evidence, fn {name, entry} -> {name, entry["archive_sha256"]} end)

    report = %{
      "scope" => "local-source-cohort-not-public-release",
      "upstream_revision" => revisions["wotex"],
      "upstream_revisions" => revisions,
      "archives" => archives,
      "evidence_directory" => destination,
      "archive_evidence_sha256" => file_digest(Path.join(destination, "archive-evidence.json")),
      "consumers" => results
    }

    report = if host_result, do: Map.put(report, "host", host_result), else: report

    name =
      cond do
        ui? -> "ui-consumer.json"
        host? -> "host-consumer.json"
        service? -> "service-consumer.json"
        true -> "source-consumer.json"
      end

    bytes = Jason.encode!(report, pretty: true) <> "\n"
    File.write!(Path.join(destination, name), bytes, [:exclusive])
    File.write!(Path.join(@root, "_build/verification/#{name}"), bytes)
    IO.puts("Recorded #{destination}/#{name}; temporary registry and keys removed on exit")
  end

  @doc false
  def retain_archives!(workspace, destination) do
    archives = Path.wildcard(Path.join(workspace, "registry/tarballs/*.tar")) |> Enum.sort()
    if length(archives) > 512, do: raise("archive inventory count exceeds limit")
    total = Enum.reduce(archives, 0, &(File.stat!(&1).size + &2))
    if total > 512 * 1024 * 1024, do: raise("archive inventory bytes exceed limit")
    retained = Path.join(destination, "archives")
    File.mkdir!(retained)

    evidence =
      Map.new(archives, fn archive ->
        name = Path.basename(archive)
        bytes = bounded_read!(archive, @archive_byte_limit)
        File.write!(Path.join(retained, name), bytes, [:exclusive])
        entry = %{"archive_sha256" => digest(bytes), "bytes" => byte_size(bytes)}

        inspected =
          try do
            Map.merge(entry, inspect_archive!(bytes, source_owner(workspace, name)))
          rescue
            error ->
              Map.merge(entry, %{
                "result" => "failed",
                "failure_class" => inspect(error.__struct__)
              })
          end

        {name, inspected}
      end)

    File.write!(
      Path.join(destination, "archive-evidence.json"),
      Jason.encode!(evidence, pretty: true) <> "\n",
      [:exclusive]
    )

    if Enum.any?(evidence, fn {_, entry} -> entry["result"] != "pass" end),
      do: raise("retained archive inspection failed; see archive-evidence.json")

    evidence
  end

  @doc false
  def retain_failure(workspace, destination, error) do
    unless File.exists?(Path.join(destination, "archive-evidence.json")) do
      try do
        retain_archives!(workspace, destination)
      rescue
        retention_error ->
          IO.warn("Archive retention failed: #{inspect(retention_error.__struct__)}")
      end
    end

    File.write!(
      Path.join(destination, "failure.json"),
      Jason.encode!(%{"result" => "failed", "failure_class" => inspect(error.__struct__)}) <>
        "\n",
      [:exclusive]
    )
  end

  defp source_owner(workspace, name) do
    Map.get(
      %{
        "wotex-0.1.0.tar" => Path.join(workspace, "wotex/packages/wotex"),
        "wotex_runtime-0.1.0.tar" => Path.join(workspace, "wotex/packages/wotex-runtime"),
        "wotex_binding_http-0.1.0.tar" =>
          Path.join(workspace, "wotex/packages/wotex-binding-http"),
        "wotex_tracker-0.1.0.tar" => @root,
        "wotex_tracker_service-0.1.0.tar" => Path.join(@root, "packages/tracker_service"),
        "wotex_tracker_ui-0.1.0.tar" => Path.join(@root, "packages/tracker_ui")
      },
      name
    )
  end

  defp inspect_archive!(bytes, source) do
    {outer, outer_members} = regular_members!(bytes)

    unless Enum.sort(Map.keys(outer)) == ~w(CHECKSUM VERSION contents.tar.gz metadata.config),
      do: raise("unexpected Hex outer members")

    unless outer["VERSION"] == "3", do: raise("unexpected Hex archive version")
    checksum = outer["CHECKSUM"] |> String.trim() |> String.downcase()

    unless checksum ==
             digest([outer["VERSION"], outer["metadata.config"], outer["contents.tar.gz"]]),
           do: raise("Hex inner checksum differs")

    contents = bounded_gunzip!(outer["contents.tar.gz"])
    {files, members} = regular_members!(contents)

    members =
      Map.new(members, fn {name, member} ->
        if source do
          path = Path.join(source, name)

          comparison =
            try do
              source_sha = path |> bounded_read!(@member_byte_limit) |> digest()
              source_mode = rem(File.lstat!(path).mode, 0o10000)

              %{
                "source_sha256" => source_sha,
                "source_mode" => source_mode,
                "source_matches" =>
                  source_sha == digest(files[name]) and
                    source_mode == rem(member["mode"], 0o10000)
              }
            rescue
              error ->
                %{"source_matches" => false, "source_failure_class" => inspect(error.__struct__)}
            end

          {name, Map.merge(member, comparison)}
        else
          {name, member}
        end
      end)

    matches = is_nil(source) or Enum.all?(members, fn {_, member} -> member["source_matches"] end)

    %{
      "result" => if(matches, do: "pass", else: "failed"),
      "source_comparison" =>
        if(source, do: "local-owner", else: "registry-dependency-not-compared"),
      "source_root" => source,
      "hex_inner_checksum" => checksum,
      "contents_tar_gz_sha256" => digest(outer["contents.tar.gz"]),
      "contents_tar_sha256" => digest(contents),
      "outer_members" => outer_members,
      "regular_members" => members
    }
  end

  defp regular_members!(bytes) do
    {:ok, entries} = :erl_tar.table({:binary, bytes}, [:verbose])
    if length(entries) > 10_000, do: raise("archive member count exceeds limit")
    names = Enum.map(entries, fn {name, _, _, _, _, _, _} -> List.to_string(name) end)
    unless Enum.uniq(names) == names, do: raise("duplicate archive members")

    Enum.each(entries, fn {name, type, size, _, _, _, _} ->
      name = List.to_string(name)

      unless type in [:regular, :directory] and size <= @member_byte_limit and
               Path.type(name) == :relative and name != "" and
               not Enum.any?(Path.split(name), &(&1 in [".", ".."])) and
               byte_size(name) <= 1024,
             do: raise("invalid archive member")
    end)

    {:ok, files} = :erl_tar.extract({:binary, bytes}, [:memory])
    files = Map.new(files, fn {name, payload} -> {List.to_string(name), payload} end)

    members =
      entries
      |> Enum.filter(fn {_, type, _, _, _, _, _} -> type == :regular end)
      |> Map.new(fn {name, _, size, _, mode, _, _} ->
        name = List.to_string(name)
        payload = Map.fetch!(files, name)
        unless byte_size(payload) == size, do: raise("archive member size differs")
        {name, %{"bytes" => size, "mode" => mode, "sha256" => digest(payload)}}
      end)

    {files, members}
  end

  defp bounded_read!(path, limit) do
    unless File.lstat!(path).type == :regular and File.stat!(path).size <= limit,
      do: raise("file exceeds archive evidence limit")

    bytes = File.read!(path)
    if byte_size(bytes) > limit, do: raise("file exceeds archive evidence limit")
    bytes
  end

  defp bounded_gunzip!(bytes) do
    stream = :zlib.open()

    try do
      :ok = :zlib.inflateInit(stream, 31, :reset)
      result = inflate_chunks(stream, :zlib.safeInflate(stream, bytes), [], 0)
      :ok = :zlib.inflateEnd(stream)
      IO.iodata_to_binary(result)
    after
      :zlib.close(stream)
    end
  end

  defp inflate_chunks(stream, {status, chunk}, chunks, total)
       when status in [:continue, :finished] do
    total = total + IO.iodata_length(chunk)
    if total > @decoded_byte_limit, do: raise("decoded archive exceeds evidence limit")
    chunks = [chunk | chunks]

    if status == :finished,
      do: Enum.reverse(chunks),
      else: inflate_chunks(stream, :zlib.safeInflate(stream, []), chunks, total)
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

  @doc false
  def clean_environment(environment \\ System.get_env()) do
    environment
    |> Map.new(fn {key, value} ->
      if String.starts_with?(key, "WOTEX_TRACKER_"), do: {key, nil}, else: {key, value}
    end)
    |> Map.merge(%{
      "WOTEX_PATH_DEPS" => nil,
      "MIX_BUILD_PATH" => nil,
      "MIX_BUILD_ROOT" => nil,
      "MIX_DEPS_PATH" => nil,
      "MIX_LOCKFILE" => nil,
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
