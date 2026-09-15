defmodule Wotex.Tracker.Service.HTTP.Router do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn
  require Logger
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Events, Identifier, Result, Store}
  alias Wotex.Tracker.Service.HTTP.{Capacity, Server, Stream, Wire}

  @mutations %{
    "observations" => {:submit, "ingest"},
    "enrollments" => {:enroll, "enroll"},
    "materialisations" => {:materialize, "enroll"},
    "revocations" => {:revoke, "admin"}
  }

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, {server, config}) do
    with {:ok, capacity} <- Server.child(server, :capacity),
         {:ok, lease} <- Capacity.acquire(capacity) do
      try do
        conn |> prepare(server, config) |> respond(capacity, lease, config)
      after
        Capacity.release(capacity, lease)
      end
    else
      {:error, code} ->
        {conn, error} = uncommitted({conn, Wire.error(code)})
        Wire.send_result(conn, error)
    end
  end

  defp prepare(conn, server, config) do
    result =
      with {:ok, path} <- Wire.path(conn),
           true <- Wire.acceptable?(conn, media(path)),
           {:ok, params} <- Wire.parameters(conn) do
        route(conn, path, params, server, config)
      else
        false ->
          result =
            if conn.method == "POST",
              do: Wire.mutation_error(:not_acceptable, operation_id(conn)),
              else: Wire.error(:not_acceptable)

          {conn, result}

        error ->
          {conn, error}
      end

    uncommitted(result)
  rescue
    _ -> internal_error(conn)
  catch
    :exit, _ -> internal_error(conn)
  end

  defp uncommitted({%{method: "POST"} = conn, {:error, code}}) when is_atom(code),
    do: {conn, Wire.mutation_error(code, operation_id(conn))}

  defp uncommitted({%{method: "POST"} = conn, {:error, error}}) do
    error =
      error
      |> Map.put_new("outcome", "not_committed")
      |> Map.put_new("operation_id", operation_id(conn))

    {conn, {:error, error}}
  end

  defp uncommitted(result), do: result

  defp media(["api", "v1", "scopes", _, "events", "stream"]), do: "text/event-stream"

  defp media(["api", "v1", "scopes", _, "observations", _, "raw"]),
    do: "application/vnd.wotex.tracker.observation+json"

  defp media(["api", "v1", "scopes", _, "evidence", _, "raw"]),
    do: "application/vnd.wotex.tracker.evidence+json"

  defp media(_), do: "application/json"

  defp internal_error(conn) do
    # This is the outer protocol error boundary, not data admission. Defects are
    # reported without exception/request text and never represented as rollback.
    Logger.error("tracker HTTP request failed")
    {:error, error} = Wire.error(:internal_error)

    error =
      if conn.method == "POST",
        do:
          Map.merge(error, %{
            "outcome" => "unknown",
            "operation_id" => operation_id(conn)
          }),
        else: error

    {conn, {:error, error}}
  end

  defp route(%{method: "GET"} = conn, ["health", "live"], params, _, _)
       when map_size(params) == 0,
       do: {conn, {:ok, %{"status" => "live"}}}

  defp route(%{method: "GET"} = conn, ["api", "v1", "openapi.json"], params, _, _)
       when map_size(params) == 0 do
    bytes = File.read!(Application.app_dir(:wotex_tracker_service, "priv/openapi/v1.json"))
    {:raw, conn, {:ok, bytes}, "application/json"}
  end

  defp route(conn, ["api", "v1", "scopes", scope | path], params, server, config) do
    with {:ok, service} <- Server.context(server, config),
         {:ok, token} <- token(conn) do
      # Do not retain Authorization in the connection used by response/SSE code.
      conn = %{conn | req_headers: List.keydelete(conn.req_headers, "authorization", 0)}
      scoped(conn, path, params, {service, token, scope, config.clock.()})
    else
      {:error, :invalid_configuration} -> {conn, Wire.error(:storage_unavailable)}
      error -> {conn, error}
    end
  end

  defp route(conn, ["api", version | _], _, _, _) when version != "v1",
    do: {conn, Wire.error(:unsupported_version)}

  defp route(conn, _, _, _, _), do: {conn, Wire.error(:not_found)}

  defp scoped(%{method: "POST"} = conn, [resource], params, context)
       when is_map_key(@mutations, resource) do
    {function, permission} = @mutations[resource]
    {service, token, scope, now} = context
    operation = operation_id(conn)

    with {:ok, _} <- Service.authorize(service, token, scope, permission, now),
         true <- map_size(params) == 0 and not is_nil(operation),
         {:ok, body, conn} <- Wire.body(conn) do
      {conn, apply(Service, function, [service, token, scope, operation, body, now])}
    else
      false -> {conn, Wire.mutation_error(:invalid_request, operation)}
      {:error, code, conn} -> {conn, Wire.mutation_error(code, operation)}
      {:error, code} -> {conn, Wire.mutation_error(code, operation)}
    end
  end

  defp scoped(%{method: "GET"} = conn, ["things", thing, "properties", name], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context

    {:ok, context} =
      Context.new(
        request_id: Identifier.uuid(),
        deadline: System.monotonic_time(:millisecond) + 5000
      )

    {:property, conn, Service.read_property(service, token, scope, thing, name, context, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["events", "stream"], params, {service, token, scope, now}) do
    with {:ok, access} <- Service.authorize(service, token, scope, "read", now),
         {:ok, cursor} <- stream_cursor(conn, params),
         {:ok, page} <- Events.batch(service, access, cursor, now) do
      {:stream, conn, service, access, cursor, page}
    else
      error -> {conn, normalize(error)}
    end
  end

  defp scoped(%{method: "GET"} = conn, ["events"], %{"cursor" => cursor} = params, context)
       when map_size(params) == 1 do
    {service, token, scope, now} = context
    {conn, Service.events(service, token, scope, cursor, now)}
  end

  defp scoped(%{method: "GET"} = conn, [resource, id, "raw"], params, context)
       when resource in ["observations", "evidence"] and map_size(params) == 0 do
    {service, token, scope, now} = context

    {result, type} =
      case resource do
        "observations" -> {Service.raw_observation(service, token, scope, id, now), "observation"}
        "evidence" -> {Service.raw_evidence(service, token, scope, id, now), "evidence"}
      end

    conn = put_resp_header(conn, "content-disposition", ~s(attachment; filename="#{type}.json"))
    {:raw, conn, result, "application/vnd.wotex.tracker." <> type <> "+json"}
  end

  defp scoped(%{method: "GET"} = conn, ["operations", id], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.operation(service, token, scope, id, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["health", "ready"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context

    result =
      with {:ok, _} <- Service.authorize(service, token, scope, "read", now),
           do: Store.readiness(service.store)

    {conn, normalize(result)}
  end

  defp scoped(%{method: "GET"} = conn, ["capabilities"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context

    result =
      with {:ok, _} <- Service.authorize(service, token, scope, "read", now) do
        {:ok,
         %{
           "api_version" => "v1",
           "import" => "available",
           "ble_scan" => "unsupported",
           "cellular" => "unsupported",
           "rules" => "unsupported",
           "analytics" => "unsupported",
           "runtime" => %{
             "readproperty" => "available",
             "observeproperty" => "unsupported",
             "invokeaction" => "unsupported"
           },
           "directory" => "unconfigured"
         }}
      end

    {conn, normalize(result)}
  end

  defp scoped(%{method: "GET"} = conn, [resource, id, "history"], params, context) do
    {service, token, scope, now} = context

    result =
      with {:ok, params} <- list_params(params),
           do: Service.history(service, token, scope, resource, id, params, now)

    {conn, result}
  end

  defp scoped(%{method: "GET"} = conn, [resource, id], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.get(service, token, scope, resource, id, now)}
  end

  defp scoped(%{method: "GET"} = conn, [resource], params, context) do
    {service, token, scope, now} = context

    result =
      with {:ok, params} <- list_params(params),
           do: Service.list(service, token, scope, resource, params, now)

    {conn, result}
  end

  defp scoped(conn, _, _, {service, token, scope, now}) do
    result =
      with {:ok, _} <- Service.authorize(service, token, scope, "read", now),
           do:
             Wire.error(if(conn.method == "GET", do: :invalid_request, else: :method_not_allowed))

    {conn, normalize(result)}
  end

  defp list_params(%{"limit" => limit} = params) do
    case Integer.parse(limit) do
      {integer, ""} when integer in 1..100 ->
        if Integer.to_string(integer) == limit,
          do: {:ok, %{params | "limit" => integer}},
          else: Wire.error(:invalid_request)

      _ ->
        Wire.error(:invalid_request)
    end
  end

  defp list_params(params), do: {:ok, params}

  defp stream_cursor(conn, params) do
    case {params, Wire.single_header(conn, "last-event-id")} do
      {%{"cursor" => cursor}, {:ok, nil}} when map_size(params) == 1 -> {:ok, cursor}
      {empty, {:ok, cursor}} when map_size(empty) == 0 and is_binary(cursor) -> {:ok, cursor}
      _ -> Wire.error(:invalid_cursor)
    end
  end

  defp token(conn) do
    case Wire.single_header(conn, "authorization") do
      {:ok, header} when is_binary(header) -> bearer(header)
      _ -> Wire.error(:unauthorized)
    end
  end

  defp bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] ->
        if String.downcase(scheme, :ascii) == "bearer",
          do: {:ok, token},
          else: Wire.error(:unauthorized)

      _ ->
        Wire.error(:unauthorized)
    end
  end

  defp operation_id(conn) do
    case Wire.single_header(conn, "idempotency-key") do
      {:ok, value} -> Wire.valid_operation(value)
      _ -> nil
    end
  end

  defp normalize({:error, %{"code" => _}} = error), do: error
  defp normalize(result), do: Result.normalize(result)

  defp respond({conn, result}, _, _, _), do: Wire.send_result(conn, result)

  defp respond({:property, conn, {:ok, result}}, _, _, _),
    do:
      conn
      |> put_resp_header("x-wotex-generation", result["generation"])
      |> Wire.json(200, result["value"])

  defp respond({:property, conn, error}, _, _, _), do: Wire.send_result(conn, error)
  defp respond({:raw, conn, {:ok, bytes}, type}, _, _, _), do: Wire.bytes(conn, 200, bytes, type)
  defp respond({:raw, conn, error, _}, _, _, _), do: Wire.send_result(conn, error)

  defp respond({:stream, conn, service, access, cursor, page}, capacity, lease, config) do
    case Capacity.stream(capacity, lease) do
      :ok -> Stream.run(conn, service, access, cursor, page, config)
      error -> Wire.send_result(conn, error)
    end
  end
end
