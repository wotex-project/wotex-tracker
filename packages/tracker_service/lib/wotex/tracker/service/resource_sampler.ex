defmodule Wotex.Tracker.Service.ResourceSampler do
  @moduledoc """
  Host-owned, periodic BEAM resource observation.

  Samples cover the local VM, including other explicitly started instances. They
  are not an OS RSS or per-tenant measurement. The bounded collector owns their
  retention; a sampler failure cannot change domain state.
  """

  use GenServer

  alias Wotex.Tracker.Service.OperationalTelemetry

  @interval_ms 30_000

  @doc false
  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    send(self(), :sample)
    {:ok, :ready}
  end

  @impl true
  def handle_info(:sample, state) do
    OperationalTelemetry.runtime_sample()
    Process.send_after(self(), :sample, @interval_ms)
    {:noreply, state}
  end
end
