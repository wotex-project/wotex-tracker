defmodule Wotex.Tracker.Mobile.Development.APNsSimulator do
  @moduledoc """
  Finite APNs provider, delivery and tap peer for local mobile development.

  Provider acceptance, simulated OS delivery and a user opening the notification
  are separate operations. Accepted payloads retain only the opaque event
  reference and a digest of the provider token. Status exposes counts and finite
  states, never tokens, event references or rendered navigation scripts.
  """

  use GenServer

  @scenarios ~w(accepted invalid_token rejected rate_limited offline)a
  @launch_states ~w(cold warm background)a
  @schema "wtr.notification-reference.v1"
  @reference ~r/\A[^\x00]{1,256}\z/u
  @keys ~w(name delivery)a

  @doc "Starts one bounded provider peer with an explicit delivery target."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)
    delivery = Keyword.get(options, :delivery)

    if valid_options?(options) and is_atom(name) and callback?(delivery, :notification, 3) do
      GenServer.start_link(__MODULE__, delivery, name: name)
    else
      {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Selects the next finite provider outcome."
  @spec set_scenario(atom(), GenServer.server()) :: :ok | {:error, :invalid_scenario}
  def set_scenario(scenario, server \\ __MODULE__)

  def set_scenario(scenario, server) when scenario in @scenarios,
    do: call(server, {:scenario, scenario}, {:error, :invalid_scenario})

  def set_scenario(_, _), do: {:error, :invalid_scenario}

  @doc "Submits one minimal notification to the simulated provider."
  @spec dispatch(map(), String.t(), GenServer.server()) ::
          {:accepted | :invalid_token | :rejected, String.t()}
          | {:retry, :rate_limited | :offline}
          | {:error, :invalid_request}
  def dispatch(endpoint, event_reference, server \\ __MODULE__) do
    call(server, {:dispatch, endpoint, event_reference}, {:retry, :offline})
  end

  @doc "Separately records simulated OS delivery after provider acceptance."
  @spec deliver(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def deliver(receipt, server \\ __MODULE__),
    do: call(server, {:deliver, receipt}, {:error, :unavailable})

  @doc "Routes one delivered notification through a cold, warm or background app state."
  @spec tap(String.t(), atom(), GenServer.server()) :: :ok | {:error, atom()}
  def tap(receipt, launch_state, server \\ __MODULE__)

  def tap(receipt, launch_state, server) when launch_state in @launch_states,
    do: call(server, {:tap, receipt, launch_state}, {:error, :unavailable})

  def tap(_, _, _), do: {:error, :invalid_launch_state}

  @doc "Marks an already delivered provider receipt as an old device notification."
  @spec mark_old(String.t(), GenServer.server()) :: :ok | {:error, atom()}
  def mark_old(receipt, server \\ __MODULE__),
    do: call(server, {:mark_old, receipt}, {:error, :unavailable})

  @doc "Returns a secret-free provider/delivery/read projection."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{mode: :development, state: :unavailable}
  end

  @impl true
  def init(delivery) do
    {:ok,
     %{
       delivery: delivery,
       scenario: :accepted,
       sequence: 0,
       receipts: %{},
       provider: empty_counts(),
       launches: %{cold: 0, warm: 0, background: 0},
       duplicate_taps: 0,
       old_taps: 0
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    receipt_states = Enum.frequencies_by(Map.values(state.receipts), & &1.state)

    status = %{
      mode: :development,
      scenario: state.scenario,
      provider: state.provider,
      receipts: receipt_states,
      launches: state.launches,
      duplicate_taps: state.duplicate_taps,
      old_taps: state.old_taps
    }

    {:reply, status, state}
  end

  def handle_call({:scenario, scenario}, _from, state),
    do: {:reply, :ok, %{state | scenario: scenario}}

  def handle_call({:dispatch, endpoint, event_reference}, _from, state) do
    case request(endpoint, event_reference) do
      {:ok, request} -> provider_outcome(request, state)
      {:error, _} -> {:reply, {:error, :invalid_request}, state}
    end
  end

  def handle_call({:deliver, receipt}, _from, state) do
    case Map.fetch(state.receipts, receipt) do
      {:ok, item} ->
        item = %{item | state: :delivered}
        {:reply, :ok, put_in(state.receipts[receipt], item)}

      :error ->
        {:reply, {:error, :invalid_receipt}, state}
    end
  end

  def handle_call({:tap, receipt, launch_state}, _from, state) do
    case Map.fetch(state.receipts, receipt) do
      {:ok, %{state: :delivered} = item} -> route_tap(receipt, item, launch_state, state)
      {:ok, _} -> {:reply, {:error, :not_delivered}, state}
      :error -> {:reply, {:error, :invalid_receipt}, state}
    end
  end

  def handle_call({:mark_old, receipt}, _from, state) do
    case Map.fetch(state.receipts, receipt) do
      {:ok, %{state: :delivered} = item} ->
        {:reply, :ok, put_in(state.receipts[receipt], %{item | old: true})}

      {:ok, _} ->
        {:reply, {:error, :not_delivered}, state}

      :error ->
        {:reply, {:error, :invalid_receipt}, state}
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp provider_outcome(request, %{scenario: :accepted} = state) do
    sequence = state.sequence + 1
    receipt = receipt(sequence, request)

    item = %{
      state: :accepted,
      event_reference: request.event_reference,
      token_digest: digest(request.token),
      taps: 0,
      old: false
    }

    state =
      state
      |> Map.put(:sequence, sequence)
      |> put_in([:receipts, receipt], item)
      |> increment_provider(:accepted)

    {:reply, {:accepted, receipt}, state}
  end

  defp provider_outcome(request, %{scenario: scenario} = state)
       when scenario in [:invalid_token, :rejected] do
    sequence = state.sequence + 1
    receipt = receipt(sequence, request)
    state = state |> Map.put(:sequence, sequence) |> increment_provider(scenario)
    {:reply, {scenario, receipt}, state}
  end

  defp provider_outcome(_request, %{scenario: :rate_limited} = state) do
    {:reply, {:retry, :rate_limited}, increment_provider(state, :rate_limited)}
  end

  defp provider_outcome(_request, %{scenario: :offline} = state) do
    {:reply, {:retry, :offline}, increment_provider(state, :offline)}
  end

  defp route_tap(receipt, item, launch_state, state) do
    payload = %{
      source: :push,
      data: %{schema: @schema, event_ref: item.event_reference}
    }

    case invoke(state.delivery, :notification, [payload, launch_state]) do
      :ok ->
        duplicate_taps = state.duplicate_taps + if(item.taps > 0, do: 1, else: 0)
        old_taps = state.old_taps + if(item.old, do: 1, else: 0)
        item = %{item | taps: item.taps + 1}

        state =
          state
          |> put_in([:receipts, receipt], item)
          |> update_in([:launches, launch_state], &(&1 + 1))
          |> Map.put(:duplicate_taps, duplicate_taps)
          |> Map.put(:old_taps, old_taps)

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :delivery_unavailable}, state}
    end
  end

  defp request(
         %{
           "id" => id,
           "provider" => "apns",
           "app_id" => app_id,
           "environment" => environment,
           "token" => token
         } = endpoint,
         event_reference
       )
       when map_size(endpoint) == 5 and environment in ["sandbox", "production"] do
    valid =
      bounded_text?(id, 256) and bundle_id?(app_id) and provider_token?(token) and
        bounded_text?(event_reference, 256) and Regex.match?(@reference, event_reference)

    if valid,
      do: {:ok, %{id: id, token: token, event_reference: event_reference}},
      else: {:error, :invalid_request}
  end

  defp request(_, _), do: {:error, :invalid_request}

  defp provider_token?(token) when is_binary(token) and byte_size(token) in 2..4_096,
    do: rem(byte_size(token), 2) == 0 and token =~ ~r/\A[0-9A-Fa-f]+\z/

  defp provider_token?(_), do: false

  defp bundle_id?(value) when is_binary(value) and byte_size(value) in 3..256,
    do: value =~ ~r/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/

  defp bundle_id?(_), do: false

  defp bounded_text?(value, maximum)
       when is_binary(value) and byte_size(value) in 1..maximum//1,
       do: String.valid?(value)

  defp bounded_text?(_, _), do: false

  defp receipt(sequence, request) do
    :crypto.hash(:sha256, :erlang.term_to_binary({sequence, request}, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp increment_provider(state, outcome),
    do: update_in(state, [:provider, outcome], &(&1 + 1))

  defp empty_counts,
    do: %{accepted: 0, invalid_token: 0, rejected: 0, rate_limited: 0, offline: 0}

  defp invoke({module, context}, function, arguments) do
    apply(module, function, [context | arguments])
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp callback?({module, _}, function, arity) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp callback?(_, _, _), do: false

  defp valid_options?(options) do
    Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
      Keyword.keys(options) -- @keys == [] and Keyword.has_key?(options, :delivery)
  end

  defp call(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _ -> fallback
  end
end
