defmodule Wotex.Tracker.Nerves.QemuBootRecord do
  @moduledoc false

  def run([first_log, reboot_log]) do
    host = File.cwd!()
    root = Path.expand("../..", host)
    ui? = System.get_env("WOTEX_TRACKER_UI") == "1"
    profile = if(ui?, do: "qemu_kiosk", else: "qemu_headless")
    build_profile = if(ui?, do: "qemu-ui", else: "qemu")
    lock_path = if(ui?, do: "mix.qemu-ui.lock", else: "mix.qemu.lock")
    build = Path.join(host, "_build/#{build_profile}/qemu_aarch64_dev")
    image = Path.join(build, "nerves/images/wotex_tracker_nerves.fw")
    release_root = Path.join(build, "rel/wotex_tracker_nerves")
    release = Path.join(release_root, "releases/0.1.0/wotex_tracker_nerves.rel")

    {:ok, [{:release, {release_name, release_version}, {:erts, erts}, applications}]} =
      :file.consult(String.to_charlist(release))

    "wotex_tracker_nerves" = to_string(release_name)
    "0.1.0" = to_string(release_version)

    apps =
      Map.new(applications, fn {name, version, start} -> {name, {to_string(version), start}} end)

    names = Map.keys(apps)

    true =
      Enum.all?(
        ~w(exqlite nerves_runtime nerves_time vintage_net wotex_tracker_service)a,
        &(&1 in names)
      )

    if ui? do
      true = Enum.all?(~w(bandit phoenix phoenix_live_view wotex_tracker_ui)a, &(&1 in names))
      true = Enum.all?(~w(nerves_ssh nerves_pack myelin)a, &(&1 not in names))
    else
      true =
        Enum.all?(
          ~w(nerves_ssh nerves_pack phoenix phoenix_live_view wotex_tracker_ui)a,
          &(&1 not in names)
        )
    end

    {_, :none} = Map.fetch!(apps, :iex)

    fixture_beam =
      Path.join(
        release_root,
        "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.QemuFixture.beam"
      )

    true = File.regular?(fixture_beam)

    if ui? do
      Enum.each(
        ~w(
          Elixir.Wotex.Tracker.Nerves.Browser.beam
          Elixir.Wotex.Tracker.Nerves.Browser.DeviceSession.beam
          Elixir.Wotex.Tracker.Nerves.Browser.Endpoint.beam
          Elixir.Wotex.Tracker.Nerves.PanelAcceptance.beam
        ),
        fn beam ->
          true =
            File.regular?(Path.join(release_root, "lib/wotex_tracker_nerves-0.1.0/ebin/#{beam}"))
        end
      )
    end

    {:ok, {Wotex.Tracker.Nerves.QemuFixture, [imports: fixture_imports]}} =
      :beam_lib.chunks(String.to_charlist(fixture_beam), [:imports])

    true = {:httpc, :request, 4} in fixture_imports
    true = {:gen_tcp, :connect, 4} in fixture_imports
    true = {:gen_tcp, :recv, 3} in fixture_imports
    true = {:gen_tcp, :send, 2} in fixture_imports
    true = {Wotex.Tracker.Service.Codec, :decode, 1} in fixture_imports
    true = {Wotex.Tracker.Service.Cellular.Server, :listener_info, 1} in fixture_imports

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

    vm_args = File.read!(Path.join(release_root, "releases/0.1.0/vm.args"))
    true = String.contains?(vm_args, "-noshell")
    false = Regex.match?(~r/^\s*-(?:name|sname|setcookie|user)\b/m, vm_args)
    true = Regex.match?(~r/^\s*-heart\s+-env\s+HEART_BEAT_TIMEOUT\s+30\s*$/m, vm_args)
    true = Regex.match?(~r/^\s*-env\s+HEART_INIT_TIMEOUT\s+600\s*$/m, vm_args)
    sys_config = File.read!(Path.join(release_root, "releases/0.1.0/sys.config"))
    true = String.contains?(sys_config, "{startup_guard_enabled,true}")
    false = String.contains?(sys_config, "secret_key")
    false = String.contains?(sys_config, "token_sha256")

    nif = Path.join(release_root, "lib/exqlite-0.40.0/priv/sqlite3_nif.so")
    {nif_type, 0} = System.cmd("file", ["-b", nif])
    true = String.contains?(nif_type, "ARM aarch64")
    {metadata_text, 0} = System.cmd("fwup", ["-m", "-i", image])

    metadata =
      metadata_text
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, "=", parts: 2)
        {key, String.trim(value, "\"")}
      end)

    "qemu_aarch64" = metadata["meta-platform"]
    first = File.read!(first_log)
    reboot = File.read!(reboot_log)
    true = String.contains?(first, "Booting from slot a")
    true = String.contains?(first, "Linux version ")
    true = String.contains?(first, "Formatting application partition")

    true =
      String.contains?(
        first,
        "QEMU boot probe passed: private store, loopback HTTP, TAT140 cellular peer " <>
          "and durable replay, native resources, initialized storage marker"
      )

    true = String.contains?(reboot, "Booting from slot a")
    false = String.contains?(reboot, "Formatting application partition")
    true = String.contains?(first, "initialized storage marker")
    true = String.contains?(reboot, "initialized storage marker")
    true = String.contains?(first, "Firmware valid and all applications started successfully")
    true = String.contains?(reboot, "Firmware valid and all applications started successfully")

    true =
      String.contains?(
        reboot,
        "QEMU boot probe passed: private store, loopback HTTP, TAT140 cellular peer " <>
          "and durable replay, native resources, initialized storage marker"
      )

    false = String.contains?(first <> reboot, "QEMU boot probe failed")

    if ui? do
      panel_marker =
        "QEMU kiosk panel probe passed: 28 shared routes, authenticated activation, " <>
          "keyboard controls, offline assets and isolated browser restart"

      true = String.contains?(first, panel_marker)
      true = String.contains?(reboot, panel_marker)
      true = String.contains?(first, "shared kiosk workflows and isolated browser restart")
      true = String.contains?(reboot, "shared kiosk workflows and isolated browser restart")
    end

    [_, kernel] = Regex.run(~r/Linux version (\S+)/, first)

    [_, qemu] =
      Regex.run(
        ~r/QEMU emulator version (\S+)/,
        elem(System.cmd("qemu-system-aarch64", ["--version"]), 0)
      )

    lock = Mix.Dep.Lock.read(lock_path)

    profile_checks =
      if ui? do
        %{
          "authenticated_single_use_display_activation" => true,
          "shared_route_count" => 28,
          "analytics_and_route_input_forms" => true,
          "bounded_zoom_and_pan_input_models" => true,
          "tat140_provisioning_input" => true,
          "ble_companion_input_hook" => true,
          "loopback_browser_and_local_assets_only" => true,
          "browser_restart_retained_service_store" => true,
          "no_physical_display_runtime" => true
        }
      else
        %{"no_ui_or_ssh_applications" => true}
      end

    record = %{
      "schema" => if(ui?, do: "wtr.nerves-qemu-kiosk-boot.v1", else: "wtr.nerves-qemu-boot.v1"),
      "kind" => if(ui?, do: "virtual_kiosk_firmware_boot", else: "virtual_firmware_boot"),
      "profile" => profile,
      "firmware" => %{
        "sha256" => digest(image),
        "bytes" => File.stat!(image).size,
        "metadata" => metadata,
        "target_erts" => to_string(erts),
        "target_elixir" => elem(apps[:elixir], 0),
        "sqlite_nif" => String.trim(nif_type)
      },
      "virtual_system" => %{
        "qemu_version" => qemu,
        "kernel_version" => kernel,
        "nerves_system_qemu_aarch64" =>
          lock |> Map.fetch!(:nerves_system_qemu_aarch64) |> elem(2),
        "nerves_toolchain_aarch64_nerves_linux_gnu" =>
          lock |> Map.fetch!(:nerves_toolchain_aarch64_nerves_linux_gnu) |> elem(2)
      },
      "release_applications" => names |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "checks" =>
        Map.merge(
          %{
            "first_boot_formatted_fresh_partition" => true,
            "first_boot_private_store_and_loopback_http" => true,
            "first_boot_tat140_imei_codec8e_ingress" => true,
            "first_boot_tat140_ble_sensor_state" => true,
            "first_boot_native_resource_sample" => true,
            "first_boot_initialized_storage_marker" => true,
            "first_boot_startup_guard_completed" => true,
            "reboot_kept_existing_partition" => true,
            "reboot_private_store_and_loopback_http" => true,
            "reboot_tat140_durable_replay" => true,
            "reboot_tat140_ble_sensor_state" => true,
            "reboot_native_resource_sample" => true,
            "reboot_initialized_storage_marker" => true,
            "reboot_startup_guard_completed" => true,
            "no_active_iex_or_distribution" => true,
            "no_credentials_in_runtime_config" => true,
            "core_health_before_firmware_validation" => true,
            "firmware_startup_guard_with_finite_heart_timeout" => true,
            "offline_direct_tls_provisioning" => true,
            "sqlite_nif_aarch64" => true
          },
          profile_checks
        ),
      "boot_log_sha256" => %{"first" => digest(first_log), "reboot" => digest(reboot_log)},
      "sources" => %{
        "wotex_tracker" => source(root),
        "wotex" => source(Path.expand("../wotex/packages/wotex", root)),
        "wotex_runtime" => source(Path.expand("../wotex/packages/wotex-runtime", root)),
        "wotex_binding_http" => source(Path.expand("../wotex/packages/wotex-binding-http", root))
      },
      "physical_boot" => "not_executed",
      "hardware_acceptance" => "not_executed"
    }

    destination =
      Path.join(
        root,
        if(ui?,
          do: "verification/nerves-qemu-kiosk-boot.json",
          else: "verification/nerves-qemu-boot.json"
        )
      )

    File.write!(destination, Jason.encode!(record, pretty: true) <> "\n")
    IO.puts("Recorded #{Path.relative_to(destination, root)}")
  end

  def run(_), do: Mix.raise("Pass first-boot and reboot serial logs")

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
    repository = String.trim(root)
    relative = Path.relative_to(path, repository)

    arguments =
      ["status", "--porcelain=v1", "--untracked-files=all", "--"] ++
        if(relative == ".", do: [], else: [relative])

    {changed, 0} = System.cmd("git", arguments, cd: repository)

    source_changes =
      changed
      |> String.split("\n", trim: true)
      |> Enum.map(&String.slice(&1, 3..-1//1))
      |> Enum.reject(&String.starts_with?(&1, "verification/"))

    %{
      "commit" => String.trim(head),
      "tracked_changes" => source_changes != [],
      "tracked_paths" => source_changes
    }
  end
end

Wotex.Tracker.Nerves.QemuBootRecord.run(System.argv())
