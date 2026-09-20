defmodule Wotex.Tracker.Nerves.QemuBootRecord do
  @moduledoc false

  def run([first_log, reboot_log]) do
    host = File.cwd!()
    root = Path.expand("../..", host)
    build = Path.join(host, "_build/qemu/qemu_aarch64_dev")
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

    true =
      Enum.all?(
        ~w(nerves_ssh nerves_pack phoenix phoenix_live_view wotex_tracker_ui)a,
        &(&1 not in names)
      )

    {_, :none} = Map.fetch!(apps, :iex)

    fixture_beam =
      Path.join(
        release_root,
        "lib/wotex_tracker_nerves-0.1.0/ebin/Elixir.Wotex.Tracker.Nerves.QemuFixture.beam"
      )

    true = File.regular?(fixture_beam)

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

    true = File.regular?(firmware_health_beam)

    {:ok, {Wotex.Tracker.Nerves.Application, [imports: application_imports]}} =
      :beam_lib.chunks(String.to_charlist(application_beam), [:imports])

    true = {Wotex.Tracker.Nerves.FirmwareHealth, :check, 4} in application_imports

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
        "QEMU boot probe passed: private store, loopback HTTP and native resources"
      )

    true = String.contains?(reboot, "Booting from slot a")
    false = String.contains?(reboot, "Formatting application partition")
    true = String.contains?(first, "initialized storage marker")
    true = String.contains?(reboot, "initialized storage marker")

    true =
      String.contains?(
        reboot,
        "QEMU boot probe passed: private store, loopback HTTP and native resources"
      )

    false = String.contains?(first <> reboot, "QEMU boot probe failed")
    [_, kernel] = Regex.run(~r/Linux version (\S+)/, first)

    [_, qemu] =
      Regex.run(
        ~r/QEMU emulator version (\S+)/,
        elem(System.cmd("qemu-system-aarch64", ["--version"]), 0)
      )

    lock = Mix.Dep.Lock.read("mix.qemu.lock")

    record = %{
      "schema" => "wtr.nerves-qemu-boot.v1",
      "kind" => "virtual_firmware_boot",
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
      "checks" => %{
        "first_boot_formatted_fresh_partition" => true,
        "first_boot_private_store_and_loopback_http" => true,
        "first_boot_native_resource_sample" => true,
        "first_boot_initialized_storage_marker" => true,
        "reboot_kept_existing_partition" => true,
        "reboot_private_store_and_loopback_http" => true,
        "reboot_native_resource_sample" => true,
        "reboot_initialized_storage_marker" => true,
        "no_ui_or_ssh_applications" => true,
        "no_active_iex_or_distribution" => true,
        "no_credentials_in_runtime_config" => true,
        "core_health_before_firmware_validation" => true,
        "firmware_startup_guard_with_finite_heart_timeout" => true,
        "sqlite_nif_aarch64" => true
      },
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

    destination = Path.join(root, "verification/nerves-qemu-boot.json")
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
    relative = Path.relative_to(path, String.trim(root))

    arguments =
      ["diff", "--name-only", "HEAD", "--"] ++ if(relative == ".", do: [], else: [relative])

    {changed, 0} = System.cmd("git", arguments, cd: path)

    source_changes =
      changed
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "verification/"))

    %{
      "commit" => String.trim(head),
      "tracked_changes" => source_changes != [],
      "tracked_paths" => source_changes
    }
  end
end

Wotex.Tracker.Nerves.QemuBootRecord.run(System.argv())
