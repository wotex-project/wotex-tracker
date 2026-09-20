defmodule Wotex.Tracker.Service.Cellular.Connection do
  @moduledoc false

  use ThousandIsland.Handler

  alias ThousandIsland.Socket
  alias Wotex.Tracker.Protocols.Teltonika.{Codec8Extended, TCPSession}
  alias Wotex.Tracker.Service.Cellular.{Ingress, Server}

  @impl ThousandIsland.Handler
  def handle_connection(_socket, options) do
    state =
      Map.merge(options, %{
        phase: :login,
        login: TCPSession.new_login(),
        stream: nil,
        ingress: nil,
        session: nil,
        deadline: deadline(options.login_timeout_ms)
      })

    continue(state)
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, %{phase: :login} = state),
    do: login(data, socket, state)

  def handle_data(data, socket, %{phase: :frames} = state),
    do: frames(data, socket, state)

  @impl ThousandIsland.Handler
  def handle_close(_socket, state), do: release(state)

  @impl ThousandIsland.Handler
  def handle_error(_reason, _socket, state), do: release(state)

  @impl ThousandIsland.Handler
  def handle_shutdown(_socket, state), do: release(state)

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state), do: release(state)

  defp login(data, socket, state) do
    case TCPSession.feed_login(state.login, data) do
      {:ok, login} ->
        continue(%{state | login: login})

      {:login, imei, tail} ->
        admit_login(imei, tail, socket, state)

      {:error, _} ->
        {:close, state}
    end
  end

  defp admit_login(imei, tail, socket, state) do
    with {:ok, ingress} <- Server.ingress(state.server),
         {:ok, session} <- call(fn -> Ingress.login(ingress, imei) end),
         :ok <- Socket.send(socket, TCPSession.login_reply(:accepted)) do
      state = %{
        state
        | phase: :frames,
          login: nil,
          stream: Codec8Extended.new_stream(),
          ingress: ingress,
          session: session,
          deadline: deadline(state.frame_timeout_ms)
      }

      if tail == <<>>, do: continue(state), else: frames(tail, socket, state)
    else
      {:error, reason} when reason in [:unauthorized, :busy] ->
        _ = Socket.send(socket, TCPSession.login_reply(:rejected))
        {:close, state}

      _ ->
        {:close, state}
    end
  end

  defp frames(data, socket, state) do
    case Codec8Extended.feed(state.stream, data) do
      {:ok, stream, packets} ->
        continue_frames(packets, socket, %{state | stream: stream})

      {:error, _} ->
        {:close, state}
    end
  end

  defp continue_frames(packets, socket, state) do
    case acknowledge(packets, socket, state) do
      {:ok, state} -> continue(reset_frame_deadline(state, packets))
      :close -> {:close, state}
    end
  end

  defp reset_frame_deadline(state, []), do: state

  defp reset_frame_deadline(state, _packets),
    do: %{state | deadline: deadline(state.frame_timeout_ms)}

  defp acknowledge([], _socket, state), do: {:ok, state}

  defp acknowledge([packet | packets], socket, state) do
    with {:ok, receipt} <- call(fn -> Ingress.submit(state.ingress, state.session, packet) end),
         {:ok, {:send, reply}} <-
           TCPSession.data_reply(receipt.record_count, receipt.disposition),
         :ok <- Socket.send(socket, reply) do
      acknowledge(packets, socket, state)
    else
      _ -> :close
    end
  end

  defp continue(state) do
    case state.deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:continue, state, remaining}
      _ -> {:close, state}
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp call(function) do
    function.()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp release(%{ingress: ingress, session: session})
       when is_pid(ingress) and not is_nil(session),
       do: Ingress.close(ingress, session)

  defp release(_), do: :ok
end
