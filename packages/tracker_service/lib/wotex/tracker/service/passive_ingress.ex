defmodule Wotex.Tracker.Service.PassiveIngress do
  @moduledoc """
  Serialized admission of configured passive BLE captures into Tracker.

  The ingress owns the bearer credential and retries only generation conflicts.
  A content-identical capture has one deterministic operation identity, so an
  unknown reply can be reconciled without creating another observation. No BLE
  address is promoted to canonical device identity.
  """

  use GenServer

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Credentials, PassiveAdvertisement, Store}

  @maximum_retries 3

  @type disposition :: :accepted | :duplicate | :rejected | :unknown
  @type receipt :: %{disposition: disposition(), operation_id: String.t()}

  @doc "Starts one explicitly configured passive-advertisement admission owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, state, server_options} <- options(options),
         do: GenServer.start_link(__MODULE__, state, server_options)
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Submits one adapter capture and returns its durable disposition."
  @spec submit(GenServer.server(), term(), timeout()) ::
          {:ok, receipt()} | {:error, :invalid_advertisement}
  def submit(server, advertisement, timeout \\ 5_000),
    do: GenServer.call(server, {:submit, advertisement}, timeout)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:submit, advertisement}, _from, state) do
    case PassiveAdvertisement.validate(advertisement) do
      {:ok, advertisement} -> {:reply, {:ok, admit(state, advertisement)}, state}
      {:error, :invalid_advertisement} = error -> {:reply, error, state}
    end
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  defp options(options) do
    allowed = [:service, :token, :scope, :adapter, :maximum_retries, :name]
    required = [:service, :token, :scope, :adapter]

    if Keyword.keyword?(options) and
         length(options) == length(Enum.uniq(Keyword.keys(options))) and
         Enum.all?(Keyword.keys(options), &(&1 in allowed)) and
         Enum.all?(required, &Keyword.has_key?(options, &1)) do
      state = %{
        service: Keyword.fetch!(options, :service),
        token: Keyword.fetch!(options, :token),
        scope: Keyword.fetch!(options, :scope),
        adapter: Keyword.fetch!(options, :adapter),
        maximum_retries: Keyword.get(options, :maximum_retries, @maximum_retries)
      }

      if state?(state),
        do: {:ok, state, Keyword.take(options, [:name])},
        else: {:error, :invalid_configuration}
    else
      {:error, :invalid_configuration}
    end
  end

  defp state?(state) do
    service?(state.service) and match?({:ok, _}, Credentials.token_digest(state.token)) and
      Codec.id?(state.scope) and Codec.id?(state.adapter) and
      is_integer(state.maximum_retries) and state.maximum_retries in 0..@maximum_retries
  end

  defp service?(%Service{}), do: true
  defp service?(provider), do: is_function(provider, 0)

  defp admit(state, advertisement) do
    operation = operation_id(state.adapter, advertisement)

    disposition =
      with {:ok, service} <- service(state.service),
           {:ok, access} <-
             Service.authorize(
               service,
               state.token,
               state.scope,
               "ingest",
               "passive_ble_submit",
               advertisement.observed_at
             ) do
        case Store.operation(
               service.store,
               state.scope,
               access.principal,
               operation,
               advertisement.observed_at
             ) do
          {:ok, _} -> :duplicate
          {:error, :not_found} -> submit_new(state, service, advertisement, operation)
          {:error, _} -> :unknown
        end
      else
        _ -> :rejected
      end

    %{disposition: disposition, operation_id: operation}
  end

  defp service(%Service{} = service), do: {:ok, service}

  defp service(provider) when is_function(provider, 0) do
    case provider.() do
      {:ok, %Service{} = service} -> {:ok, service}
      _ -> {:error, :service_unavailable}
    end
  rescue
    _ -> {:error, :service_unavailable}
  catch
    _, _ -> {:error, :service_unavailable}
  end

  defp submit_new(state, service, advertisement, operation) do
    with {:ok, observation} <- observation(state.adapter, advertisement),
         {:ok, document} <- Observation.to_map(observation) do
      retry_submit(
        state,
        service,
        advertisement,
        document,
        operation,
        state.maximum_retries
      )
    else
      _ -> :rejected
    end
  end

  defp retry_submit(state, service, advertisement, document, operation, retries) do
    case Store.snapshot(service.store, %{
           scope: state.scope,
           kind: "observations",
           generation: nil,
           after: "",
           limit: 1
         }) do
      {:ok, page} ->
        request = %{"observation" => document, "expected_generation" => page["generation"]}

        case Service.submit(
               service,
               state.token,
               state.scope,
               operation,
               request,
               advertisement.observed_at
             ) do
          {:ok, %{"outcome" => "committed", "disposition" => "accepted"}} ->
            :accepted

          {:ok, %{"outcome" => "committed"}} ->
            :duplicate

          {:ok, %{"outcome" => "unknown"}} ->
            :unknown

          {:error, %{"code" => "conflict"}} when retries > 0 ->
            retry_submit(state, service, advertisement, document, operation, retries - 1)

          {:error, %{"outcome" => "not_committed"}} ->
            :rejected

          _ ->
            :unknown
        end

      _ ->
        :unknown
    end
  end

  defp observation(adapter, advertisement) do
    Observation.new(%{
      id: advertisement.id,
      observed_at: advertisement.observed_at,
      ingress: "ble",
      source: %{"adapter" => adapter, "receiver" => advertisement.receiver},
      addressing: %{
        "address" => advertisement.address,
        "address_type" => Atom.to_string(advertisement.address_type)
      },
      payload: {:bytes, advertisement.payload},
      radio: %{"rssi" => advertisement.rssi, "unit" => "dBm"},
      transport: %{"manufacturer_id" => advertisement.manufacturer_id},
      provenance: advertisement.provenance
    })
  end

  defp operation_id(adapter, advertisement) do
    document =
      advertisement
      |> Map.from_struct()
      |> Map.new(fn
        {:payload, value} -> {"payload", Base.encode64(value)}
        {:address_type, value} -> {"address_type", Atom.to_string(value)}
        {key, value} -> {Atom.to_string(key), value}
      end)

    <<a::48, version::16, variant::16, b::48, _::binary>> =
      :crypto.hash(:sha256, ["wtr.passive-ble-operation.v1:", adapter, Codec.encode!(document)])

    bytes =
      <<a::48, Bitwise.bor(Bitwise.band(version, 0x0FFF), 0x4000)::16,
        Bitwise.bor(Bitwise.band(variant, 0x3FFF), 0x8000)::16, b::48>>

    <<first::binary-size(8), second::binary-size(4), third::binary-size(4),
      fourth::binary-size(4), fifth::binary>> = Base.encode16(bytes, case: :lower)

    Enum.join([first, second, third, fourth, fifth], "-")
  end
end
