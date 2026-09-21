defmodule Wotex.Tracker.Mobile.Development.RemoteService do
  @moduledoc """
  Finite Responses-free service peer for the local mobile simulator.

  It admits one documented development credential, returns an empty authorized
  asset projection and retains at most one notification endpoint for the local
  APNs peer. No bearer token or provider token is retained in process status.
  """

  use GenServer

  @behaviour Wotex.Tracker.UI.RemoteTransport

  @origin %{scheme: :https, host: "mobile-simulator.invalid", port: 443}
  @token "development-token"
  @scope "workshop"
  @prefix "/api/v1/scopes/workshop/"
  @keys ~w(name apns)a

  @doc "Returns the fixed credential accepted only by the development peer."
  @spec credential() :: %{scope: String.t(), token: String.t()}
  def credential, do: %{scope: @scope, token: @token}

  @doc "Starts the bounded local service peer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ [])

  def start_link(options) when is_list(options) do
    name = Keyword.get(options, :name, __MODULE__)
    apns = Keyword.get(options, :apns)

    if Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
         Keyword.keys(options) -- @keys == [] and is_atom(name) and optional_apns?(apns) do
      GenServer.start_link(__MODULE__, apns, name: name)
    else
      {:error, :invalid_configuration}
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc "Returns only bounded, non-secret peer state."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{mode: :development, state: :unavailable}
  end

  @impl true
  def request(server, authority, request) do
    GenServer.call(server, {:request, authority, request})
  catch
    :exit, _ -> {:error, :offline}
  end

  @doc "Dispatches one opaque notification reference through the local APNs peer."
  @spec dispatch_notification(String.t(), GenServer.server()) ::
          {:accepted | :invalid_token | :rejected, String.t()}
          | {:retry, :rate_limited | :offline}
          | {:error, atom()}
  def dispatch_notification(event_reference, server \\ __MODULE__) do
    GenServer.call(server, {:dispatch_notification, event_reference})
  catch
    :exit, _ -> {:retry, :offline}
  end

  @impl true
  def init(apns), do: {:ok, %{requests: 0, generation: 0, endpoints: %{}, apns: apns}}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       mode: :development,
       request_count: state.requests,
       endpoint_count: map_size(state.endpoints),
       generation: state.generation
     }, state}
  end

  def handle_call({:dispatch_notification, event_reference}, _from, state) do
    {reply, state} = do_dispatch_notification(state, event_reference)
    {:reply, reply, state}
  end

  def handle_call({:request, authority, request}, _from, state) do
    state = %{state | requests: state.requests + 1}
    {reply, state} = respond(authority, request, state)
    {:reply, reply, state}
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp respond(@origin, request, state) when is_map(request) do
    cond do
      not valid_request?(request) ->
        {error_response(400, "invalid_request"), state}

      not authorized?(request.headers) ->
        {error_response(401, "unauthorized"), state}

      true ->
        case resource(request.path) do
          {:ok, resource} -> route(request.method, resource, request.body, state)
          {:error, _} -> {error_response(404, "not_found"), state}
        end
    end
  end

  defp respond(_, _, state), do: {error_response(400, "invalid_request"), state}

  defp route("GET", "access", "", state) do
    data = %{
      "schema" => "wtr.access.v1",
      "credential_id" => "mobile-development",
      "principal" => "developer",
      "scope" => @scope,
      "permissions" => ~w(admin enroll ingest interact raw read),
      "expires_at" => 9_007_199_254_740_991
    }

    {response(data), state}
  end

  defp route("GET", "notification_endpoints", "", state) do
    data = %{
      "generation" => Integer.to_string(state.generation),
      "items" => Enum.map(Map.values(state.endpoints), &Map.delete(&1, "token"))
    }

    {response(data), state}
  end

  defp route("POST", "notification_endpoints", body, state) do
    with {:ok, %{"id" => id} = endpoint} <- mutation_request(body),
         true <- is_binary(id) and byte_size(id) in 1..256,
         true <- expected_generation?(endpoint, state.generation),
         stored = Map.take(endpoint, ~w(id provider app_id environment token)),
         true <- map_size(stored) == 5 do
      state = %{
        state
        | endpoints: %{id => stored},
          generation: state.generation + 1
      }

      {response(%{"outcome" => "committed"}), state}
    else
      _ -> {error_response(400, "invalid_request"), state}
    end
  end

  defp route("POST", "notification_endpoint_deletions", body, state) do
    with {:ok, %{"id" => id} = request} <- mutation_request(body),
         true <- is_binary(id),
         true <- expected_generation?(request, state.generation) do
      state = %{
        state
        | endpoints: Map.delete(state.endpoints, id),
          generation: state.generation + 1
      }

      {response(%{"outcome" => "committed"}), state}
    else
      _ -> {error_response(400, "invalid_request"), state}
    end
  end

  defp route("GET", _resource, "", state) do
    {response(%{"generation" => "0", "items" => [], "cursor" => nil}), state}
  end

  defp route("POST", _resource, body, state) when is_binary(body) and byte_size(body) > 0,
    do: {response(%{"outcome" => "committed"}), state}

  defp route(_, _, _, state), do: {error_response(400, "invalid_request"), state}

  defp mutation_request(body) do
    with {:ok, document} <- Jason.decode(body),
         %{"id" => _} = request <- document,
         true <- map_size(document) <= 8 do
      {:ok, request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp do_dispatch_notification(%{apns: nil} = state, _event_reference),
    do: {{:error, :provider_unavailable}, state}

  defp do_dispatch_notification(%{endpoints: endpoints} = state, event_reference)
       when map_size(endpoints) == 1 do
    [{id, endpoint}] = Map.to_list(endpoints)
    result = invoke(state.apns, :dispatch, [endpoint, event_reference])

    state =
      case result do
        {:invalid_token, _receipt} ->
          %{state | endpoints: Map.delete(endpoints, id), generation: state.generation + 1}

        _ ->
          state
      end

    {result, state}
  end

  defp do_dispatch_notification(state, _event_reference),
    do: {{:error, :no_endpoint}, state}

  defp expected_generation?(request, generation) do
    Map.get(request, "expected_generation") == Integer.to_string(generation)
  end

  defp valid_request?(request) do
    Map.keys(request) |> Enum.sort() == ~w(body headers method path timeout_ms)a |> Enum.sort() and
      request.method in ~w(GET POST) and is_binary(request.path) and
      byte_size(request.path) in 1..2_048 and is_list(request.headers) and
      length(request.headers) <= 8 and is_binary(request.body) and
      byte_size(request.body) <= 1_048_576 and request.timeout_ms in 100..30_000
  end

  defp authorized?(headers) do
    Enum.count(headers, &(&1 == {"authorization", "Bearer " <> @token})) == 1
  end

  defp resource(path) do
    case String.split(path, "?", parts: 2) do
      [@prefix <> resource | _] when byte_size(resource) in 1..1_024 -> {:ok, resource}
      _ -> {:error, :invalid_path}
    end
  end

  defp optional_apns?(nil), do: true

  defp optional_apns?({module, _context}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :dispatch, 3)

  defp optional_apns?(_), do: false

  defp invoke({module, context}, function, arguments) do
    apply(module, function, arguments ++ [context])
  rescue
    _ -> {:retry, :offline}
  catch
    _, _ -> {:retry, :offline}
  end

  defp response(data), do: encoded(200, %{"schema" => "wtr.response.v1", "data" => data})

  defp error_response(status, code),
    do: encoded(status, %{"schema" => "wtr.response.v1", "error" => %{"code" => code}})

  defp encoded(status, document),
    do: {:ok, status, [{"content-type", "application/json"}], Jason.encode!(document)}
end
