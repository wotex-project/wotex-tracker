defmodule Wotex.Tracker.Host.Browser.PromptProvider do
  @moduledoc """
  Host-owned bounded request admission. Each proposal runs in a supervised task;
  caller loss and deadlines cancel it. The model never handles service authority.
  """
  use GenServer
  alias Wotex.Tracker.Host.Browser.OpenAI

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: options[:name])

  @doc "Proposes form fields or a clarification, with no raw service data."
  def propose(server, request) do
    GenServer.call(server, {:propose, request}, 15_000)
  catch
    :exit, _ -> {:error, %{"code" => "prompt_unavailable"}}
  end

  @impl true
  def init(options) do
    {:ok,
     %{
       config: Keyword.fetch!(options, :config),
       task_supervisor: Keyword.fetch!(options, :task_supervisor),
       requester: Keyword.get(options, :requester, OpenAI),
       active: %{},
       callers: %{},
       window: System.monotonic_time(:millisecond),
       count: 0
     }}
  end

  @impl true
  def handle_call({:propose, request}, from, state) do
    now = System.monotonic_time(:millisecond)
    state = if now - state.window >= 60_000, do: %{state | window: now, count: 0}, else: state

    if map_size(state.active) >= state.config.max_concurrent or
         state.count >= state.config.max_requests_per_minute do
      {:reply, {:error, %{"code" => "overloaded"}}, state}
    else
      requester = state.requester
      config = state.config

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          requester.request(config, request)
        end)

      caller_monitor = Process.monitor(elem(from, 0))
      timer = Process.send_after(self(), {:deadline, task.ref}, state.config.timeout_ms)
      entry = %{task: task, from: from, caller_monitor: caller_monitor, timer: timer}

      {:noreply,
       %{
         state
         | active: Map.put(state.active, task.ref, entry),
           callers: Map.put(state.callers, caller_monitor, task.ref),
           count: state.count + 1
       }}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case state.active[ref] do
      nil ->
        {:noreply, state}

      entry ->
        GenServer.reply(entry.from, normalize(result))
        {:noreply, release(state, ref, false)}
    end
  end

  def handle_info({:deadline, ref}, state) do
    case state.active[ref] do
      nil ->
        {:noreply, state}

      entry ->
        GenServer.reply(entry.from, {:error, %{"code" => "prompt_unavailable"}})
        {:noreply, release(state, ref, true)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    cond do
      Map.has_key?(state.active, ref) ->
        GenServer.reply(state.active[ref].from, {:error, %{"code" => "prompt_unavailable"}})
        {:noreply, release(state, ref, false)}

      task_ref = state.callers[ref] ->
        {:noreply, release(state, task_ref, true)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp release(state, ref, stop_task?) do
    case Map.pop(state.active, ref) do
      {nil, _} ->
        state

      {entry, active} ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(ref, [:flush])
        Process.demonitor(entry.caller_monitor, [:flush])
        if stop_task?, do: Process.exit(entry.task.pid, :kill)

        %{state | active: active, callers: Map.delete(state.callers, entry.caller_monitor)}
    end
  end

  defp normalize({:ok, proposal}) when is_map(proposal), do: {:ok, proposal}

  defp normalize({:error, %{"code" => code}}) when code in ~w(prompt_invalid prompt_unavailable),
    do: {:error, %{"code" => code}}

  defp normalize(_), do: {:error, %{"code" => "prompt_unavailable"}}
end
