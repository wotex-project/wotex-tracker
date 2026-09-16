defmodule Wotex.Tracker.Nerves.BuildRecord do
  @moduledoc false

  @required ~w(exqlite nerves_runtime nerves_time vintage_net vintage_net_ethernet wotex_tracker_service)
  @excluded ~w(nerves_ssh nerves_pack phoenix phoenix_live_view wotex_tracker_host wotex_tracker_ui)

  def run do
    host = File.cwd!()
    root = Path.expand("../..", host)
    image = Path.join(host, "_build/rpi5_dev/nerves/images/wotex_tracker_nerves.fw")

    release =
      Path.join(
        host,
        "_build/rpi5_dev/rel/wotex_tracker_nerves/releases/0.1.0/wotex_tracker_nerves.rel"
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
    true = Enum.all?(@required, &(&1 in names))
    true = Enum.all?(@excluded, &(&1 not in names))
    {_, :none} = Map.fetch!(apps, "iex")

    args = File.read!(Path.join(release_root, "releases/0.1.0/vm.args"))
    true = String.contains?(args, "-noshell")
    false = Regex.match?(~r/^\s*-(?:name|sname|setcookie|user)\b/m, args)
    sys_config = File.read!(Path.join(release_root, "releases/0.1.0/sys.config"))
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

    "rpi5" = metadata["meta-platform"]
    "aarch64" = metadata["meta-architecture"]
    lock = Mix.Dep.Lock.read()

    record = %{
      "schema" => "wtr.nerves-headless-build.v1",
      "kind" => "development_cross_build",
      "firmware" => %{
        "sha256" => digest(image),
        "bytes" => File.stat!(image).size,
        "metadata" => metadata,
        "target_erts" => erts,
        "target_elixir" => elem(apps["elixir"], 0),
        "sqlite_nif" => String.trim(nif_type)
      },
      "resolved" =>
        Map.new(
          ~w(nerves nerves_system_rpi5 nerves_toolchain_aarch64_nerves_linux_gnu nerves_runtime nerves_time vintage_net vintage_net_ethernet)a,
          fn name -> {Atom.to_string(name), lock |> Map.fetch!(name) |> elem(2)} end
        ),
      "release_applications" => Enum.sort(names),
      "checks" => %{
        "required_service_network_time_storage" => true,
        "no_browser_or_ssh_applications" => true,
        "no_active_iex_or_distribution" => true,
        "no_credentials_in_runtime_config" => true,
        "sqlite_nif_aarch64" => true
      },
      "sources" => %{
        "wotex_tracker" => source(root),
        "wotex" => source(Path.expand("../wotex", root)),
        "wotex_runtime" => source(Path.expand("../wotex-runtime", root)),
        "wotex_binding_http" => source(Path.expand("../wotex-binding-http", root))
      },
      "physical_boot" => "not_executed",
      "hardware_acceptance" => "not_executed"
    }

    destination = Path.join(root, "verification/nerves-headless-build.json")
    File.write!(destination, Jason.encode!(record, pretty: true) <> "\n")
    IO.puts("Recorded #{Path.relative_to(destination, root)}")
  end

  defp digest(path) do
    path
    |> File.stream!([:read, :binary], 1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp source(path) do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    {status, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=no"], cd: path)
    %{"commit" => String.trim(head), "tracked_changes" => String.trim(status) != ""}
  end
end

Wotex.Tracker.Nerves.BuildRecord.run()
