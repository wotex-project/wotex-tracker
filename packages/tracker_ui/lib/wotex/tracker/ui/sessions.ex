defmodule Wotex.Tracker.UI.Sessions do
  @moduledoc """
  Explicit bounded, volatile browser credential custody.

  Only an opaque random identifier leaves this process through login. Bearer
  tokens never enter a cookie, LiveView session payload or socket assign. Each
  request uses the host's service adapter and current clock; authorization is
  repeated by that service. Logout rejects subsequent delivery, including an
  in-flight read. Restart requires sign-in and stores no observations.
  """

  use GenServer
  alias Wotex.Tracker.UI.Client

  @doc "Starts a session store with an explicit client; optional name belongs to the host."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         {name, options} <- Keyword.pop(options, :name),
         {:ok, config} <- configuration(options) do
      GenServer.start_link(__MODULE__, config, if(name, do: [name: name], else: []))
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Authenticates read access before retaining a credential for at most one hour."
  @spec login(GenServer.server(), String.t(), String.t()) :: Client.result()
  def login(server, token, scope) when is_binary(token) and is_binary(scope) do
    with true <- byte_size(token) <= 256 and byte_size(scope) <= 128,
         {client, clock} <- GenServer.call(server, :client),
         {:ok, _} <- call(client, token, scope, :authorize, %{}, clock.()) do
      GenServer.call(server, {:issue, token, scope})
    else
      false -> unauthorized()
      error -> error
    end
  catch
    :exit, _ -> unavailable()
  end

  def login(_, _, _), do: unauthorized()

  @doc "Executes an authorized service request without exposing credentials to the view."
  @spec request(GenServer.server(), String.t(), atom(), map()) :: Client.result()
  def request(server, id, action, arguments \\ %{}) do
    with {:ok, {client, clock, token, scope}} <- GenServer.call(server, {:fetch, id}) do
      result = call(client, token, scope, action, arguments, clock.())

      if match?({:error, %{"code" => "unauthorized"}}, result), do: logout(server, id)

      case GenServer.call(server, {:alive, id}) do
        true -> result
        false -> unauthorized()
      end
    end
  catch
    :exit, _ -> unavailable()
  end

  @doc "Destroys this browser session without revoking the underlying service credential."
  @spec logout(GenServer.server(), String.t()) :: :ok
  def logout(server, id) do
    GenServer.call(server, {:logout, id})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :expire, 30_000)
    {:ok, state}
  end

  defp configuration(options) do
    client = Keyword.get(options, :client)
    clock = Keyword.get(options, :clock, fn -> System.system_time(:millisecond) end)
    monotonic = Keyword.get(options, :monotonic, fn -> System.monotonic_time(:millisecond) end)
    capacity = Keyword.get(options, :capacity, 128)
    ttl = Keyword.get(options, :ttl, 3_600_000)

    if client?(client) and is_function(clock, 0) and
         is_function(monotonic, 0) and capacity in 1..4096 and ttl in 1..3_600_000 and
         length(options) == map_size(Map.new(options)) and
         Keyword.keys(options) -- [:client, :clock, :monotonic, :capacity, :ttl] == [] do
      {:ok,
       %{
         client: client,
         clock: clock,
         monotonic: monotonic,
         capacity: capacity,
         ttl: ttl,
         entries: %{}
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp client?({module, _}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :request, 6)

  defp client?(_), do: false

  @impl true
  def handle_call(:client, _, state), do: {:reply, {state.client, state.clock}, state}

  def handle_call({:issue, token, scope}, _, state) do
    state = prune(state)

    if map_size(state.entries) < state.capacity do
      id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      entry = %{token: token, scope: scope, expires: state.monotonic.() + state.ttl}
      {:reply, {:ok, %{"id" => id}}, put_in(state.entries[id], entry)}
    else
      {:reply, {:error, %{"code" => "capacity"}}, state}
    end
  end

  def handle_call({:fetch, id}, _, state) do
    state = prune(state)

    result =
      case state.entries[id] do
        nil -> unauthorized()
        entry -> {:ok, {state.client, state.clock, entry.token, entry.scope}}
      end

    {:reply, result, state}
  end

  def handle_call({:alive, id}, _, state) do
    state = prune(state)
    {:reply, Map.has_key?(state.entries, id), state}
  end

  def handle_call({:logout, id}, _, state),
    do: {:reply, :ok, %{state | entries: Map.delete(state.entries, id)}}

  @impl true
  def handle_info(:expire, state) do
    Process.send_after(self(), :expire, 30_000)
    {:noreply, prune(state)}
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp prune(state) do
    now = state.monotonic.()
    %{state | entries: Map.reject(state.entries, fn {_, entry} -> now >= entry.expires end)}
  end

  defp call({module, context}, token, scope, action, arguments, now),
    do: module.request(context, token, scope, action, arguments, now)

  defp unauthorized, do: {:error, %{"code" => "unauthorized"}}
  defp unavailable, do: {:error, %{"code" => "storage_unavailable"}}
end
