defmodule Wotex.Tracker.Service.Cellular.Ingress do
  @moduledoc """
  Serialized, configured admission from Teltonika TCP packets into the service.

  The process owns private IMEI lookup material and service bearer tokens. Login
  compares a keyed digest with an explicit finite device configuration; the raw
  IMEI is never retained in process state. This is configured routing admission,
  not cryptographic device authentication.

  Every decoded frame is revalidated, represented by one atomic cellular
  observation and submitted with a deterministic UUID operation identity. A
  reconnect first resolves the retained operation receipt, allowing an unknown
  post-commit outcome to become a duplicate without rewriting the observation.
  Calls are serialized here, so sessions for the same device cannot race store
  admission. The returned disposition is suitable for `TCPSession.data_reply/2`.
  """

  use GenServer

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Protocols.Teltonika.{Codec8Extended, TCPSession}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Credentials, Store}

  @maximum_sessions 32
  @maximum_retries 3

  defmodule Session do
    @moduledoc "Opaque admission handle for one live cellular connection."

    @derive {Inspect, only: []}
    @opaque t :: %__MODULE__{reference: reference()}
    @enforce_keys [:reference]
    defstruct [:reference]
  end

  @type disposition :: :accepted | :duplicate | :rejected | :unknown
  @type receipt :: %{
          disposition: disposition(),
          operation_id: String.t(),
          record_count: pos_integer()
        }

  @doc "Starts an explicitly configured serialized cellular admission owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, state, server_options} <- options(options),
         do: GenServer.start_link(__MODULE__, state, server_options)
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc false
  @spec validate_options(term()) :: :ok | {:error, :invalid_configuration}
  def validate_options(options) do
    case options(options) do
      {:ok, _state, _server_options} -> :ok
      {:error, :invalid_configuration} = error -> error
    end
  end

  @doc "Admits one syntactically valid IMEI against private keyed configuration."
  @spec login(GenServer.server(), term(), timeout()) ::
          {:ok, Session.t()} | {:error, :unauthorized | :busy | :invalid_request}
  def login(server, imei, timeout \\ 5000), do: GenServer.call(server, {:login, imei}, timeout)

  @doc "Releases a live session handle; repeated release is harmless."
  @spec close(GenServer.server(), term()) :: :ok
  def close(server, session), do: GenServer.cast(server, {:close, session})

  @doc "Atomically admits one revalidated packet and reports its durable disposition."
  @spec submit(GenServer.server(), term(), term(), timeout()) ::
          {:ok, receipt()} | {:error, :unauthorized | :invalid_request}
  def submit(server, session, packet, timeout \\ 5000),
    do: GenServer.call(server, {:submit, session, packet}, timeout)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:login, imei}, _from, state) do
    with true <- map_size(state.sessions) < state.maximum_sessions,
         {:ok, digest} <- TCPSession.identity_digest(imei, state.identity_key),
         {:ok, device} <- device(state.devices, digest) do
      reference = make_ref()
      session = %Session{reference: reference}
      {:reply, {:ok, session}, put_in(state.sessions[reference], device.identity_digest)}
    else
      false -> {:reply, {:error, :busy}, state}
      {:error, %Wotex.Tracker.Error{}} -> {:reply, {:error, :invalid_request}, state}
      {:error, :unauthorized} -> {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call({:submit, %Session{reference: reference}, packet}, _from, state) do
    with {:ok, digest} <- Map.fetch(state.sessions, reference),
         {:ok, device} <- device(state.devices, digest),
         {:ok, packet} <- packet(packet) do
      receipt = admit(state, device, packet)
      {:reply, {:ok, receipt}, state}
    else
      :error -> {:reply, {:error, :unauthorized}, state}
      {:error, :unauthorized} -> {:reply, {:error, :unauthorized}, state}
      {:error, _} -> {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:submit, _, _}, _from, state),
    do: {:reply, {:error, :invalid_request}, state}

  @impl true
  def handle_cast({:close, %Session{reference: reference}}, state),
    do: {:noreply, update_in(state.sessions, &Map.delete(&1, reference))}

  def handle_cast({:close, _}, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp options(options) do
    allowed = [
      :service,
      :identity_key,
      :devices,
      :clock,
      :maximum_sessions,
      :maximum_retries,
      :name
    ]

    if Keyword.keyword?(options) and
         length(options) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      state = %{
        service: Keyword.get(options, :service),
        identity_key: Keyword.get(options, :identity_key),
        devices: Keyword.get(options, :devices),
        clock: Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end),
        maximum_sessions: Keyword.get(options, :maximum_sessions, @maximum_sessions),
        maximum_retries: Keyword.get(options, :maximum_retries, @maximum_retries),
        sessions: %{}
      }

      if state?(state),
        do: {:ok, state, Keyword.take(options, [:name])},
        else: {:error, :invalid_configuration}
    else
      {:error, :invalid_configuration}
    end
  end

  defp state?(state) do
    match?(%Service{}, state.service) and is_binary(state.identity_key) and
      byte_size(state.identity_key) == 32 and is_function(state.clock, 0) and
      is_integer(state.maximum_sessions) and state.maximum_sessions in 1..@maximum_sessions and
      is_integer(state.maximum_retries) and state.maximum_retries in 0..@maximum_retries and
      devices?(state.devices)
  end

  defp devices?(devices) when is_list(devices) and devices != [] and length(devices) <= 32 do
    Enum.all?(devices, &device?/1) and
      devices |> Enum.map(& &1.identity_digest) |> Enum.uniq() |> length() == length(devices) and
      devices |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(devices)
  end

  defp devices?(_), do: false

  defp device?(%{identity_digest: digest, token: token, scope: scope, id: id} = device)
       when map_size(device) == 4,
       do:
         digest?(digest) and match?({:ok, _}, Credentials.token_digest(token)) and
           Codec.id?(scope) and Codec.id?(id)

  defp device?(_), do: false

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: match?({:ok, _}, Base.decode16(digest, case: :lower))

  defp digest?(_), do: false

  defp device(devices, digest) do
    case Enum.find(devices, &equal?(&1.identity_digest, digest)) do
      nil -> {:error, :unauthorized}
      device -> {:ok, device}
    end
  end

  defp equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp equal?(_, _), do: false

  defp packet(%{frame: frame} = claimed) when is_binary(frame) do
    case Codec8Extended.decode_frame(frame) do
      {:ok, decoded} when decoded === claimed -> {:ok, decoded}
      _ -> {:error, :invalid_packet}
    end
  end

  defp packet(_), do: {:error, :invalid_packet}

  defp admit(state, device, packet) do
    operation = operation_id(device.identity_digest, packet.frame)

    result =
      with {:ok, now} <- current_time(state.clock),
           true <- Codec.time?(now),
           {:ok, access} <-
             Service.authorize(
               state.service,
               device.token,
               device.scope,
               "ingest",
               "cellular_submit",
               now
             ) do
        case Store.operation(
               state.service.store,
               device.scope,
               access.principal,
               operation,
               now
             ) do
          {:ok, _} -> :duplicate
          {:error, :not_found} -> submit_new(state, device, packet, operation, now)
          {:error, _} -> :unknown
        end
      else
        _ -> :rejected
      end

    %{disposition: result, operation_id: operation, record_count: packet.record_count}
  end

  defp current_time(clock) do
    {:ok, clock.()}
  rescue
    _ -> {:error, :invalid_clock}
  catch
    _, _ -> {:error, :invalid_clock}
  end

  defp submit_new(state, device, packet, operation, now) do
    with {:ok, observation} <- observation(device, packet, now),
         {:ok, document} <- Observation.to_map(observation) do
      retry_submit(state, device, document, operation, now, state.maximum_retries)
    else
      _ -> :rejected
    end
  end

  defp retry_submit(state, device, document, operation, now, retries) do
    case Store.snapshot(state.service.store, %{
           scope: device.scope,
           kind: "observations",
           generation: nil,
           after: "",
           limit: 1
         }) do
      {:ok, page} ->
        request = %{"observation" => document, "expected_generation" => page["generation"]}

        case Service.submit(state.service, device.token, device.scope, operation, request, now) do
          {:ok, %{"outcome" => "committed", "disposition" => "accepted"}} ->
            :accepted

          {:ok, %{"outcome" => "committed"}} ->
            :duplicate

          {:ok, %{"outcome" => "unknown"}} ->
            :unknown

          {:error, %{"code" => "conflict"}} when retries > 0 ->
            retry_submit(state, device, document, operation, now, retries - 1)

          {:error, %{"outcome" => "not_committed"}} ->
            :rejected

          _ ->
            :unknown
        end

      _ ->
        :unknown
    end
  end

  defp observation(device, packet, now) do
    digest = frame_digest(device.identity_digest, packet.frame)

    Observation.new(%{
      id: "teltonika-frame-" <> digest,
      observed_at: now,
      ingress: "cellular",
      source: %{"adapter" => "teltonika-tcp", "device" => device.id},
      addressing: %{"identity_digest" => device.identity_digest},
      payload: {:bytes, packet.frame},
      radio: %{},
      transport: %{
        "codec" => packet.codec,
        "record_count" => packet.record_count,
        "acknowledgement" => "durable-record-count"
      },
      provenance: %{
        "protocol" => "teltonika-codec8-extended",
        "revision" => "1.0.0",
        "identity_assurance" => "configured-routing-identifier"
      }
    })
  end

  defp operation_id(identity_digest, frame) do
    <<a::48, version::16, variant::16, b::48, _::binary>> =
      :crypto.hash(:sha256, ["wtr.teltonika-operation.v1:", identity_digest, frame])

    bytes =
      <<a::48, Bitwise.bor(Bitwise.band(version, 0x0FFF), 0x4000)::16,
        Bitwise.bor(Bitwise.band(variant, 0x3FFF), 0x8000)::16, b::48>>

    <<first::binary-size(8), second::binary-size(4), third::binary-size(4),
      fourth::binary-size(4), fifth::binary>> = Base.encode16(bytes, case: :lower)

    Enum.join([first, second, third, fourth, fifth], "-")
  end

  defp frame_digest(identity_digest, frame),
    do:
      :crypto.hash(:sha256, ["wtr.teltonika-frame.v1:", identity_digest, frame])
      |> Base.encode16(case: :lower)
end
