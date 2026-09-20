defmodule Wotex.Tracker.UI.Sessions do
  @moduledoc """
  Explicit bounded, volatile browser credential custody.

  Only an opaque random identifier leaves this process through login. Bearer
  tokens never enter a cookie, LiveView session payload or socket assign. Each
  request uses the host's client adapter and current clock. Online authorization
  is repeated by the service; an explicitly restored cache-only session remains
  subject to its host adapter's conservative authorization. Logout rejects
  subsequent delivery, including an in-flight read. Restart requires sign-in or
  explicit host restoration and stores no observations.
  """

  use GenServer
  alias Wotex.Tracker.UI.{Client, SessionCustodian}

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
         {:ok, context} <- call(client, token, scope, :session_context, %{}, clock.()),
         {:ok, access} <- session_context(context, scope) do
      GenServer.call(server, {:issue, token, scope, access, true})
    else
      false -> unauthorized()
      error -> error
    end
  catch
    :exit, _ -> unavailable()
  end

  def login(_, _, _), do: unauthorized()

  @doc false
  @spec restore(GenServer.server(), String.t(), String.t()) :: Client.result()
  def restore(server, token, scope) when is_binary(token) and is_binary(scope) do
    with true <- byte_size(token) <= 256 and byte_size(scope) <= 128,
         {client, clock} <- GenServer.call(server, :client),
         {:ok, context} <- call(client, token, scope, :session_context, %{}, clock.()),
         {:ok, access} <- session_context(context, scope) do
      GenServer.call(server, {:issue, token, scope, access, false})
    else
      false -> unauthorized()
      error -> error
    end
  catch
    :exit, _ -> unavailable()
  end

  def restore(_, _, _), do: unauthorized()

  @doc false
  @spec restore_cached(GenServer.server(), String.t(), String.t(), map()) :: Client.result()
  def restore_cached(server, token, scope, access)
      when is_binary(token) and is_binary(scope) and is_map(access) do
    identity = %{
      "scope" => scope,
      "can_enroll" => false,
      "can_ingest" => false,
      "can_read_raw" => false,
      "can_manage_queries" => false,
      "can_interact" => false
    }

    with true <- byte_size(token) <= 256 and byte_size(scope) <= 128,
         {:ok, access} <- session_context(%{"identity" => identity, "access" => access}, scope) do
      GenServer.call(server, {:issue, token, scope, access, false})
    else
      _ -> unauthorized()
    end
  catch
    :exit, _ -> unavailable()
  end

  def restore_cached(_, _, _, _), do: unauthorized()

  @doc false
  @spec discard(GenServer.server(), String.t()) :: :ok
  def discard(server, id) when is_binary(id) do
    GenServer.call(server, {:discard, id})
  catch
    :exit, _ -> :ok
  end

  def discard(_, _), do: :ok

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

  @doc """
  Lists the live browser sessions that hold the same credential and scope as this one.

  Each item has a non-secret `handle`, its wall-clock `started_at` and
  `expires_at`, and whether it is this session. Session identifiers and
  credentials never leave the store. An unknown or expired session gets
  `unauthorized`.
  """
  @spec list(GenServer.server(), String.t()) :: Client.result()
  def list(server, id) do
    GenServer.call(server, {:list, id})
  catch
    :exit, _ -> unavailable()
  end

  @doc """
  Ends another browser session that holds the same credential and scope.

  The service credential stays valid. A handle that does not name such a session
  returns `not_found`; the current session ends through `logout/2`.
  """
  @spec end_session(GenServer.server(), String.t(), String.t()) :: :ok | {:error, map()}
  def end_session(server, id, handle) do
    GenServer.call(server, {:end_session, id, handle})
  catch
    :exit, _ -> unavailable()
  end

  @doc "Destroys this browser session without revoking the underlying service credential."
  @spec logout(GenServer.server(), String.t()) :: :ok | {:error, map()}
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
    custodian = Keyword.get(options, :custodian)

    if client?(client) and is_function(clock, 0) and
         is_function(monotonic, 0) and capacity in 1..4096 and ttl in 1..3_600_000 and
         custodian?(custodian) and
         length(options) == map_size(Map.new(options)) and
         Keyword.keys(options) -- [:client, :clock, :monotonic, :capacity, :ttl, :custodian] ==
           [] do
      {:ok,
       %{
         client: client,
         clock: clock,
         monotonic: monotonic,
         capacity: capacity,
         ttl: ttl,
         custodian: custodian,
         entries: %{}
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp client?({module, _}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :request, 6)

  defp client?(_), do: false

  defp custodian?(nil), do: true

  defp custodian?({module, _}) when is_atom(module),
    do:
      Code.ensure_loaded?(module) and function_exported?(module, :retain, 2) and
        function_exported?(module, :release, 2)

  defp custodian?(_), do: false

  @impl true
  def handle_call(:client, _, state), do: {:reply, {state.client, state.clock}, state}

  def handle_call({:issue, token, scope, access, persist?}, _, state) do
    state = prune(state)

    if map_size(state.entries) < state.capacity do
      issue(state, token, scope, access, persist?)
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

  def handle_call({:list, id}, _, state) do
    state = prune(state)

    case state.entries[id] do
      nil ->
        {:reply, unauthorized(), state}

      current ->
        items =
          state.entries
          |> Enum.filter(fn {_, entry} -> same_credential?(entry, current) end)
          |> Enum.sort_by(fn {_, entry} -> {entry.started_at, entry.handle} end)
          |> Enum.map(fn {key, entry} ->
            %{
              "handle" => entry.handle,
              "started_at" => entry.started_at,
              "expires_at" => entry.started_at + state.ttl,
              "current" => key == id
            }
          end)

        {:reply, {:ok, %{"items" => items}}, state}
    end
  end

  def handle_call({:end_session, id, handle}, _, state) do
    state = prune(state)

    with current when not is_nil(current) <- state.entries[id],
         {key, _} <-
           Enum.find(state.entries, fn {key, entry} ->
             key != id and entry.handle == handle and same_credential?(entry, current)
           end) do
      {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
    else
      nil when is_map_key(state.entries, id) ->
        {:reply, {:error, %{"code" => "not_found"}}, state}

      _ ->
        {:reply, unauthorized(), state}
    end
  end

  def handle_call({:logout, id}, _, state) do
    case state.entries[id] do
      nil ->
        {:reply, :ok, state}

      entry ->
        if SessionCustodian.release(state.custodian, credential(entry, id)) == :ok,
          do: {:reply, :ok, %{state | entries: Map.delete(state.entries, id)}},
          else: {:reply, unavailable(), state}
    end
  end

  def handle_call({:discard, id}, _, state) do
    {:reply, :ok, %{state | entries: Map.delete(state.entries, id)}}
  end

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

  defp issue(state, token, scope, access, persist?) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    entry = %{
      token: token,
      scope: scope,
      expires: state.monotonic.() + state.ttl,
      handle: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      started_at: state.clock.(),
      access: access
    }

    if not persist? or SessionCustodian.retain(state.custodian, credential(entry, id)) == :ok do
      result = if persist?, do: %{"id" => id}, else: %{"id" => id, "access" => access}
      {:reply, {:ok, result}, put_in(state.entries[id], entry)}
    else
      {:reply, unavailable(), state}
    end
  end

  # Tokens are compared in constant time; scope must match exactly.
  defp same_credential?(entry, current),
    do:
      entry.scope == current.scope and byte_size(entry.token) == byte_size(current.token) and
        :crypto.hash_equals(entry.token, current.token)

  defp credential(entry, id) do
    %{token: entry.token, scope: entry.scope, access: entry.access, session_id: id}
  end

  defp session_context(%{"identity" => identity, "access" => access}, scope)
       when is_map(identity) and is_map(access) do
    with true <- identity["scope"] == scope,
         true <- access["scope"] == scope,
         credential when is_binary(credential) <- access["credential_id"],
         principal when is_binary(principal) <- access["principal"],
         expires when is_integer(expires) <- access["expires_at"],
         true <- byte_size(credential) in 1..256 and byte_size(principal) in 1..256,
         true <- expires in 0..9_007_199_254_740_991 do
      {:ok, access}
    else
      _ -> unavailable()
    end
  end

  defp session_context(_, _), do: unavailable()

  defp call({module, context}, token, scope, action, arguments, now),
    do: module.request(context, token, scope, action, arguments, now)

  defp unauthorized, do: {:error, %{"code" => "unauthorized"}}
  defp unavailable, do: {:error, %{"code" => "storage_unavailable"}}
end
