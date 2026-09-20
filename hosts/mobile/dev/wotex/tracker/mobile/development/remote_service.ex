defmodule Wotex.Tracker.Mobile.Development.RemoteService do
  @moduledoc """
  Finite Responses-free service peer for the local mobile simulator.

  It admits one documented development credential, returns an empty authorized
  asset projection and retains at most one redacted notification endpoint. No
  bearer token or provider token is retained in process status.
  """

  use GenServer

  @behaviour Wotex.Tracker.UI.RemoteTransport

  @origin %{scheme: :https, host: "mobile-simulator.invalid", port: 443}
  @token "development-token"
  @scope "workshop"
  @prefix "/api/v1/scopes/workshop/"
  @keys [:name]

  @doc "Returns the fixed credential accepted only by the development peer."
  @spec credential() :: %{scope: String.t(), token: String.t()}
  def credential, do: %{scope: @scope, token: @token}

  @doc "Starts the bounded local service peer."
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

  @impl true
  def init(:ok), do: {:ok, %{requests: 0, endpoints: %{}}}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       mode: :development,
       request_count: state.requests,
       endpoint_count: map_size(state.endpoints)
     }, state}
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
      "generation" => Integer.to_string(map_size(state.endpoints)),
      "items" => Map.values(state.endpoints)
    }

    {response(data), state}
  end

  defp route("POST", "notification_endpoints", body, state) do
    with {:ok, %{"id" => id} = endpoint} <- mutation_request(body),
         true <- is_binary(id) and byte_size(id) in 1..256 do
      stored = Map.take(endpoint, ~w(id provider app_id environment))
      state = %{state | endpoints: %{id => stored}}
      {response(%{"outcome" => "committed"}), state}
    else
      _ -> {error_response(400, "invalid_request"), state}
    end
  end

  defp route("POST", "notification_endpoint_deletions", body, state) do
    with {:ok, %{"id" => id}} <- mutation_request(body),
         true <- is_binary(id) do
      state = %{state | endpoints: Map.delete(state.endpoints, id)}
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

  defp response(data), do: encoded(200, %{"schema" => "wtr.response.v1", "data" => data})

  defp error_response(status, code),
    do: encoded(status, %{"schema" => "wtr.response.v1", "error" => %{"code" => code}})

  defp encoded(status, document),
    do: {:ok, status, [{"content-type", "application/json"}], Jason.encode!(document)}
end
