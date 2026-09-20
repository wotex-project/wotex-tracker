defmodule Wotex.Tracker.Nerves.NativeResourceSampler do
  @moduledoc """
  Periodically contributes closed Linux resource samples to operational history.

  The default source reads only fixed procfs paths. Sampling failure is isolated
  from the service and produces no partial or synthetic metric.
  """

  use GenServer

  alias Wotex.Tracker.Nerves.LinuxProcfs
  alias Wotex.Tracker.Service.OperationalTelemetry

  @default_interval_ms 30_000
  @minimum_interval_ms 1_000
  @maximum_interval_ms 300_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) when is_list(options) do
    source = Keyword.get(options, :source, {LinuxProcfs, &File.read/1})
    interval = Keyword.get(options, :interval_ms, @default_interval_ms)

    if source?(source) and interval in @minimum_interval_ms..@maximum_interval_ms do
      send(self(), :sample)
      {:ok, %{source: source, interval_ms: interval}}
    else
      {:stop, :invalid_configuration}
    end
  end

  def init(_), do: {:stop, :invalid_configuration}

  @impl true
  def handle_info(:sample, state) do
    case call(state.source) do
      {:ok, measurements} ->
        OperationalTelemetry.native_resource_sample(:nerves, :linux_procfs, measurements)

      _ ->
        :ok
    end

    Process.send_after(self(), :sample, state.interval_ms)
    {:noreply, state}
  end

  defp source?({module, _context}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :sample, 1)

  defp source?(_), do: false

  defp call({module, context}) do
    module.sample(context)
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
