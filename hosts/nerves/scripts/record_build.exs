defmodule Wotex.Tracker.Nerves.BuildRecord do
  @moduledoc false

  @base_required ~w(exqlite nerves_runtime nerves_time vintage_net vintage_net_ethernet wotex_tracker_service)
  @base_excluded ~w(nerves_ssh nerves_pack wotex_tracker_host)

  def run do
    ui? = System.get_env("WOTEX_TRACKER_UI") == "1"
    profile = if(ui?, do: "kiosk", else: "headless")
    build_dir = if(ui?, do: "_build/ui", else: "_build")
    system = if(ui?, do: :kiosk_system_rpi5, else: :nerves_system_rpi5)
    host = File.cwd!()
    root = Path.expand("../..", host)
    image = Path.join(host, "#{build_dir}/rpi5_dev/nerves/images/wotex_tracker_nerves.fw")

    release =
      Path.join(
        host,
        "#{build_dir}/rpi5_dev/rel/wotex_tracker_nerves/releases/0.1.0/wotex_tracker_nerves.rel"
      )

    release_root = Path.expand("../../..", release)

    {:ok, [{:release, {release_name, release_version}, {:erts, erts}, applications}]} =
      :file.consult(String.to_charlist(release))

    "wotex_tracker_nerves" = to_string(release_name)
    "0.1.0" = to_string(release_version)
    erts = to_string(erts)

    apps =
      Map.new(applications, fn {name, version, start} ->
        {Atom.to_string(name), {to_string(version), start}}
      end)

    names = Map.keys(apps)
    ui_required = ~w(muontrap myelin phoenix phoenix_live_view wotex_tracker_ui)
    required = @base_required ++ if(ui?, do: ui_required, else: [])

    excluded =
      @base_excluded ++
        if(ui?, do: [], else: ~w(myelin phoenix phoenix_live_view wotex_tracker_ui))

    true = Enum.all?(required, &(&1 in names))
    true = Enum.all?(excluded, &(&1 not in names))

    if ui? do
      kiosk_beam =
        Path.join(
          release_root,
          "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.Kiosk.Process.beam"
        )

      device_session_beam =
        Path.join(
          release_root,
          "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.Browser.DeviceSession.beam"
        )

      device_session_plug_beam =
        Path.join(
          release_root,
          "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.Browser.DeviceSessionPlug.beam"
        )

      true = File.regular?(kiosk_beam)
      true = File.regular?(device_session_beam)
      true = File.regular?(device_session_plug_beam)

      {:ok, {Wotex.Tracker.Nerves.Kiosk.Process, [imports: kiosk_imports]}} =
        :beam_lib.chunks(String.to_charlist(kiosk_beam), [:imports])

      true =
        {Wotex.Tracker.Nerves.Browser.DeviceSession, :launch_url, 1} in kiosk_imports
    end

    {_, :none} = Map.fetch!(apps, "iex")

    application_beam =
      Path.join(
        release_root,
        "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.Application.beam"
      )

    firmware_health_beam =
      Path.join(
        release_root,
        "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.FirmwareHealth.beam"
      )

    provisioner_beam =
      Path.join(
        release_root,
        "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.Provisioner.beam"
      )

    tls_provisioning_beam =
      Path.join(
        release_root,
        "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.TLSProvisioning.beam"
      )

    true = File.regular?(firmware_health_beam)
    true = File.regular?(tls_provisioning_beam)

    {:ok, {Wotex.Tracker.Nerves.Application, [imports: application_imports]}} =
      :beam_lib.chunks(String.to_charlist(application_beam), [:imports])

    true = {Wotex.Tracker.Nerves.FirmwareHealth, :check, 4} in application_imports

    {:ok, {Wotex.Tracker.Nerves.Provisioner, [imports: provisioner_imports]}} =
      :beam_lib.chunks(String.to_charlist(provisioner_beam), [:imports])

    true = {Wotex.Tracker.Nerves.TLSProvisioning, :provision, 4} in provisioner_imports

    args = File.read!(Path.join(release_root, "releases/0.1.0/vm.args"))
    true = String.contains?(args, "-noshell")
    false = Regex.match?(~r/^\s*-(?:name|sname|setcookie|user)\b/m, args)
    true = Regex.match?(~r/^\s*-heart\s+-env\s+HEART_BEAT_TIMEOUT\s+30\s*$/m, args)
    true = Regex.match?(~r/^\s*-env\s+HEART_INIT_TIMEOUT\s+600\s*$/m, args)
    sys_config = File.read!(Path.join(release_root, "releases/0.1.0/sys.config"))
    true = String.contains?(sys_config, "{startup_guard_enabled,true}")
    false = String.contains?(sys_config, "secret_key")
    false = String.contains?(sys_config, "token_sha256")

    nif = Path.join(release_root, "lib/exqlite-0.40.0/priv/sqlite3_nif.so")
    {nif_type, 0} = System.cmd("file", ["-b", nif])
    true = String.contains?(nif_type, "ARM aarch64")

    myelin_extension =
      if ui? do
        {version, _} = Map.fetch!(apps, "myelin")
        library = Path.join(release_root, "lib/myelin-#{version}/priv/webext/libmyelin.so")
        {type, 0} = System.cmd("file", ["-b", library])
        true = String.contains?(type, "ARM aarch64")
        String.trim(type)
      end

    {metadata_text, 0} = System.cmd("fwup", ["-m", "-i", image])

    metadata =
      metadata_text
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {key, String.trim(value, "\"")}
      end)

    "rpi5" = metadata["meta-platform"]
    "aarch64" = metadata["meta-architecture"]
    lock = Mix.Dep.Lock.read()

    firmware =
      %{
        "sha256" => digest(image),
        "bytes" => File.stat!(image).size,
        "metadata" => metadata,
        "target_erts" => erts,
        "target_elixir" => elem(apps["elixir"], 0),
        "sqlite_nif" => String.trim(nif_type)
      }
      |> then(fn value ->
        if ui?, do: Map.put(value, "myelin_web_extension", myelin_extension), else: value
      end)

    record = %{
      "schema" => "wtr.nerves-#{profile}-build.v1",
      "kind" => "development_cross_build",
      "firmware" => firmware,
      "resolved" =>
        Map.new(
          [
            :nerves,
            system,
            :nerves_toolchain_aarch64_nerves_linux_gnu,
            :nerves_runtime,
            :nerves_time,
            :vintage_net,
            :vintage_net_ethernet
          ] ++
            if(ui?, do: [:muontrap, :myelin, :phoenix, :phoenix_live_view], else: []),
          fn name -> {Atom.to_string(name), lock |> Map.fetch!(name) |> elem(2)} end
        ),
      "release_applications" => Enum.sort(names),
      "checks" =>
        %{
          "required_service_network_time_storage" => true,
          "profile_application_set" => true,
          "no_ssh_applications" => true,
          "no_active_iex_or_distribution" => true,
          "no_credentials_in_runtime_config" => true,
          "core_health_before_firmware_validation" => true,
          "firmware_startup_guard_with_finite_heart_timeout" => true,
          "offline_direct_tls_provisioning" => true,
          "sqlite_nif_aarch64" => true
        }
        |> then(fn checks ->
          if ui? do
            Map.merge(checks, %{
              "myelin_web_extension_aarch64" => true,
              "authenticated_local_display_session" => true
            })
          else
            checks
          end
        end),
      "sources" => %{
        "wotex_tracker" => source(root),
        "wotex" => source(Path.expand("../wotex/packages/wotex", root)),
        "wotex_runtime" => source(Path.expand("../wotex/packages/wotex-runtime", root)),
        "wotex_binding_http" => source(Path.expand("../wotex/packages/wotex-binding-http", root))
      },
      "physical_boot" => "not_executed",
      "hardware_acceptance" => "not_executed"
    }

    destination = Path.join(root, "verification/nerves-#{profile}-build.json")
    File.write!(destination, Jason.encode!(record, pretty: true) <> "\n")
    IO.puts("Recorded #{Path.relative_to(destination, root)}")
  end

  defp digest(path) do
    path
    |> File.stream!(1_048_576, [:read, :binary])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp source(path) do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"], cd: path)
    relative = Path.relative_to(path, String.trim(root))

    arguments =
      ["diff", "--name-only", "HEAD", "--"] ++ if(relative == ".", do: [], else: [relative])

    {changed, 0} = System.cmd("git", arguments, cd: path)

    source_changes =
      changed
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "verification/"))

    %{"commit" => String.trim(head), "tracked_changes" => source_changes != []}
  end
end

Wotex.Tracker.Nerves.BuildRecord.run()
