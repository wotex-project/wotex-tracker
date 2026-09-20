defmodule Wotex.Tracker.Service.HTTP.Router do
  @moduledoc false

  @behaviour Plug
  import Plug.Conn
  require Logger
  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    Events,
    Identifier,
    OperationalTelemetry,
    PropertyObservation,
    Result,
    Store
  }

  alias Wotex.Tracker.Service.HTTP.{Capacity, PropertyStream, Server, Stream, Wire}

  @mutations %{
    "observations" => {:submit, "ingest"},
    "enrollments" => {:enroll, "enroll"},
    "associations" => {:associate, "enroll"},
    "materialisations" => {:materialize, "enroll"},
    "revocations" => {:revoke, "admin"},
    "unenrollments" => {:unenroll, "admin"},
    "saved_queries" => {:save_query, "admin"},
    "saved_query_deletions" => {:delete_query, "admin"},
    "policies" => {:save_policy, "admin"},
    "policy_deletions" => {:delete_policy, "admin"},
    "alert_acknowledgements" => {:acknowledge_alert, "admin"},
    "arming" => {:set_arming, "admin"},
    "owner_presence" => {:admit_owner_presence, "admin"},
    "notification_endpoints" => {:register_notification_endpoint, "admin"},
    "notification_endpoint_deletions" => {:unregister_notification_endpoint, "admin"},
    "domain_data_deletions" => {:delete_domain_data, "admin"}
  }

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, {server, config}) do
    started = System.monotonic_time()

    response =
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

    OperationalTelemetry.request(request_operation(conn), response.status, started)
    response
  end

  defp request_operation(%{path_info: ["health", "live"]}), do: :health
  defp request_operation(%{path_info: ["api", "v1", "openapi.json"]}), do: :contract
  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "health", "ready"]}), do: :health

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "capabilities"]}),
    do: :capabilities

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "analytics", "query"]}),
    do: :analytics

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "analytics", "pages"]}),
    do: :analytics

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "routes", "pages"]}),
    do: :route

  defp request_operation(%{
         path_info: ["api", "v1", "scopes", _, "saved_queries", _, "execute"]
       }),
       do: :saved_query

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "events", "stream"]}),
    do: :stream

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "events"]}), do: :events

  defp request_operation(%{
         path_info: ["api", "v1", "scopes", _, "things", _, "properties", _ | _]
       }),
       do: :property

  defp request_operation(%{
         path_info: ["api", "v1", "scopes", _, "things", _, "actions", _]
       }),
       do: :action

  defp request_operation(%{path_info: ["api", "v1", "scopes", _, "actions", _]}),
    do: :action

  defp request_operation(%{method: "POST", path_info: ["api", "v1", "scopes", _ | _]}),
    do: :mutation

  defp request_operation(%{method: "GET", path_info: ["api", "v1", "scopes", _ | _]}),
    do: :resource

  defp request_operation(_), do: :unknown

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

  defp uncommitted(
         {%{
            method: "POST",
            path_info: ["api", "v1", "scopes", _scope, "analytics", operation]
          } = conn, result}
       )
       when operation in ["query", "pages"],
       do: {conn, result}

  defp uncommitted(
         {%{method: "POST", path_info: ["api", "v1", "scopes", _scope, "routes", "pages"]} =
            conn, result}
       ),
       do: {conn, result}

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

  defp media(["api", "v1", "scopes", _, "things", _, "properties", _, "observe"]),
    do: "text/event-stream"

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
      case conn do
        %{
          method: "POST",
          path_info: ["api", "v1", "scopes", _scope, "analytics", operation]
        }
        when operation in ["query", "pages"] ->
          error

        %{method: "POST", path_info: ["api", "v1", "scopes", _scope, "routes", "pages"]} ->
          error

        %{method: "POST"} ->
          Map.merge(error, %{
            "outcome" => "unknown",
            "operation_id" => operation_id(conn)
          })

        _ ->
          error
      end

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

  defp scoped(
         %{method: "POST"} = conn,
         ["analytics", "query"],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0 do
    with {:ok, _} <- Service.authorize(service, token, scope, "read", now),
         {:ok, body, conn} <- Wire.body(conn) do
      {conn, Service.analytics(service, token, scope, body, now)}
    else
      {:error, code, conn} -> {conn, Wire.error(code)}
      error -> {conn, normalize(error)}
    end
  end

  defp scoped(
         %{method: "POST"} = conn,
         ["routes", "pages"],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0 do
    with {:ok, _} <- Service.authorize(service, token, scope, "read", now),
         {:ok, body, conn} <- Wire.body(conn) do
      {conn, Service.route_history(service, token, scope, body, now)}
    else
      {:error, code, conn} -> {conn, Wire.error(code)}
      error -> {conn, normalize(error)}
    end
  end

  defp scoped(
         %{method: "POST"} = conn,
         ["analytics", "pages"],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0 do
    with {:ok, _} <- Service.authorize(service, token, scope, "read", now),
         {:ok, body, conn} <- Wire.body(conn) do
      {conn, Service.analytics_page(service, token, scope, body, now)}
    else
      {:error, code, conn} -> {conn, Wire.error(code)}
      error -> {conn, normalize(error)}
    end
  end

  defp scoped(
         %{method: "GET"} = conn,
         ["saved_queries", id, "execute"],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0,
       do: {conn, Service.execute_saved_query(service, token, scope, id, now)}

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

  defp scoped(
         %{method: "POST"} = conn,
         ["things", thing, "actions", name],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0 do
    operation = operation_id(conn)

    with {:ok, _} <- Service.authorize(service, token, scope, "interact", now),
         true <- not is_nil(operation),
         {:ok, body, conn} <- Wire.body(conn) do
      {conn, Service.invoke_action(service, token, scope, operation, thing, name, body, now)}
    else
      false -> {conn, Wire.mutation_error(:invalid_request, operation)}
      {:error, code, conn} -> {conn, Wire.mutation_error(code, operation)}
      {:error, code} -> {conn, Wire.mutation_error(code, operation)}
    end
  end

  defp scoped(%{method: "GET"} = conn, ["things", thing, "policies"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.thing_policies(service, token, scope, thing, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["things", thing, "rules"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.thing_rules(service, token, scope, thing, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["things", thing, "alerts"], params, context) do
    {service, token, scope, now} = context

    result =
      with {:ok, params} <- list_params(params),
           do: Service.thing_alerts(service, token, scope, thing, params, now)

    {conn, result}
  end

  defp scoped(%{method: "GET"} = conn, ["things", thing, "trips"], params, context) do
    {service, token, scope, now} = context

    result =
      with {:ok, params} <- trip_params(params),
           do: Service.thing_trips(service, token, scope, thing, params, now)

    {conn, result}
  end

  defp scoped(
         %{method: "GET"} = conn,
         ["things", thing, "trips", trip],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0,
       do: {conn, Service.trip_summary(service, token, scope, thing, trip, now)}

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

  defp scoped(
         %{method: "GET"} = conn,
         ["things", thing, "properties", name, "observe"],
         params,
         {service, token, scope, now}
       ) do
    with {:ok, access} <- Service.authorize(service, token, scope, "read", now),
         {:ok, cursor} <- property_cursor(conn, params),
         {:ok, page} <- PropertyObservation.open(service, access, thing, name, cursor, now) do
      {:property_stream, conn, service, access, page}
    else
      error -> {conn, normalize(error)}
    end
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

  defp scoped(%{method: "GET"} = conn, ["operations"], params, context) do
    {service, token, scope, now} = context

    result =
      with {:ok, params} <- list_params(params),
           do: Service.operations(service, token, scope, params, now)

    {conn, result}
  end

  defp scoped(%{method: "GET"} = conn, ["operations", id], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.operation(service, token, scope, id, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["actions", id], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.action_status(service, token, scope, id, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["health", "ready"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context

    result =
      with {:ok, _} <- Service.authorize(service, token, scope, "read", now),
           do: Store.readiness(service.store)

    {conn, normalize(result)}
  end

  defp scoped(%{method: "GET"} = conn, ["credentials"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.credentials(service, token, scope, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["access"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.access(service, token, scope, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["access_audit"], params, context) do
    {service, token, scope, now} = context

    result =
      with {:ok, params} <- list_params(params),
           do: Service.access_audit(service, token, scope, params, now)

    {conn, result}
  end

  defp scoped(%{method: "GET"} = conn, ["privacy"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.privacy(service, token, scope, now)}
  end

  defp scoped(%{method: "GET"} = conn, ["notification_endpoints"], params, context)
       when map_size(params) == 0 do
    {service, token, scope, now} = context
    {conn, Service.notification_endpoints(service, token, scope, now)}
  end

  defp scoped(
         %{method: "GET"} = conn,
         ["notification_endpoints", id],
         params,
         {service, token, scope, now}
       )
       when map_size(params) == 0,
       do: {conn, Service.notification_endpoint(service, token, scope, id, now)}

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
           "cellular" => Atom.to_string(service.cellular_ingress),
           "rules" => "heartbeat_battery_motion_geofence_suspicious_movement_definitions",
           "analytics" => "structured_queries",
           "route_history" => "snapshot_pinned_gap_honest_pages",
           "trip_history" => "snapshot_pinned_event_pages",
           "trip_summaries" => "bounded_gap_honest_reconstruction",
           "arming" => "explicit_administrative_fact",
           "owner_presence" => "closed_evidence_fact_admission",
           "notifications" => "encrypted_principal_bound_apns_registration",
           "notification_delivery" => Atom.to_string(service.notification_delivery),
           "access_audit" => "bounded_successful_authorization_decisions",
           "privacy" => "administrator_inspection_and_scope_domain_data_deletion",
           "runtime" => %{
             "readproperty" => "available",
             "observeproperty" => "available",
             "invokeaction" => Atom.to_string(service.action_delivery)
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

  defp trip_params(params) when is_map(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ["limit", "cursor", "from_at", "to_at"])),
         {:ok, params} <- list_params(params),
         {:ok, params} <- time_param(params, "from_at"),
         {:ok, params} <- time_param(params, "to_at") do
      {:ok, params}
    else
      false -> Wire.error(:invalid_request)
      error -> error
    end
  end

  defp time_param(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, params}
      {:ok, value} -> parsed_time_param(params, key, value)
    end
  end

  defp parsed_time_param(params, key, value) when is_binary(value) do
    with {integer, ""} when integer in 0..9_007_199_254_740_991 <- Integer.parse(value),
         true <- Integer.to_string(integer) == value do
      {:ok, Map.put(params, key, integer)}
    else
      _ -> Wire.error(:invalid_request)
    end
  end

  defp parsed_time_param(_params, _key, _value), do: Wire.error(:invalid_request)

  defp property_cursor(conn, params) do
    case {params, Wire.single_header(conn, "last-event-id")} do
      {empty, {:ok, nil}} when map_size(empty) == 0 -> {:ok, nil}
      _ -> stream_cursor(conn, params)
    end
  end

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

  defp respond({:property_stream, conn, service, access, page}, capacity, lease, config) do
    case Capacity.stream(capacity, lease) do
      :ok -> PropertyStream.run(conn, service, access, page, config)
      error -> Wire.send_result(conn, error)
    end
  end

  defp respond({:stream, conn, service, access, cursor, page}, capacity, lease, config) do
    case Capacity.stream(capacity, lease) do
      :ok -> Stream.run(conn, service, access, cursor, page, config)
      error -> Wire.send_result(conn, error)
    end
  end
end
