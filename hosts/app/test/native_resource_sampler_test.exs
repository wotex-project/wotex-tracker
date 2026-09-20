defmodule Wotex.Tracker.Host.NativeResourceSamplerTest do
  use ExUnit.Case, async: false

  alias Wotex.Tracker.Host.{DarwinSystemTools, LinuxProcfs, NativeResourceSampler}
  alias Wotex.Tracker.Service.OperationalHistory

  defmodule Source do
    def sample(:raise), do: raise("synthetic procfs failure")
    def sample(:throw), do: throw(:synthetic_procfs_failure)
    def sample(:block), do: Process.sleep(60_000)
    def sample(result), do: result
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "supported hosts select only their fixed production source" do
    assert {:linux_procfs, LinuxProcfs, reader} =
             NativeResourceSampler.default_source({:unix, :linux})

    assert is_function(reader, 1)

    assert {:darwin_system_tools, DarwinSystemTools, runner} =
             NativeResourceSampler.default_source({:unix, :darwin})

    assert is_function(runner, 2)
    assert nil == NativeResourceSampler.default_source({:win32, :nt})
  end

  test "fixed procfs fields become one exact integer sample" do
    files = %{
      "/proc/meminfo" => "MemTotal: 2048 kB\nMemAvailable: 1024 kB\n",
      "/proc/self/status" => "Name:\tbeam.smp\nVmRSS:\t256 kB\n",
      "/proc/loadavg" => "0.125 0.25 0.5 1/100 123\n"
    }

    reader = fn path -> Map.fetch(files, path) end

    assert {:ok,
            %{
              system_available_memory_bytes: 1_048_576,
              process_rss_bytes: 262_144,
              load_1m_milli: 125
            }} = LinuxProcfs.sample(reader)

    refute inspect(LinuxProcfs.sample(reader)) =~ "/proc"
  end

  test "fixed Darwin tools become one exact integer sample" do
    outputs = %{
      "/usr/bin/vm_stat" =>
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n" <>
          "Pages free: 100.\nPages inactive: 200.\nPages speculative: 25.\n",
      "/bin/ps" => "2048\n",
      "/usr/sbin/sysctl" => "{ 1.25 2.50 5.00 }\n"
    }

    parent = self()

    runner = fn executable, arguments ->
      send(parent, {:command, executable, arguments})
      {Map.fetch!(outputs, executable), 0}
    end

    assert {:ok,
            %{
              system_available_memory_bytes: 5_324_800,
              process_rss_bytes: 2_097_152,
              load_1m_milli: 1_250
            }} = DarwinSystemTools.sample(runner)

    assert_receive {:command, "/usr/bin/vm_stat", []}
    assert_receive {:command, "/bin/ps", ["-o", "rss=", "-p", pid]}
    assert pid == System.pid()
    assert_receive {:command, "/usr/sbin/sysctl", ["-n", "vm.loadavg"]}
  end

  test "missing, malformed and oversized Darwin output fails the whole sample" do
    valid = %{
      "/usr/bin/vm_stat" =>
        "Mach Virtual Memory Statistics: (page size of 4096 bytes)\n" <>
          "Pages free: 10.\nPages inactive: 20.\nPages speculative: 5.\n",
      "/bin/ps" => "1024\n",
      "/usr/sbin/sysctl" => "{ 0.50 1.00 1.50 }\n"
    }

    assert {:error, :unavailable} = DarwinSystemTools.sample(nil)
    assert {:error, :unavailable} = DarwinSystemTools.sample(fn _, _ -> raise "unavailable" end)
    assert {:error, :unavailable} = DarwinSystemTools.sample(fn _, _ -> throw(:unavailable) end)

    for {executable, output} <- [
          {"/usr/bin/vm_stat", "Pages free: 10.\n"},
          {"/bin/ps", "not-rss\n"},
          {"/usr/sbin/sysctl", "not-load\n"}
        ] do
      runner = fn path, _ -> {if(path == executable, do: output, else: valid[path]), 0} end
      assert {:error, :unavailable} = DarwinSystemTools.sample(runner)
    end

    runner = fn path, _ ->
      {if(path == "/usr/bin/vm_stat", do: :binary.copy("x", 65_537), else: valid[path]), 0}
    end

    assert {:error, :unavailable} = DarwinSystemTools.sample(runner)
    assert {:error, :unavailable} = DarwinSystemTools.sample(fn _, _ -> {"unavailable", 1} end)
  end

  test "the real Darwin adapter reads only a complete nonnegative sample" do
    if :os.type() == {:unix, :darwin} do
      assert {:ok, measurements} = DarwinSystemTools.sample()

      assert Enum.sort(Map.keys(measurements)) ==
               ~w(load_1m_milli process_rss_bytes system_available_memory_bytes)a

      assert Enum.all?(measurements, fn {_, value} -> is_integer(value) and value >= 0 end)
    end
  end

  test "missing, malformed and oversized procfs input fails the whole sample" do
    valid = %{
      "/proc/meminfo" => "MemAvailable: 1024 kB\n",
      "/proc/self/status" => "VmRSS: 256 kB\n",
      "/proc/loadavg" => "0.125 0.25 0.5 1/100 123\n"
    }

    assert {:error, :unavailable} = LinuxProcfs.sample(fn _ -> {:error, :enoent} end)
    assert {:error, :unavailable} = LinuxProcfs.sample(nil)
    assert {:error, :unavailable} = LinuxProcfs.sample(fn _ -> raise "unavailable" end)
    assert {:error, :unavailable} = LinuxProcfs.sample(fn _ -> throw(:unavailable) end)

    assert {:error, :unavailable} =
             LinuxProcfs.sample(fn path ->
               Map.fetch!(%{valid | "/proc/meminfo" => "MemTotal: 1024 kB\n"}, path)
               |> then(&{:ok, &1})
             end)

    assert {:error, :unavailable} =
             LinuxProcfs.sample(fn path ->
               Map.fetch!(%{valid | "/proc/loadavg" => "not-a-load\n"}, path) |> then(&{:ok, &1})
             end)

    assert {:error, :unavailable} =
             LinuxProcfs.sample(fn path ->
               value =
                 if path == "/proc/meminfo", do: :binary.copy("x", 65_537), else: valid[path]

               {:ok, value}
             end)
  end

  test "invalid sampler sources and intervals fail startup" do
    assert {:stop, :invalid_configuration} = NativeResourceSampler.init([])
    assert {:stop, :invalid_configuration} = NativeResourceSampler.init(:invalid)

    assert {:stop, :invalid_configuration} =
             NativeResourceSampler.init(
               source: {:linux_procfs, Source, {:error, :unavailable}},
               interval_ms: 999
             )

    assert {:stop, :invalid_configuration} =
             NativeResourceSampler.init(
               source: {:linux_procfs, Source, {:error, :unavailable}},
               interval_ms: 1_000,
               sample_timeout_ms: 99
             )

    assert {:stop, :invalid_configuration} =
             NativeResourceSampler.init(
               source: {:unknown_source, Source, {:error, :unavailable}},
               interval_ms: 1_000
             )

    assert {:stop, :invalid_configuration} =
             NativeResourceSampler.init(
               source: {:linux_procfs, String, :unused},
               interval_ms: 1_000
             )
  end

  test "the sampler emits only the service event and survives source failure" do
    collector = start_supervised!({OperationalHistory, []})

    sampler =
      start_supervised!(
        {NativeResourceSampler,
         source:
           {:linux_procfs, Source,
            {:ok,
             %{
               system_available_memory_bytes: 2_048,
               process_rss_bytes: 1_024,
               load_1m_milli: 75
             }}},
         interval_ms: 60_000}
      )

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [_]}},
        OperationalHistory.snapshot(collector, event: "native.sample")
      )
    end)

    assert Process.alive?(sampler)

    assert {:ok, %{"samples" => [sample]}} =
             OperationalHistory.snapshot(collector, event: "native.sample")

    assert sample["measurements"] == %{
             "system_available_memory_bytes" => 2_048,
             "process_rss_bytes" => 1_024,
             "load_1m_milli" => 75
           }

    assert sample["metadata"] == %{
             "surface" => "service",
             "source" => "linux_procfs"
           }

    failed =
      start_supervised!(
        {NativeResourceSampler, source: {:linux_procfs, Source, :raise}, interval_ms: 60_000},
        id: :failed_sampler
      )

    Process.sleep(10)
    assert Process.alive?(failed)

    thrown =
      start_supervised!(
        {NativeResourceSampler, source: {:linux_procfs, Source, :throw}, interval_ms: 60_000},
        id: :throwing_sampler
      )

    Process.sleep(10)
    assert Process.alive?(thrown)

    assert {:ok, %{"samples" => [_]}} =
             OperationalHistory.snapshot(collector, event: "native.sample")
  end

  test "a blocked native source is killed at its finite deadline" do
    collector = start_supervised!({OperationalHistory, []})

    sampler =
      start_supervised!(
        {NativeResourceSampler,
         source: {:darwin_system_tools, Source, :block},
         interval_ms: 60_000,
         sample_timeout_ms: 100}
      )

    Process.sleep(150)
    assert Process.alive?(sampler)

    assert {:ok, %{"samples" => []}} =
             OperationalHistory.snapshot(collector, event: "native.sample")
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
