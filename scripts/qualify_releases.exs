defmodule Wotex.Tracker.ReleaseQualifier do
  @moduledoc false

  alias Wotex.Tracker.Command

  @root Path.expand("..", __DIR__)
  @builder "wotex-tracker-builder:elixir-1.18.4-otp-27.3.4.15"
  @image "wotex-tracker:0.1.0-linux-arm64-local"
  @ui_image "wotex-tracker-ui:0.1.0-linux-arm64-local"
  @builder_base "hexpm/elixir@sha256:473f77ee88977dc8cc5d05fb91080a308be86be3fc27d50aef9a837d07c8268b"
  @runtime_base "debian@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171"
  @native_client "wotex-tracker-protocol-consumer"
  @linux_native_target "aarch64-linux-musl"

  def verify(workspace, registry, url, environment, ui? \\ false) do
    workspace = Path.expand(workspace)
    destination = Path.join(@root, "_build/releases")
    File.mkdir_p!(destination)
    variant = if(ui?, do: "wotex_tracker_ui", else: "wotex_tracker")
    {native_result, native_archive} = native(workspace, registry, url, environment, ui?)
    File.cp!(native_archive, Path.join(destination, "#{variant}-0.1.0-darwin-arm64.tar.gz"))
    {linux_result, linux_archive} = linux(workspace, registry, ui?)

    if native_result["source_sha256"] != linux_result["source_sha256"],
      do: raise("host source changed between platform builds")

    File.cp!(linux_archive, Path.join(destination, "#{variant}-0.1.0-linux-arm64.tar.gz"))

    %{
      "darwin-arm64" => native_result,
      "linux-arm64" => linux_result,
      "published" => false
    }
  end

  defp native(workspace, registry, url, environment, ui?) do
    source = Path.join(workspace, "native-host")
    digest = source_copy(source, ui?)

    build_environment =
      environment
      |> Map.put("HEX_HOME", Path.join(workspace, "native-host-hex"))
      |> Map.put("WOTEX_TRACKER_UI", if(ui?, do: "1", else: nil))

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
      build_environment
    )

    IO.puts("Host native: resolving ordinary production artifacts and assembling bundled ERTS")

    for command <- [
          ~w(mix deps.get --only prod),
          ~w(mix compile --warnings-as-errors),
          ~w(mix release wotex_tracker)
        ] do
      Command.run!(command, source, build_environment)
    end

    release = Path.join(release_build_path(source, ui?), "rel/wotex_tracker")
    fixtures = Path.join(workspace, "native-fixtures")
    client = build_native_client(workspace)
    probe_environment = Map.put(environment, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    IO.puts("Host native: black-box HTTP/SSE, signal/restart, crash recovery and full storage")

    probe_arguments =
      [
        release,
        Path.join(@root, "scripts/release_probe.exs"),
        release,
        fixtures,
        "--native-consumer",
        client
      ] ++
        if(ui?,
          do: ["--browser", "--native-resource", "darwin_system_tools"],
          else: []
        )

    output =
      Command.plain!(
        Path.join(@root, "scripts/run_release_script"),
        probe_arguments,
        env: probe_environment
      )

    unless String.contains?(output, "RELEASE_PROBE_PASS"),
      do: raise("native bundled release probe did not pass")

    IO.puts(String.trim(output))
    artifact = Path.join(release_build_path(source, ui?), "wotex_tracker-0.1.0.tar.gz")

    {%{
       "source_sha256" => digest,
       "platform" => :erlang.system_info(:system_architecture) |> to_string(),
       "native_client_sha256" => file_digest(client),
       "native_compiler" => "zig " <> (Command.plain!("zig", ["version"]) |> String.trim()),
       "result" => fixtures |> Path.join("result.json") |> File.read!() |> Jason.decode!(),
       "archive_sha256" => file_digest(artifact)
     }, artifact}
  end

  defp linux(workspace, registry, ui?) do
    build = Path.join(workspace, "linux-build")
    File.mkdir!(build)
    digest = source_copy(Path.join(build, "host"), ui?)
    {:ok, _files} = File.cp_r(registry, Path.join(build, "registry"))
    verification = Path.join(build, "verification")
    File.mkdir!(verification)

    for name <- ~w(release_probe.exs http_consumer.exs static_server.exs run_release_script) do
      File.cp!(Path.join(@root, "scripts/#{name}"), Path.join(verification, name))
    end

    File.chmod!(Path.join(verification, "run_release_script"), 0o755)
    client = build_linux_client(build)
    File.cp!(client, Path.join(verification, @native_client))
    File.chmod!(Path.join(verification, @native_client), 0o755)
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    container = "wtr-build-#{suffix}"
    probe = "wtr-probe-#{suffix}"
    volume = "wtr-fixtures-#{suffix}"
    IO.puts("Host Linux ARM64: building pinned toolchain image")

    docker!(
      ~w(build --platform linux/arm64 -f) ++
        [
          Path.join(@root, "hosts/app/Dockerfile.builder"),
          "-t",
          @builder,
          Path.join(@root, "hosts/app")
        ]
    )

    image = image_tag(ui?)

    docker!(
      [
        "run",
        "-d",
        "--name",
        container,
        "--platform",
        "linux/arm64",
        "-v",
        "#{build}:/build",
        "-e",
        "HEX_HOME=/build/hex-home"
      ] ++ ui_build_environment(ui?) ++ [@builder, "sleep", "infinity"]
    )

    try do
      docker!([
        "exec",
        "-d",
        container,
        "elixir",
        "/build/verification/static_server.exs",
        "/build/registry",
        "8765"
      ])

      docker!([
        "exec",
        container,
        "mix",
        "hex.repo",
        "set",
        "hexpm",
        "--url",
        "http://127.0.0.1:8765",
        "--public-key",
        "/build/registry/public_key"
      ])

      IO.puts("Host Linux ARM64: compiling immutable artifacts and bundled release")

      for command <- [
            ~w(mix deps.get --only prod),
            ~w(mix compile --warnings-as-errors),
            ~w(mix release wotex_tracker)
          ] do
        docker!(["exec", container | command])
      end

      packages =
        docker!(["exec", container, "dpkg-query", "-W", "gcc", "libc6", "libssl3", "make"])

      compiler = docker!(["exec", container, "gcc", "--version"]) |> String.split("\n") |> hd()
      builder_id = docker!(["image", "inspect", @builder, "--format", "{{.Id}}"]) |> String.trim()
      context = Path.join(build, "runtime-image")
      File.mkdir!(context)

      {:ok, _files} =
        File.cp_r(
          Path.join(release_build_path(Path.join(build, "host"), ui?), "rel/wotex_tracker"),
          Path.join(context, "release")
        )

      IO.puts("Host Linux ARM64: packaging runtime without external language tools or a compiler")

      docker!([
        "build",
        "--platform",
        "linux/arm64",
        "-f",
        Path.join(@root, "hosts/app/Dockerfile"),
        "-t",
        image,
        context
      ])

      image_id = docker!(["image", "inspect", image, "--format", "{{.Id}}"]) |> String.trim()
      docker!(["volume", "create", volume])

      docker!([
        "run",
        "--rm",
        "--user",
        "0:0",
        "--entrypoint",
        "/bin/sh",
        "-v",
        "#{volume}:/fixtures",
        image,
        "-c",
        "chown 10001:10001 /fixtures && chmod 0700 /fixtures"
      ])

      IO.puts("Host Linux ARM64: read-only container, non-root black-box release lifecycle probe")

      probe_arguments =
        [
          "/opt/wotex",
          "/verification/release_probe.exs",
          "/opt/wotex",
          "/fixtures",
          "--readonly-directory",
          "/var/lib/wotex",
          "--native-consumer",
          "/verification/#{@native_client}"
        ] ++
          if(ui?, do: ["--browser", "--native-resource", "linux_procfs"], else: [])

      output =
        docker!([
          "run",
          "--name",
          probe,
          "--network",
          "none",
          "--read-only",
          "--platform",
          "linux/arm64",
          "--tmpfs",
          "/tmp:rw,nosuid,nodev,mode=1777",
          "-v",
          "#{volume}:/fixtures",
          "-v",
          "#{verification}:/verification:ro",
          "--entrypoint",
          "/verification/run_release_script",
          image
          | probe_arguments
        ])

      unless String.contains?(output, "RELEASE_PROBE_PASS"),
        do: raise("Linux bundled release probe did not pass")

      IO.puts(String.trim(output))
      docker!(["cp", "#{probe}:/fixtures/result.json", Path.join(build, "result.json")])
      result = build |> Path.join("result.json") |> File.read!() |> Jason.decode!()

      if result["external_compiler_absent"] != true,
        do: raise("runtime image contains a compiler")

      artifact =
        Path.join(release_build_path(Path.join(build, "host"), ui?), "wotex_tracker-0.1.0.tar.gz")

      {%{
         "source_sha256" => digest,
         "base_builder" => @builder_base,
         "base_runtime" => @runtime_base,
         "builder_image_id" => builder_id,
         "image_id" => image_id,
         "image_tag" => image,
         "compiler" => compiler,
         "native_builder" => "zig target #{@linux_native_target}",
         "native_compiler" => "zig " <> (Command.plain!("zig", ["version"]) |> String.trim()),
         "native_client_sha256" => file_digest(client),
         "builder_packages" => String.split(packages, "\n", trim: true),
         "result" => result,
         "archive_sha256" => file_digest(artifact)
       }, artifact}
    after
      for target <- [probe, container], do: docker_cleanup(["rm", "-f", target])
      docker_cleanup(["volume", "rm", volume])
    end
  end

  defp source_copy(destination, ui?) do
    File.mkdir!(destination)
    source = Path.join(@root, "hosts/app")

    files = ~w(mix.exs mix.lock README.md LICENSE NOTICE lib config priv rel bin scripts)
    files = if(ui?, do: files ++ ~w(mix.ui.lock ui), else: files)

    for name <- files do
      from = Path.join(source, name)
      to = Path.join(destination, name)

      if File.dir?(from) do
        {:ok, _files} = File.cp_r(from, to)
      else
        File.cp!(from, to)
      end
    end

    destination
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.reduce(:crypto.hash_init(:sha256), fn path, digest ->
      relative = Path.relative_to(path, destination)
      :crypto.hash_update(digest, [relative, <<0>>, File.read!(path)])
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp release_build_path(source, true), do: Path.join(source, "_build/ui/prod")
  defp release_build_path(source, false), do: Path.join(source, "_build/prod")

  defp image_tag(true), do: @ui_image
  defp image_tag(false), do: @image

  defp ui_build_environment(true), do: ["-e", "WOTEX_TRACKER_UI=1"]
  defp ui_build_environment(false), do: []

  defp build_native_client(workspace) do
    source = Path.join(@root, "native/protocol_consumer")
    target = Path.join(workspace, "native-client-darwin")
    cache = Path.join(workspace, "zig-cache-native-client")
    global_cache = Path.join(workspace, "zig-global-cache")
    IO.puts("Host native: compiling independent Zig protocol consumer")

    Command.plain!(
      "zig",
      [
        "build",
        "--build-file",
        Path.join(source, "build.zig"),
        "-Doptimize=ReleaseSafe",
        "--prefix",
        target,
        "--cache-dir",
        cache,
        "--global-cache-dir",
        global_cache
      ]
    )

    Path.join([target, "bin", @native_client])
  end

  defp build_linux_client(build) do
    source = Path.join(@root, "native/protocol_consumer")
    target = Path.join(build, "native-client")
    cache = Path.join(build, "zig-cache-native-client")
    global_cache = Path.join(build, "zig-global-cache")
    IO.puts("Host Linux ARM64: cross-compiling independent static Zig protocol consumer")

    Command.plain!("zig", [
      "build",
      "--build-file",
      Path.join(source, "build.zig"),
      "-Doptimize=ReleaseSafe",
      "-Dtarget=#{@linux_native_target}",
      "--prefix",
      target,
      "--cache-dir",
      cache,
      "--global-cache-dir",
      global_cache
    ])

    Path.join([target, "bin", @native_client])
  end

  defp docker!(arguments), do: Command.plain!("docker", arguments)

  defp docker_cleanup(arguments) do
    _result = System.cmd("docker", arguments, stderr_to_stdout: true)
    :ok
  end

  defp file_digest(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

unless System.get_env("WOTEX_TRACKER_RELEASE_QUALIFIER_NO_MAIN") == "1" do
  raise("qualify_releases.exs is loaded by qualify_source.exs --host")
end
