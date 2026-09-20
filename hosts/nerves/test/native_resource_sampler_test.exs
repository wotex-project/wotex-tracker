defmodule Wotex.Tracker.Nerves.NativeResourceSamplerTest do
  use ExUnit.Case, async: false

  alias Wotex.Tracker.Nerves.{LinuxProcfs, NativeResourceSampler}
  alias Wotex.Tracker.Service.OperationalHistory

  defmodule Source do
    def sample(:raise), do: raise("synthetic procfs failure")
    def sample(result), do: result
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
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

  test "missing, malformed and oversized procfs input fails the whole sample" do
    valid = %{
      "/proc/meminfo" => "MemAvailable: 1024 kB\n",
      "/proc/self/status" => "VmRSS: 256 kB\n",
      "/proc/loadavg" => "0.125 0.25 0.5 1/100 123\n"
    }

    assert {:error, :unavailable} = LinuxProcfs.sample(fn _ -> {:error, :enoent} end)

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

  test "the sampler emits only the closed native event and survives source failure" do
    collector = start_supervised!({OperationalHistory, []})

    sampler =
      start_supervised!(
        {NativeResourceSampler,
         source:
           {Source,
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
             "surface" => "nerves",
             "source" => "linux_procfs"
           }

    failed =
      start_supervised!(
        {NativeResourceSampler, source: {Source, :raise}, interval_ms: 60_000},
        id: :failed_sampler
      )

    Process.sleep(10)
    assert Process.alive?(failed)

    assert {:ok, %{"samples" => [_]}} =
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
