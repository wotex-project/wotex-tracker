defmodule Wotex.Tracker.Service.HTTP.SSEConnection do
  @moduledoc false
  use GenServer
  alias Mint.HTTP1, as: HTTP
  alias Wotex.Tracker.Service.HTTP.SSEParser

  def start(owner, deadline, limit) do
    reference = make_ref()

    case GenServer.start(__MODULE__, {self(), owner, reference, deadline, limit}) do
      {:ok, pid} -> {:ok, {pid, reference}}
      _ -> {:error, :request_failed}
    end
  end

  def activate({pid, reference}, conn, request, responses),
    do: GenServer.call(pid, {reference, :activate, conn, request, responses}, 1000)

  def close({pid, reference}) when is_pid(pid) and is_reference(reference) do
    GenServer.call(pid, {reference, :close}, 1000)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, _ -> {:error, :request_failed}
  end

  def close(_), do: {:error, :request_failed}

  @impl true
  def init({caller, owner, reference, deadline, limit}) do
    timer =
      Process.send_after(self(), :expired, max(deadline - System.monotonic_time(:millisecond), 0))

    {:ok,
     %{
       caller: Process.monitor(caller),
       owner: owner,
       monitor: Process.monitor(owner),
       reference: reference,
       conn: nil,
       request: nil,
       parser: SSEParser.new(limit),
       timer: timer
     }}
  end

  @impl true
  def handle_call(
        {reference, :activate, conn, request, responses},
        _,
        %{reference: reference, conn: nil} = state
      ) do
    with true <- Process.alive?(state.owner), {:ok, conn} <- HTTP.set_mode(conn, :active) do
      Process.demonitor(state.caller, [:flush])
      {:reply, :ok, %{state | conn: conn, request: request, caller: nil}, {:continue, responses}}
    else
      _ -> {:stop, :normal, {:error, :request_failed}, %{state | conn: conn}}
    end
  end

  def handle_call({reference, :close}, _, %{reference: reference} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(_, _, state), do: {:reply, {:error, :request_failed}, state}

  @impl true
  def handle_continue(responses, state), do: frames(responses, state)

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state)
      when monitor in [state.monitor, state.caller],
      do: {:stop, :normal, state}

  def handle_info(:expired, state), do: down(state)
  def handle_info(_, %{conn: nil} = state), do: {:noreply, state}

  def handle_info(message, state) do
    case HTTP.stream(state.conn, message) do
      {:ok, conn, responses} -> frames(responses, %{state | conn: conn})
      {:error, conn, _, _} -> down(%{state | conn: conn})
      :unknown -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_, state) do
    Process.cancel_timer(state.timer)
    if state.conn, do: HTTP.close(state.conn)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      item -> item
    end)
  end

  defp frames(responses, state) do
    Enum.reduce_while(responses, {:noreply, state}, fn response, {:noreply, state} ->
      case response(response, state) do
        {:noreply, state} -> {:cont, {:noreply, state}}
        result -> {:halt, result}
      end
    end)
  end

  defp response({:data, reference, bytes}, %{request: reference} = state) do
    with {:ok, parser, events} <- SSEParser.feed(state.parser, bytes),
         :ok <- deliver(events, state.owner) do
      {:noreply, %{state | parser: parser}}
    else
      _ -> down(state)
    end
  end

  defp response(_, state), do: down(state)

  defp deliver(events, owner) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Process.info(owner, :message_queue_len) do
        {:message_queue_len, count} when count < 32 ->
          send(owner, {:wotex_transport_frame, event})
          {:cont, :ok}

        _ ->
          {:halt, {:error, :overloaded}}
      end
    end)
  end

  defp down(state) do
    send(state.owner, {:wotex_transport_status, :transport_down})
    {:stop, :normal, state}
  end
end
