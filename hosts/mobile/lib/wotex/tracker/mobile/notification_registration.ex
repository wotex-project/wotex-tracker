defmodule Wotex.Tracker.Mobile.NotificationRegistration do
  @moduledoc """
  Registers one installation-bound APNs endpoint through the current session.

  Provider tokens are admitted and used for one authenticated remote operation.
  A token received before sign-in or during an unavailable network may remain
  only in this volatile, status-redacted process until an explicit retry signal;
  it is cleared after success and is never persisted. Registration, rotation
  and removal all use the service's generation check and recoverable operation
  boundary.
  """

  use GenServer
  import Bitwise

  @keys ~w(name sessions credentials app_id environment)a

  @doc "Starts the optional notification registration owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, state, server_options} <- configuration(options) do
      GenServer.start_link(__MODULE__, state, server_options)
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Schedules registration or rotation of one iOS provider token."
  @spec register(GenServer.server(), :ios, String.t()) :: :ok
  def register(server, :ios, token), do: cast(server, {:register, token})
  def register(_, _, _), do: :ok

  @doc "Schedules removal of this installation's endpoint after permission denial."
  @spec unregister(GenServer.server()) :: :ok
  def unregister(server), do: cast(server, :unregister)

  @doc "Retries a volatile token after sign-in or connectivity recovery."
  @spec retry(GenServer.server() | nil) :: :ok
  def retry(nil), do: :ok
  def retry(server), do: cast(server, :retry)

  @doc "Returns only the last non-secret registration outcome."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{state: :unavailable}
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:register, token}, state) do
    {:noreply, register(state, token)}
  end

  def handle_cast(:unregister, state) do
    {:noreply, %{state | pending: nil, status: unregister_endpoint(state)}}
  end

  def handle_cast(:retry, %{pending: nil} = state), do: {:noreply, state}
  def handle_cast(:retry, %{pending: token} = state), do: {:noreply, register(state, token)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, %{state: state.status}, state}

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp configuration(options) do
    name = Keyword.get(options, :name)
    sessions = Keyword.get(options, :sessions)
    credentials = Keyword.get(options, :credentials)
    app_id = Keyword.get(options, :app_id)
    environment = Keyword.get(options, :environment)

    if valid_options?(options) and
         Enum.all?([
           valid_name?(name),
           callback?(sessions, :request, 4),
           callback?(credentials, :notification_context, 1),
           valid_app_id?(app_id),
           environment in ~w(sandbox production)
         ]) do
      state = %{
        sessions: sessions,
        credentials: credentials,
        app_id: app_id,
        environment: environment,
        pending: nil,
        status: :idle
      }

      {:ok, state, if(name, do: [name: name], else: [])}
    else
      {:error, :invalid_configuration}
    end
  end

  defp register(state, token) do
    case register_endpoint(state, token) do
      :registered -> %{state | pending: nil, status: :registered}
      :unknown -> %{state | pending: token, status: :unknown}
      :unavailable -> %{state | pending: token, status: :unavailable}
      :invalid -> %{state | pending: nil, status: :unavailable}
    end
  end

  defp register_endpoint(state, token) do
    with :ok <- provider_token(token),
         {:ok, context} <- context(state),
         {:ok, generation, _items} <- endpoints(state, context.session_id),
         operation <- operation(:register, context.endpoint_id, generation, token),
         result <-
           request(state.sessions, context.session_id, :register_notification_endpoint, %{
             "operation" => operation,
             "request" => %{
               "id" => context.endpoint_id,
               "provider" => "apns",
               "app_id" => state.app_id,
               "environment" => state.environment,
               "token" => token,
               "expected_generation" => generation
             }
           }) do
      outcome(result, :registered)
    else
      {:error, :invalid_token} -> :invalid
      _ -> :unavailable
    end
  end

  defp unregister_endpoint(state) do
    with {:ok, context} <- context(state),
         {:ok, generation, items} <- endpoints(state, context.session_id),
         true <- endpoint?(items, context.endpoint_id),
         operation <- operation(:unregister, context.endpoint_id, generation, nil),
         result <-
           request(state.sessions, context.session_id, :unregister_notification_endpoint, %{
             "operation" => operation,
             "request" => %{
               "id" => context.endpoint_id,
               "expected_generation" => generation
             }
           }) do
      outcome(result, :removed)
    else
      false -> :absent
      _ -> :unavailable
    end
  end

  defp context(%{credentials: credentials}) do
    case invoke(credentials, :notification_context, []) do
      {:ok, %{session_id: session_id, endpoint_id: endpoint_id} = context}
      when map_size(context) == 2 and is_binary(session_id) and is_binary(endpoint_id) and
             byte_size(endpoint_id) in 1..256 ->
        {:ok, context}

      _ ->
        {:error, :unavailable}
    end
  end

  defp endpoints(state, session_id) do
    case request(state.sessions, session_id, :list, %{"resource" => "notification_endpoints"}) do
      {:ok, %{"generation" => generation, "items" => items} = page}
      when map_size(page) == 2 and is_list(items) and length(items) <= 8 ->
        if generation?(generation),
          do: {:ok, generation, items},
          else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  defp endpoint?(items, endpoint_id) do
    Enum.any?(items, fn
      %{"id" => ^endpoint_id} -> true
      _ -> false
    end)
  end

  defp outcome({:ok, %{"outcome" => "unknown"}}, _), do: :unknown
  defp outcome({:ok, %{"outcome" => "committed"}}, success), do: success
  defp outcome(_, _), do: :unavailable

  defp operation(kind, endpoint_id, generation, token) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {kind, endpoint_id, generation, token && :crypto.hash(:sha256, token)},
          [:deterministic]
        )
      )

    <<a::32, b::16, c::16, d::16, e::48, _::binary>> = digest
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(integer, width),
    do: integer |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")

  defp request(sessions, session_id, action, arguments),
    do: invoke(sessions, :request, [session_id, action, arguments])

  defp invoke({module, context}, function, arguments) do
    apply(module, function, [context | arguments])
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp cast(server, message) do
    GenServer.cast(server, message)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp callback?({module, _}, function, arity) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp callback?(_, _, _), do: false

  defp valid_options?(options) do
    Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
      Keyword.keys(options) -- @keys == []
  end

  defp provider_token(token) when is_binary(token) and byte_size(token) in 1..4_096 do
    if token |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E)),
      do: :ok,
      else: {:error, :invalid_token}
  end

  defp provider_token(_), do: {:error, :invalid_token}

  defp generation?(generation) when is_binary(generation) and byte_size(generation) in 1..19 do
    case Integer.parse(generation) do
      {value, ""} when value in 0..9_223_372_036_854_775_806 ->
        Integer.to_string(value) == generation

      _ ->
        false
    end
  end

  defp generation?(_), do: false

  defp valid_app_id?(app_id) when is_binary(app_id) and byte_size(app_id) in 3..256,
    do: Regex.match?(~r/\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/, app_id)

  defp valid_app_id?(_), do: false
  defp valid_name?(name), do: is_nil(name) or is_atom(name)
end
