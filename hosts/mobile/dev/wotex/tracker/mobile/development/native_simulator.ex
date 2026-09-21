defmodule Wotex.Tracker.Mobile.Development.NativeSimulator do
  @moduledoc """
  Deterministic dev/test peer for the mobile host's closed native capabilities.

  The simulator implements the same narrow module callbacks used by the Mob
  screen and the two app-owned NIF wrappers. It stores only the two secure-store
  slots, emits a fixed BLE peripheral, grants notification permission and
  records redacted effect counters. Its EYE Sensor peer can deterministically
  expose success, permission denial, timeout, disconnect and malformed-event
  paths. It is not compiled into production builds.
  """

  use GenServer

  @peripheral "123e4567-e89b-12d3-a456-426614174000"
  @eye_service "e61c0000-7df2-4d4e-8e6d-c611745b92e9"
  @eye_password "e61c0008-7df2-4d4e-8e6d-c611745b92e9"
  @eye_command "e61c0007-7df2-4d4e-8e6d-c611745b92e9"
  @eye_sensor_mask "e61c0021-7df2-4d4e-8e6d-c611745b92e9"
  @ble_scenarios ~w(success denied timeout disconnect malformed)a
  @push_token String.duplicate("01", 32)
  @rotated_push_token String.duplicate("02", 32)
  @secure_keys ~w(credential installation_id)
  @event_references ~r/\A[^\x00]{1,256}\z/u
  @keys [:name]

  @doc false
  @spec simulator?() :: true
  def simulator?, do: true

  @doc "Starts the single local native capability peer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ [])

  def start_link(options) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)

    if Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
         Keyword.keys(options) -- @keys == [] and is_atom(name) do
      GenServer.start_link(__MODULE__, :ok, name: name)
    else
      {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Returns redacted simulator state and effect counts."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{mode: :development, state: :unavailable}
  end

  @doc "Emits one admitted app, network or notification event to subscribers."
  @spec emit(term(), GenServer.server()) :: :ok | {:error, :invalid_event}
  def emit(event, server \\ __MODULE__) do
    with {:ok, message} <- native_event(event) do
      GenServer.call(server, {:emit, message})
    end
  catch
    :exit, _ -> {:error, :invalid_event}
  end

  @doc "Selects one finite BLE failure scenario for local development."
  @spec set_ble_scenario(atom(), GenServer.server()) :: :ok | {:error, :invalid_scenario}
  def set_ble_scenario(scenario, server \\ __MODULE__)

  def set_ble_scenario(scenario, server) when scenario in @ble_scenarios do
    GenServer.call(server, {:ble_scenario, scenario})
  catch
    :exit, _ -> {:error, :invalid_scenario}
  end

  def set_ble_scenario(_, _), do: {:error, :invalid_scenario}

  @doc false
  def fetch(key) when key in @secure_keys, do: GenServer.call(__MODULE__, {:fetch, key})
  def fetch(_), do: {:error, :unavailable}

  @doc false
  def put(key, value) when key in @secure_keys and is_binary(value),
    do: GenServer.call(__MODULE__, {:put, key, value})

  def put(_, _), do: {:error, :unavailable}

  @doc false
  def delete(key) when key in @secure_keys, do: GenServer.call(__MODULE__, {:delete, key})
  def delete(_), do: {:error, :unavailable}

  @doc false
  def subscribe([:app, :network]) do
    GenServer.call(__MODULE__, {:subscribe, self()})
  end

  def subscribe(_), do: {:error, :unavailable}

  @doc false
  def open_url(url) when is_binary(url) do
    GenServer.cast(__MODULE__, {:effect, :external_url, %{url: url}})
    :ok
  end

  def open_url(_), do: {:error, :unavailable}

  @doc false
  def request(%Mob.Socket{} = socket, :notifications) do
    record(:notification_permission, %{})
    send(self(), {:permission, :notifications, :granted})
    Mob.Socket.assign(socket, :simulated_notification_permission, :granted)
  end

  def request(socket, _), do: socket

  @doc false
  def register_push(%Mob.Socket{} = socket) do
    record(:push_registration, %{})
    send(self(), {:push_token, :ios, @push_token})
    Mob.Socket.assign(socket, :simulated_push_registration, true)
  end

  def register_push(socket), do: socket

  @doc false
  def text(%Mob.Socket{} = socket, content) when is_binary(content) do
    record(:share, %{bytes: byte_size(content), digest: digest(content)})
    Mob.Socket.assign(socket, :simulated_share, true)
  end

  def text(socket, _), do: socket

  @doc false
  def eval_js(%Mob.Socket{} = socket, script) when is_binary(script) do
    record(:webview_script, %{bytes: byte_size(script), digest: digest(script)})
    Mob.Socket.assign(socket, :simulated_webview_effect, true)
  end

  def eval_js(socket, _), do: socket

  @doc false
  def scan(request, services, timeout) do
    record(:ble_scan, %{request: request, services: services, timeout_ms: timeout})

    case ble_scenario() do
      :denied ->
        {:error, :unauthorized}

      :timeout ->
        :ok

      :malformed ->
        send(
          self(),
          {:ble_central, request, :scan_result, {@peripheral, "EYE malformed", -42, ["invalid"]}}
        )

        :ok

      _ ->
        send(
          self(),
          {:ble_central, request, :scan_result, {@peripheral, "EYE_1234567", -42, [@eye_service]}}
        )

        send(self(), {:ble_central, request, :scan_complete, nil})
        :ok
    end
  end

  @doc false
  def stop_scan(request) do
    record(:ble_stop_scan, %{request: request})
    send(self(), {:ble_central, request, :scan_stopped, nil})
    :ok
  end

  @doc false
  def connect(request, peripheral) do
    record(:ble_connect, %{request: request, peripheral: peripheral})
    send(self(), {:ble_central, request, :connected, peripheral})

    if ble_scenario() == :disconnect,
      do: send(self(), {:ble_central, request, :disconnected, peripheral})

    :ok
  end

  @doc false
  def disconnect(request, peripheral) do
    record(:ble_disconnect, %{request: request, peripheral: peripheral})
    send(self(), {:ble_central, request, :disconnected, peripheral})
    :ok
  end

  @doc false
  def discover(request, peripheral, services) do
    record(:ble_discover, %{request: request, peripheral: peripheral, services: services})
    send(self(), {:ble_central, request, :services, {peripheral, [@eye_service]}})

    send(
      self(),
      {:ble_central, request, :characteristics,
       {peripheral, @eye_service,
        [
          {@eye_command, [:write]},
          {@eye_password, [:write]},
          {@eye_sensor_mask, [:read, :write]}
        ]}}
    )

    send(self(), {:ble_central, request, :discovery_complete, nil})
    :ok
  end

  @doc false
  def read(request, peripheral, service, characteristic) do
    record(:ble_read, %{
      request: request,
      peripheral: peripheral,
      service: service,
      characteristic: characteristic
    })

    send(self(), {:ble_central, request, :value, {peripheral, service, characteristic, <<15>>}})
    :ok
  end

  @doc false
  def write(request, peripheral, service, characteristic, value) do
    record(:ble_write, %{
      request: request,
      peripheral: peripheral,
      service: service,
      characteristic: characteristic,
      value_bytes: byte_size(value),
      value_digest: digest(value)
    })

    send(self(), {:ble_central, request, :written, {peripheral, service, characteristic, value}})
    :ok
  end

  @impl true
  def init(:ok) do
    {:ok, %{secure: %{}, subscribers: %{}, effects: %{}, last: %{}, ble_scenario: :success}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      mode: :development,
      secure_slots: state.secure |> Map.keys() |> Enum.sort(),
      subscriber_count: map_size(state.subscribers),
      effects: state.effects,
      last: state.last,
      ble_scenario: state.ble_scenario
    }

    {:reply, status, state}
  end

  def handle_call({:fetch, key}, _from, state) do
    reply =
      case Map.fetch(state.secure, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | secure: Map.put(state.secure, key, value)}}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | secure: Map.delete(state.secure, key)}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state = subscribe_pid(state, pid)
    {:reply, :ok, effect(state, :subscription, %{categories: [:app, :network]})}
  end

  def handle_call({:emit, message}, _from, state) do
    Enum.each(Map.keys(state.subscribers), &send(&1, message))
    {:reply, :ok, effect(state, :emitted_event, %{kind: event_kind(message)})}
  end

  def handle_call(:ble_scenario, _from, state), do: {:reply, state.ble_scenario, state}

  def handle_call({:ble_scenario, scenario}, _from, state),
    do: {:reply, :ok, %{state | ble_scenario: scenario}}

  @impl true
  def handle_cast({:effect, kind, metadata}, state),
    do: {:noreply, effect(state, kind, metadata)}

  @impl true
  def handle_info({:DOWN, reference, :process, pid, _reason}, state) do
    subscribers =
      case state.subscribers do
        %{^pid => ^reference} -> Map.delete(state.subscribers, pid)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp subscribe_pid(%{subscribers: subscribers} = state, pid) do
    if Map.has_key?(subscribers, pid) do
      state
    else
      %{state | subscribers: Map.put(subscribers, pid, Process.monitor(pid))}
    end
  end

  defp record(kind, metadata), do: GenServer.cast(__MODULE__, {:effect, kind, metadata})

  defp ble_scenario do
    GenServer.call(__MODULE__, :ble_scenario)
  catch
    :exit, _ -> :timeout
  end

  defp effect(state, kind, metadata) do
    %{
      state
      | effects: Map.update(state.effects, kind, 1, &(&1 + 1)),
        last: Map.put(state.last, kind, metadata)
    }
  end

  defp native_event(:background), do: {:ok, {:mob_device, :did_enter_background}}
  defp native_event(:active), do: {:ok, {:mob_device, :did_become_active}}

  defp native_event(:offline),
    do: {:ok, {:mob_device, :connectivity_changed, %{online: false}}}

  defp native_event(:online),
    do: {:ok, {:mob_device, :connectivity_changed, %{online: true}}}

  defp native_event({:notification, reference})
       when is_binary(reference) and byte_size(reference) in 1..256 do
    if String.valid?(reference) and Regex.match?(@event_references, reference) do
      {:ok,
       {:notification,
        %{
          data: %{
            schema: "wtr.notification-reference.v1",
            event_ref: reference
          }
        }}}
    else
      {:error, :invalid_event}
    end
  end

  defp native_event({:push_token, :rotated}),
    do: {:ok, {:push_token, :ios, @rotated_push_token}}

  defp native_event({:push_token, :invalid}),
    do: {:ok, {:push_token, :ios, "not-a-provider-token"}}

  defp native_event(_), do: {:error, :invalid_event}

  defp event_kind({:mob_device, event}), do: event
  defp event_kind({:mob_device, event, _}), do: event
  defp event_kind({:notification, _}), do: :notification
  defp event_kind({:push_token, :ios, _}), do: :push_token

  defp digest(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
