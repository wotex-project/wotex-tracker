defmodule Wotex.Tracker.UI.Remote do
  @moduledoc """
  Calls the versioned Tracker HTTP service for shared presentation screens.

  A value is built from an explicit HTTPS origin and bounded transport. The
  adapter maps only the closed `Wotex.Tracker.UI.Client` action vocabulary; page
  content cannot select a method, host, module or arbitrary path. Every call
  carries the server-held bearer credential only in the Authorization header.

  Transport ambiguity for an idempotent mutation returns an `unknown` outcome
  with its original operation ID. The adapter never retries a mutation.
  """

  @behaviour Wotex.Tracker.UI.Client

  alias Wotex.Tracker.UI.RemoteMintTransport

  @resources ~w(observations resolutions evidence state enrollments things saved_queries rules policies alerts arming owner_presence)
  @mutations %{
    acknowledge_alert: "alert_acknowledgements",
    associate: "associations",
    delete_policy: "policy_deletions",
    delete_query: "saved_query_deletions",
    enroll: "enrollments",
    materialize: "materialisations",
    revoke: "revocations",
    save_policy: "policies",
    save_query: "saved_queries",
    set_arming: "arming",
    submit: "observations",
    unenroll: "unenrollments"
  }
  @maximum_body_bytes 1_048_576
  @maximum_response_bytes 4_194_304
  @maximum_token_bytes 256
  @permissions ~w(admin enroll ingest interact raw read)

  @derive {Inspect, only: [:origin, :timeout_ms]}
  @enforce_keys [:origin, :authority, :transport, :timeout_ms]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          origin: String.t(),
          authority: %{scheme: :http | :https, host: String.t(), port: pos_integer()},
          transport: {module(), term()},
          timeout_ms: pos_integer()
        }

  @doc "Builds a remote client from an exact origin and optional bounded transport."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_configuration}
  def new(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- length(options) == map_size(Map.new(options)),
         true <-
           Keyword.keys(options) -- [:origin, :transport, :timeout_ms, :allow_loopback] == [],
         {:ok, origin, authority} <-
           origin(Keyword.get(options, :origin), Keyword.get(options, :allow_loopback, false)),
         transport <-
           Keyword.get(
             options,
             :transport,
             {RemoteMintTransport, {Mint.HTTP, &:public_key.cacerts_get/0}}
           ),
         true <- transport?(transport),
         timeout <- Keyword.get(options, :timeout_ms, 5_000),
         true <- is_integer(timeout) and timeout in 100..30_000 do
      {:ok,
       %__MODULE__{
         origin: origin,
         authority: authority,
         transport: transport,
         timeout_ms: timeout
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def new(_), do: {:error, :invalid_configuration}

  @impl true
  def request(%__MODULE__{} = remote, token, scope, :revocation_context, arguments, _now)
      when map_size(arguments) == 0 do
    with :ok <- credentials(token, scope),
         {:ok, access} <- exchange(remote, token, scope, access_request()),
         true <- access?(access, scope),
         true <- "admin" in access["permissions"],
         {:ok, %{"generation" => generation}} <-
           exchange(remote, token, scope, get(["enrollments"], %{"limit" => 1})) do
      {:ok, %{"credential_id" => access["credential_id"], "expected_generation" => generation}}
    else
      false -> error("forbidden")
      {:error, _} = error -> error
      _ -> unavailable()
    end
  end

  def request(%__MODULE__{} = remote, token, scope, action, arguments, _now)
      when is_atom(action) and is_map(arguments) do
    with :ok <- credentials(token, scope),
         {:ok, request} <- route(action, arguments),
         result <- exchange(remote, token, scope, request) do
      project(action, result, scope)
    else
      {:error, _} = error -> error
    end
  rescue
    _ -> failure(action, arguments)
  catch
    _, _ -> failure(action, arguments)
  end

  def request(_, _, _, _, _, _), do: error("invalid_request")

  defp route(:authorize, arguments) when map_size(arguments) == 0,
    do: {:ok, access_request()}

  defp route(:session_context, arguments) when map_size(arguments) == 0,
    do: {:ok, access_request()}

  defp route(:access, arguments) when map_size(arguments) == 0,
    do: {:ok, access_request()}

  defp route(:events, %{"cursor" => cursor} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["events"], %{"cursor" => cursor})}

  defp route(:operations, %{"params" => params} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["operations"], params || %{})}

  defp route(:credentials, arguments) when map_size(arguments) == 0,
    do: {:ok, get(["credentials"])}

  defp route(:list, %{"resource" => resource} = arguments)
       when map_size(arguments) in 1..2 and resource in @resources,
       do: {:ok, get([resource], arguments["params"] || %{})}

  defp route(:get, %{"resource" => resource, "id" => id} = arguments)
       when map_size(arguments) == 2 and resource in @resources,
       do: {:ok, get([resource, id])}

  defp route(:arming, %{"id" => id} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["arming", id])}

  defp route(:owner_presence, %{"id" => id} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["owner_presence", id])}

  defp route(:thing_policies, %{"thing" => thing} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["things", thing, "policies"])}

  defp route(:thing_rules, %{"thing" => thing} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["things", thing, "rules"])}

  defp route(:thing_alerts, %{"thing" => thing} = arguments) when map_size(arguments) in 1..2,
    do: {:ok, get(["things", thing, "alerts"], arguments["params"] || %{})}

  defp route(:thing_trips, %{"thing" => thing} = arguments) when map_size(arguments) in 1..2,
    do: {:ok, get(["things", thing, "trips"], arguments["params"] || %{})}

  defp route(:trip_summary, %{"thing" => thing, "trip" => trip} = arguments)
       when map_size(arguments) == 2,
       do: {:ok, get(["things", thing, "trips", trip])}

  defp route(:read_property, %{"thing" => thing, "name" => name} = arguments)
       when map_size(arguments) == 2,
       do: {:ok, get(["things", thing, "properties", name])}

  defp route(:raw_observation, %{"id" => id} = arguments) when map_size(arguments) == 1,
    do: {:ok, raw(["observations", id, "raw"], "application/vnd.wotex.tracker.observation+json")}

  defp route(:raw_evidence, %{"id" => id} = arguments) when map_size(arguments) == 1,
    do: {:ok, raw(["evidence", id, "raw"], "application/vnd.wotex.tracker.evidence+json")}

  defp route(:history, %{"resource" => resource, "id" => id} = arguments)
       when map_size(arguments) in 2..3 and resource in @resources,
       do: {:ok, get([resource, id, "history"], arguments["params"] || %{})}

  defp route(:analytics, %{"query" => query} = arguments) when map_size(arguments) == 1,
    do: json_post(["analytics", "query"], query)

  defp route(:route_history, %{"request" => request} = arguments)
       when map_size(arguments) == 1,
       do: json_post(["routes", "pages"], request)

  defp route(:execute_saved_query, %{"id" => id} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["saved_queries", id, "execute"])}

  defp route(:operation, %{"id" => id} = arguments) when map_size(arguments) == 1,
    do: {:ok, get(["operations", id])}

  defp route(action, %{"operation" => operation, "request" => request} = arguments)
       when map_size(arguments) == 2 and is_map_key(@mutations, action),
       do: mutation([Map.fetch!(@mutations, action)], operation, request)

  defp route(_, _), do: error("unsupported")

  defp access_request, do: get(["access"])

  defp get(segments, query \\ %{}),
    do: %{method: "GET", segments: segments, query: query, body: "", type: :json, operation: nil}

  defp raw(segments, media),
    do: %{
      method: "GET",
      segments: segments,
      query: %{},
      body: "",
      type: {:raw, media},
      operation: nil
    }

  defp json_post(segments, document) do
    with {:ok, body} <- encode(document) do
      {:ok,
       %{
         method: "POST",
         segments: segments,
         query: %{},
         body: body,
         type: :json,
         operation: nil
       }}
    end
  end

  defp mutation(segments, operation, document) do
    with true <- id?(operation),
         {:ok, body} <- encode(document) do
      {:ok,
       %{
         method: "POST",
         segments: segments,
         query: %{},
         body: body,
         type: :json,
         operation: operation
       }}
    else
      _ -> error("invalid_request")
    end
  end

  defp exchange(remote, token, scope, request) do
    with {:ok, path} <- request_path(scope, request.segments, request.query),
         headers <- headers(token, request),
         {module, context} <- remote.transport,
         result <-
           module.request(context, remote.authority, %{
             method: request.method,
             path: path,
             headers: headers,
             body: request.body,
             timeout_ms: remote.timeout_ms
           }) do
      response(result, request)
    else
      {:error, _} = error -> if(request.operation, do: unknown(request.operation), else: error)
      _ -> if(request.operation, do: unknown(request.operation), else: unavailable())
    end
  rescue
    _ -> if(request.operation, do: unknown(request.operation), else: unavailable())
  catch
    _, _ -> if(request.operation, do: unknown(request.operation), else: unavailable())
  end

  defp headers(token, %{method: method, operation: operation, type: type}) do
    accept = if match?({:raw, _}, type), do: elem(type, 1), else: "application/json"
    base = [{"authorization", "Bearer " <> token}, {"accept", accept}]
    base = if method == "POST", do: [{"content-type", "application/json"} | base], else: base
    if operation, do: [{"idempotency-key", operation} | base], else: base
  end

  defp response({:ok, status, headers, body}, request)
       when status in 100..599 and is_list(headers) and is_binary(body) and
              byte_size(body) <= @maximum_response_bytes do
    case request.type do
      :json -> json_response(status, headers, body, request.operation)
      {:raw, media} -> raw_response(status, headers, body, media)
    end
  end

  defp response(_, %{operation: operation}) when is_binary(operation), do: unknown(operation)
  defp response(_, _), do: unavailable()

  defp json_response(status, headers, body, operation) do
    with true <- media?(headers, "application/json"),
         {:ok, document} <- Jason.decode(body),
         true <- is_map(document) and document["schema"] == "wtr.response.v1" do
      envelope(status, document, operation)
    else
      _ -> if(operation, do: unknown(operation), else: unavailable())
    end
  end

  defp envelope(status, %{"schema" => _, "data" => data} = document, _operation)
       when status in 200..299 and map_size(document) == 2 and (is_map(data) or is_binary(data)),
       do: {:ok, data}

  defp envelope(status, %{"schema" => _, "error" => %{"code" => code} = error} = document, _)
       when status in 400..599 and map_size(document) == 2 and is_binary(code),
       do: {:error, error}

  defp envelope(_, _, operation) when is_binary(operation), do: unknown(operation)
  defp envelope(_, _, _), do: unavailable()

  defp raw_response(200, headers, body, media) do
    if media?(headers, media), do: {:ok, body}, else: unavailable()
  end

  defp raw_response(status, headers, body, _) when status in 400..599,
    do: json_response(status, headers, body, nil)

  defp raw_response(_, _, _, _), do: unavailable()

  defp project(:authorize, {:ok, access}, scope) do
    if access?(access, scope) do
      permissions = access["permissions"]

      {:ok,
       %{
         "scope" => scope,
         "can_enroll" => "enroll" in permissions,
         "can_ingest" => "ingest" in permissions,
         "can_read_raw" => "raw" in permissions,
         "can_manage_queries" => "admin" in permissions
       }}
    else
      unavailable()
    end
  end

  defp project(:session_context, {:ok, access}, scope) do
    if access?(access, scope) do
      permissions = access["permissions"]

      {:ok,
       %{
         "identity" => %{
           "scope" => scope,
           "can_enroll" => "enroll" in permissions,
           "can_ingest" => "ingest" in permissions,
           "can_read_raw" => "raw" in permissions,
           "can_manage_queries" => "admin" in permissions
         },
         "access" => %{
           "credential_id" => access["credential_id"],
           "principal" => access["principal"],
           "scope" => access["scope"],
           "expires_at" => access["expires_at"]
         }
       }}
    else
      unavailable()
    end
  end

  defp project(:access, {:ok, access}, scope) do
    if access?(access, scope) do
      {:ok,
       %{
         "principal" => access["principal"],
         "scope" => access["scope"],
         "expires_at" => access["expires_at"]
       }}
    else
      unavailable()
    end
  end

  defp project(_, result, _), do: result

  defp access?(
         %{
           "schema" => "wtr.access.v1",
           "credential_id" => credential,
           "principal" => principal,
           "scope" => scope,
           "permissions" => permissions,
           "expires_at" => expires_at
         } = access,
         scope
       ) do
    map_size(access) == 6 and identity?(credential, principal, scope) and expiry?(expires_at) and
      permissions?(permissions)
  end

  defp access?(_, _), do: false

  defp identity?(credential, principal, scope),
    do: id?(credential) and id?(principal) and id?(scope)

  defp expiry?(expires_at),
    do: is_integer(expires_at) and expires_at in 0..9_007_199_254_740_991

  defp permissions?(permissions) when is_list(permissions) do
    permissions != [] and length(permissions) <= 6 and
      permissions == Enum.sort(Enum.uniq(permissions)) and
      Enum.all?(permissions, &(&1 in @permissions)) and "read" in permissions
  end

  defp permissions?(_), do: false

  defp request_path(scope, segments, query) do
    with {:ok, scope} <- segment(scope),
         {:ok, segments} <- segments(segments, []),
         {:ok, query} <- query(query) do
      path = "/api/v1/scopes/" <> scope <> "/" <> Enum.join(segments, "/")
      {:ok, if(query == "", do: path, else: path <> "?" <> query)}
    end
  end

  defp segments([], encoded), do: {:ok, Enum.reverse(encoded)}

  defp segments([value | rest], encoded) do
    with {:ok, value} <- segment(value), do: segments(rest, [value | encoded])
  end

  defp segment(value) do
    if id?(value),
      do: {:ok, URI.encode(value, &URI.char_unreserved?/1)},
      else: error("invalid_request")
  end

  defp query(value) when is_map(value) and map_size(value) <= 4 do
    with true <- Enum.all?(Map.keys(value), &(&1 in ~w(limit cursor from_at to_at))),
         pairs <- value |> Enum.reject(fn {_, value} -> is_nil(value) end) |> Enum.sort(),
         true <- Enum.all?(pairs, fn {key, value} -> id?(key) and query_value?(value) end) do
      {:ok, URI.encode_query(pairs)}
    else
      _ -> error("invalid_request")
    end
  end

  defp query(_), do: error("invalid_request")

  defp query_value?(value) when is_integer(value), do: value in 0..9_007_199_254_740_991
  defp query_value?(value), do: id?(value)

  defp encode(document) do
    case Jason.encode(document) do
      {:ok, bytes} when byte_size(bytes) <= @maximum_body_bytes -> {:ok, bytes}
      _ -> error("invalid_request")
    end
  rescue
    _ -> error("invalid_request")
  end

  defp origin(value, allow_loopback) when is_binary(value) do
    uri = URI.parse(value)

    with true <- origin_uri?(uri),
         {:ok, scheme} <- scheme(uri.scheme),
         {:ok, port} <- port(scheme, uri.port),
         true <- transport_origin?(scheme, uri.host, allow_loopback) do
      normalized =
        URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: explicit_port(uri)})

      {:ok, normalized, %{scheme: scheme, host: uri.host, port: port}}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  defp origin(_, _), do: {:error, :invalid_configuration}

  defp origin_uri?(uri),
    do:
      is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and is_nil(uri.query) and
        is_nil(uri.fragment) and uri.path in [nil, ""]

  defp scheme("https"), do: {:ok, :https}
  defp scheme("http"), do: {:ok, :http}
  defp scheme(_), do: :error

  defp port(scheme, nil), do: {:ok, if(scheme == :https, do: 443, else: 80)}
  defp port(_, port) when port in 1..65_535, do: {:ok, port}
  defp port(_, _), do: :error

  defp transport_origin?(:https, _, _), do: true
  defp transport_origin?(:http, host, true), do: loopback?(host)
  defp transport_origin?(_, _, _), do: false

  defp explicit_port(%URI{scheme: "https", port: 443}), do: nil
  defp explicit_port(%URI{scheme: "http", port: 80}), do: nil
  defp explicit_port(%URI{port: port}), do: port

  defp loopback?(host), do: host in ["127.0.0.1", "::1"]

  defp credentials(token, scope) do
    if is_binary(token) and byte_size(token) in 1..@maximum_token_bytes and id?(scope),
      do: :ok,
      else: error("unauthorized")
  end

  defp transport?({module, _}) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :request, 3)

  defp transport?(_), do: false

  defp id?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  defp media?(headers, expected) do
    case Enum.filter(headers, fn
           {name, value} ->
             is_binary(name) and is_binary(value) and String.downcase(name) == "content-type"

           _ ->
             false
         end) do
      [{_, value}] -> value == expected or value == expected <> "; charset=utf-8"
      _ -> false
    end
  end

  defp failure(action, %{"operation" => operation})
       when is_map_key(@mutations, action) and is_binary(operation),
       do: unknown(operation)

  defp failure(_, _), do: unavailable()
  defp unknown(operation), do: {:ok, %{"outcome" => "unknown", "operation_id" => operation}}
  defp unavailable, do: error("storage_unavailable")
  defp error(code), do: {:error, %{"code" => code}}
end
