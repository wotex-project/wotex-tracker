defmodule Wotex.Tracker.Host.NativeResourceSampler do
  @moduledoc """
  Periodically contributes closed native resource samples to operational history.

  Production sources use only fixed Linux procfs paths or fixed macOS system
  tools. Sampling failure and finite source deadlines are isolated from the
  service and produce no partial or synthetic metric.
  """

  use GenServer

  alias Wotex.Tracker.Host.{DarwinSystemTools, LinuxProcfs}
  alias Wotex.Tracker.Service.OperationalTelemetry

  @default_interval_ms 30_000
  @default_sample_timeout_ms 2_000
  @minimum_interval_ms 1_000
  @maximum_interval_ms 300_000
  @minimum_sample_timeout_ms 100
  @maximum_sample_timeout_ms 5_000
  @sources ~w(darwin_system_tools linux_procfs)a

  @doc false
  def default_source({:unix, :darwin}),
    do: {:darwin_system_tools, DarwinSystemTools, &DarwinSystemTools.command/2}

  def default_source({:unix, :linux}), do: {:linux_procfs, LinuxProcfs, &File.read/1}
  def default_source(_), do: nil

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) when is_list(options) do
    source = Keyword.get(options, :source)
    interval = Keyword.get(options, :interval_ms, @default_interval_ms)
    sample_timeout = Keyword.get(options, :sample_timeout_ms, @default_sample_timeout_ms)

    if source?(source) and interval in @minimum_interval_ms..@maximum_interval_ms and
         sample_timeout in @minimum_sample_timeout_ms..@maximum_sample_timeout_ms do
      send(self(), :sample)
      {:ok, %{source: source, interval_ms: interval, sample_timeout_ms: sample_timeout}}
    else
      {:stop, :invalid_configuration}
    end
  end

  def init(_), do: {:stop, :invalid_configuration}

  @impl true
  def handle_info(:sample, state) do
    case call(state.source, state.sample_timeout_ms) do
      {:ok, source, measurements} ->
        OperationalTelemetry.native_resource_sample(:service, source, measurements)

      _ ->
        :ok
    end

    Process.send_after(self(), :sample, state.interval_ms)
    {:noreply, state}
  end

  defp source?({source, module, _context}) when source in @sources and is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :sample, 1)

  defp source?(_), do: false

  defp call({source, module, context}, timeout) do
    task = Task.async(fn -> invoke(module, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, measurements}} -> {:ok, source, measurements}
      _ -> {:error, :unavailable}
    end
  end

  defp invoke(module, context) do
    module.sample(context)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
