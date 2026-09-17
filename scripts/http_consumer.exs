defmodule Wotex.Tracker.HTTPConsumer do
  @moduledoc false

  alias ExJsonSchema.{Schema, Validator}
  alias Wotex.Tracker.Service.{Codec, Identifier}

  @body_limit 4_194_304
  @payload "BRL8U5TDfAAE//wEDKw2QgDNy7gzTIhP"

  def main([descriptor_path]) do
    {:ok, _} = Application.ensure_all_started(:inets)
    descriptor = descriptor_path |> File.read!() |> Codec.decode!()
    context = load_contract(descriptor)
    run(context, descriptor)
  end

  def main(_arguments), do: raise("usage: http_consumer.exs DESCRIPTOR")

  defp load_contract(descriptor) do
    context = %{
      base: descriptor["url"],
      scope: descriptor["scope"],
      credentials: %{token: descriptor["token"], reader: descriptor["reader"]}
    }

    {%{"openapi" => "3.1.0"} = specification, _bytes} =
      request(context, nil, "/api/v1/openapi.json", who: nil, validate: false)

    operations =
      specification["paths"]
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Map.new(&{&1["operationId"], &1})

    Map.merge(context, %{
      specification: specification,
      schema: Schema.resolve(specification),
      operations: operations
    })
  end

  # Rule status needs host-seeded rule transitions, so it runs against a separate store.
  defp run(context, %{"mode" => "rules"}) do
    rule_workflow(context, context.scope)
    IO.puts("HTTP_CONSUMER_PASS openapi=true rule_status=true alerts=true")
  end

  defp run(context, descriptor) do
    workflow(context, descriptor)

    IO.puts(
      "HTTP_CONSUMER_PASS openapi=true enrollment=true materialisation=true " <>
        "native_types=true history=true replay=true revoked_stream_closed=true " <>
        "property_observation=true analytics_pagination=true saved_queries=true " <>
        "rule_definitions=true"
    )
  end

  defp workflow(context, descriptor) do
    prefix = "/api/v1/scopes/" <> encode_segment(context.scope)

    %{"status" => "live"} = data(context, "liveness", "/health/live", who: nil)
    request(context, "capabilities", prefix <> "/capabilities", who: nil, status: 401)

    %{"ble_scan" => "unsupported"} =
      data(context, "capabilities", prefix <> "/capabilities")

    request(context, "capabilities", prefix <> "/capabilities",
      headers: [{"authorization", "bearer " <> context.credentials.token}]
    )

    request(context, "capabilities", prefix <> "/capabilities",
      headers: [{"authorization", "Basic invalid"}],
      status: 401
    )

    %{"writable" => true} = data(context, "readiness", prefix <> "/health/ready")
    snapshot = data(context, "list_state", prefix <> "/state", who: :reader)
    "0" = snapshot["generation"]

    observation = observation("private-client-observation")
    import = %{"observation" => observation, "expected_generation" => "0"}

    {%{"error" => %{"outcome" => "not_committed"}}, _bytes} =
      request(context, "import_observation", prefix <> "/observations",
        body: import,
        who: nil,
        status: 401
      )

    request(context, "import_observation", prefix <> "/observations",
      body: import,
      who: :reader,
      status: 403
    )

    request(context, "import_observation", prefix <> "/observations",
      body: import,
      operation: "not-uuid",
      status: 400
    )

    request(context, "import_observation", prefix <> "/observations",
      body: import,
      headers: [{"content-type", "text/plain"}],
      status: 415
    )

    request(context, "import_observation", prefix <> "/observations",
      body: import,
      headers: [{"content-encoding", "gzip"}],
      status: 415
    )

    request(context, "import_observation", prefix <> "/observations",
      body: import,
      headers: [{"accept", "application/xml"}],
      status: 406
    )

    request(context, "list_state", prefix <> "/state",
      headers: [{"accept", "application/json;q=0, */*;q=1"}],
      status: 406
    )

    request(context, "list_state", prefix <> "/state",
      headers: [{"accept", "text/plain, application/*;q=0.8"}]
    )

    request(context, "capabilities", prefix <> "/capabilities", method: :delete, status: 405)
    request(context, "list_state", prefix <> "/state?limit=101", status: 400)
    request(context, "list_state", prefix <> "/state?limit=bad", status: 400)
    request(context, "list_state", prefix <> "/state?limit=1")
    request(context, "get_state", prefix <> "/state/missing?extra=true", status: 400)
    request(context, "stream_events", prefix <> "/events/stream", status: 400)
    request(context, "get_things", prefix <> "/things/missing", status: 404)
    operation = Identifier.uuid()

    imported =
      data(context, "import_observation", prefix <> "/observations",
        body: import,
        operation: operation
      )

    "1" = imported["generation"]

    ^imported =
      data(context, "import_observation", prefix <> "/observations",
        body: import,
        operation: operation
      )

    ^imported = data(context, "operation_status", prefix <> "/operations/" <> operation)

    request(context, "import_observation", prefix <> "/observations",
      body: put_in(import, ["expected_generation"], "1"),
      operation: operation,
      status: 409
    )

    observation_id = get_in(imported, ["data", "observation_id"])
    {public, public_bytes} = request(context, "list_observations", prefix <> "/observations")
    ^observation_id = get_in(public, ["data", "items", Access.at(0), "id"])

    for private <- ["private-client-observation", "private-hardware", "9007199254740993"] do
      false = String.contains?(public_bytes, private)
    end

    raw_path = prefix <> "/observations/" <> encode_segment(observation_id) <> "/raw"
    request(context, "export_observation", raw_path, who: :reader, status: 403)
    {^observation, raw_bytes} = request(context, "export_observation", raw_path)
    true = String.contains?(raw_bytes, ~s("float":1.0))
    true = String.contains?(raw_bytes, ~s("wide":9007199254740993))

    state =
      data(context, "get_state", prefix <> "/state/" <> encode_segment(observation_id))["value"]

    temperature = Enum.find(state["measurements"], &(&1["kind"] == "temperature"))
    %{"type" => "number", "value" => 24.3} = temperature["value"]

    enrolled =
      data(context, "enroll", prefix <> "/enrollments",
        body: %{
          "observation_id" => observation_id,
          "title" => "Independent client sensor",
          "owner_confirmed" => true,
          "expected_generation" => "1"
        }
      )

    thing = get_in(enrolled, ["data", "thing_id"])

    %{"generation" => "3"} =
      data(context, "materialize", prefix <> "/materialisations",
        body: %{"thing_id" => thing, "expected_generation" => "2"}
      )

    query = query(thing, descriptor["now"], "independent-temperature-history", 1)

    analytics =
      data(context, "query_analytics", prefix <> "/analytics/query", body: query, who: :reader)

    ^query = analytics["spec"]
    1 = analytics["qualified_rows"]
    24.3 = get_in(analytics, ["series", Access.at(0), "points", Access.at(0), "value"])

    paged_query = query(thing, descriptor["now"], "independent-temperature-pages", 2)

    page_request = %{
      "schema" => "wtr.query-page-request.v1",
      "query" => paged_query,
      "page_size" => 1,
      "cursor" => nil
    }

    first_page =
      data(context, "page_analytics", prefix <> "/analytics/pages",
        body: page_request,
        who: :reader
      )

    0 = first_page["page"]["index"]
    true = is_binary(first_page["cursor"])

    second_page =
      data(context, "page_analytics", prefix <> "/analytics/pages",
        body: %{page_request | "cursor" => first_page["cursor"]},
        who: :reader
      )

    1 = second_page["page"]["index"]
    nil = second_page["cursor"]
    true = first_page["generation"] == second_page["generation"]

    true =
      get_in(first_page, ["result", "snapshot"]) == get_in(second_page, ["result", "snapshot"])

    forged = %{query | "identity" => "wtr-json-v1:sha256:" <> String.duplicate("0", 64)}

    request(context, "query_analytics", prefix <> "/analytics/query",
      body: forged,
      who: :reader,
      status: 400
    )

    replay =
      data(
        context,
        "replay_events",
        prefix <> "/events?" <> URI.encode_query(%{"cursor" => snapshot["stream_cursor"]}),
        who: :reader
      )

    ["1", "2", "3"] = Enum.map(replay["items"], & &1["id"])
    thing_path = prefix <> "/things/" <> encode_segment(thing)
    td = data(context, "get_things", thing_path)["value"]
    ^thing = td["id"]
    10 = map_size(td["properties"])

    {24.3, _bytes} =
      request(context, "read_property", thing_path <> "/properties/temperature", who: :reader)

    {100_044, _bytes} =
      request(context, "read_property", thing_path <> "/properties/pressure", who: :reader)

    evidence =
      request(
        context,
        "export_evidence",
        prefix <> "/evidence/" <> encode_segment(thing) <> "/raw"
      )
      |> elem(0)

    true = Enum.any?(evidence, &(get_in(&1, ["claim", "strategy"]) == "operator-pseudonym-v1"))
    event_stream_workflow(context, prefix, snapshot, td)
    post_stream_workflow(context, prefix, thing, observation, td)
  end

  defp rule_workflow(context, scope) do
    prefix = "/api/v1/scopes/" <> encode_segment(scope)
    rules = prefix <> "/rules"

    %{"rules" => "heartbeat_battery_definitions"} =
      data(context, "capabilities", prefix <> "/capabilities", who: :reader)

    request(context, "list_rules", rules, who: nil, status: 401)
    request(context, "list_rules", rules <> "?limit=0", who: :reader, status: 400)
    first = data(context, "list_rules", rules <> "?limit=2", who: :reader)
    items = rule_pages(context, rules, first, first["items"])

    ["battery", "geofence", "heartbeat", "motion", "transport_degradation"] =
      Enum.map(items, & &1["value"]["kind"])

    ["low", "inside", "overdue", "moving", "degraded"] =
      Enum.map(items, & &1["value"]["status"])

    heartbeat = Enum.find(items, &(&1["id"] == "heartbeat:silence"))
    heartbeat_path = rules <> "/" <> encode_segment(heartbeat["id"])
    fetched = data(context, "get_rules", heartbeat_path, who: :reader)
    true = fetched["value"] == heartbeat["value"]
    %{"type" => "integer", "value" => _} = fetched["value"]["heartbeat"]["due_at"]
    request(context, "get_rules", rules <> "/heartbeat%3Amissing", who: :reader, status: 404)
    history = data(context, "history_rules", heartbeat_path <> "/history", who: :reader)

    [{"current", false}, {"overdue", false}] =
      Enum.map(history["items"], &{&1["value"]["status"], &1["deleted"]})

    {_value, bytes} = request(context, "list_rules", rules, who: :reader)

    for private <- ~w(capture private-hardware latitude longitude bundle payload) do
      false = String.contains?(bytes, private)
    end

    alert_workflow(context, prefix)
  end

  defp alert_workflow(context, prefix) do
    {%{"data" => page}, bytes} =
      request(context, "list_alerts", prefix <> "/alerts", who: :reader)

    ["geofence.entered", "trip.started", "transport.degraded", "battery.low", "heartbeat.overdue"] =
      Enum.map(page["items"], & &1["value"]["event"]["kind"])

    for private <- ~w(capture _evidence_id _observation_id _sample_identity) do
      false = String.contains?(bytes, private)
    end

    [newest | _] = page["items"]
    body = %{"alert_id" => newest["id"], "expected_generation" => page["generation"]}
    path = prefix <> "/alert_acknowledgements"
    request(context, "acknowledge_alert", path, body: body, who: :reader, status: 403)

    %{"data" => %{"action" => "acknowledged"}} =
      data(context, "acknowledge_alert", path, body: body)

    request(context, "acknowledge_alert", path, body: body, status: 409)
    alert_path = prefix <> "/alerts/" <> encode_segment(newest["id"])

    %{"acknowledgement" => %{"by" => "wtr1_" <> _}} =
      data(context, "get_alerts", alert_path)["value"]

    [nil, %{}] =
      context
      |> data("history_alerts", alert_path <> "/history", who: :reader)
      |> Map.fetch!("items")
      |> Enum.map(& &1["value"]["acknowledgement"])
  end

  defp rule_pages(_context, _rules, %{"cursor" => nil}, items), do: items

  defp rule_pages(context, rules, %{"cursor" => cursor}, items) do
    page =
      data(context, "list_rules", rules <> "?cursor=" <> URI.encode_www_form(cursor),
        who: :reader
      )

    rule_pages(context, rules, page, items ++ page["items"])
  end

  defp event_stream_workflow(context, prefix, snapshot, td) do
    stream =
      open_stream(
        context,
        prefix <> "/events/stream?" <> URI.encode_query(%{"cursor" => snapshot["stream_cursor"]}),
        :reader
      )

    {%{"event" => "ready"}, stream} = next_frame(stream)

    {events, stream} =
      Enum.map_reduce(1..3, stream, fn _index, connection ->
        {frame, connection} = next_frame(connection)
        "tracker" = frame["event"]
        event = Codec.decode!(frame["data"])

        validate_schema!(
          context,
          get_in(context.specification, ["components", "schemas", "Event"]),
          event
        )

        true = frame["id"] == event["cursor"]
        {event, connection}
      end)

    ["1", "2", "3"] = Enum.map(events, & &1["id"])
    close_stream(stream)

    resumed =
      open_stream(context, prefix <> "/events/stream", :reader,
        headers: [{"last-event-id", events |> Enum.at(1) |> Map.fetch!("cursor")}]
      )

    {%{"event" => "ready"}, resumed} = next_frame(resumed)
    {frame, resumed} = next_frame(resumed)
    "3" = frame["data"] |> Codec.decode!() |> Map.fetch!("id")

    data(context, "revoke", prefix <> "/revocations",
      body: %{"credential_id" => "reader", "expected_generation" => "3"}
    )

    :closed = await_close(resumed)
    request(context, "list_state", prefix <> "/state", who: :reader, status: 401)
    request(context, "capabilities", "/api/v9/scopes/workshop/capabilities", status: 404)
    request(context, "list_state", prefix <> "/state?limit=01", status: 400)
    request(context, "list_state", prefix <> "/state?limit=1&limit=2", status: 400)
    request(context, "list_state", prefix <> "/state?token=forbidden", status: 400)

    request(context, "import_observation", prefix <> "/observations",
      raw: ~s({"observation":{},"observation":{}}),
      method: :post,
      validate_body: false,
      status: 400
    )

    request(context, "import_observation", prefix <> "/observations",
      raw: :binary.copy(" ", 1_048_577),
      method: :post,
      validate_body: false,
      status: 400
    )

    true = td["properties"]["temperature"]["observable"]
  end

  defp post_stream_workflow(context, prefix, thing, observation, td) do
    wide = %{
      observation
      | "id" => "wide-clock-fixture",
        "ingress" => "imported",
        "observed_at" => 9_007_199_254_740_993,
        "payload" => %{
          "kind" => "json",
          "value" => %{"integer" => 1, "float" => 1.0, "false" => false, "null" => nil}
        }
    }

    imported =
      data(context, "import_observation", prefix <> "/observations",
        body: %{"observation" => wide, "expected_generation" => "4"}
      )

    wide_id = get_in(imported, ["data", "observation_id"])

    %{"type" => "wide_integer", "value" => "9007199254740993"} =
      data(context, "get_observations", prefix <> "/observations/" <> wide_id)["value"][
        "observed_at"
      ]

    for generation <- ["5", "6"] do
      data(context, "materialize", prefix <> "/materialisations",
        body: %{"thing_id" => thing, "expected_generation" => generation}
      )
    end

    state_path = prefix <> "/state/" <> encode_segment(thing)
    history = data(context, "history_state", state_path <> "/history?limit=1")
    ["3"] = Enum.map(history["items"], & &1["generation"])

    second_history =
      data(
        context,
        "history_state",
        state_path <> "/history?" <> URI.encode_query(%{"cursor" => history["cursor"]})
      )

    ["6"] = Enum.map(second_history["items"], & &1["generation"])

    third_history =
      data(
        context,
        "history_state",
        state_path <> "/history?" <> URI.encode_query(%{"cursor" => second_history["cursor"]})
      )

    ["7"] = Enum.map(third_history["items"], & &1["generation"])

    request(context, "history_state", state_path <> "/history", who: :reader, status: 401)
    request(context, "history_state", state_path <> "/history?limit=101", status: 400)
    request(context, "history_state", prefix <> "/state/missing/history", status: 404)

    data(context, "materialize", prefix <> "/materialisations",
      body: %{"thing_id" => thing, "expected_generation" => "7"}
    )

    observe_path =
      prefix <> "/things/" <> encode_segment(thing) <> "/properties/temperature/observe"

    request(context, "observe_property", observe_path, who: nil, status: 401)
    request(context, "observe_property", observe_path, who: :reader, status: 401)

    request(
      context,
      "observe_property",
      prefix <> "/things/" <> encode_segment(thing) <> "/properties/missing/observe",
      status: 404
    )

    request(context, "observe_property", observe_path <> "?cursor=wtrc1.invalid", status: 400)

    property = open_stream(context, observe_path, :token)
    {first, property} = next_frame(property)
    "property:snapshot:8:8" = first["event"]
    24.3 = Codec.decode!(first["data"])
    validate_schema!(context, td["properties"]["temperature"], Codec.decode!(first["data"]))

    data(context, "materialize", prefix <> "/materialisations",
      body: %{"thing_id" => thing, "expected_generation" => "8"}
    )

    {updated, property} = next_frame(property)
    "property:event:9:9" = updated["event"]
    close_stream(property)

    resumed =
      open_stream(
        context,
        observe_path <> "?" <> URI.encode_query(%{"cursor" => first["id"]}),
        :token
      )

    {replayed, resumed} = next_frame(resumed)
    true = updated["event"] == replayed["event"]
    true = updated["data"] == replayed["data"]
    close_stream(resumed)

    saved = %{
      "id" => "independent-temperature",
      "title" => "Independent temperature",
      "query" => query(thing, 1_700_000_000_000, "independent-temperature-history", 1),
      "visualization" => %{"type" => "line", "show_legend" => true, "show_points" => false},
      "expected_generation" => "9"
    }

    receipt = data(context, "save_query", prefix <> "/saved_queries", body: saved)
    "10" = receipt["generation"]
    %{"query_id" => "independent-temperature", "action" => "saved"} = receipt["data"]
    saved_path = prefix <> "/saved_queries/" <> encode_segment(saved["id"])
    definition = data(context, "get_saved_queries", saved_path)["value"]
    true = saved["query"] == definition["query"]

    [^definition] =
      context
      |> data("list_saved_queries", prefix <> "/saved_queries")
      |> Map.fetch!("items")
      |> Enum.map(& &1["value"])

    executed = data(context, "execute_saved_query", saved_path <> "/execute")
    true = saved["query"] == executed["spec"]

    %{"generation" => "11", "data" => %{"action" => "deleted"}} =
      data(context, "delete_query", prefix <> "/saved_query_deletions",
        body: %{"id" => saved["id"], "expected_generation" => "10"}
      )

    request(context, "get_saved_queries", saved_path, status: 404)

    [false, true] =
      context
      |> data("history_saved_queries", saved_path <> "/history")
      |> Map.fetch!("items")
      |> Enum.map(& &1["deleted"])

    policy_workflow(context, prefix, thing)
  end

  defp policy_workflow(context, prefix, thing) do
    policy = %{
      "id" => "independent-battery",
      "kind" => "battery",
      "thing_id" => thing,
      "parameters" => %{
        "measurement_kind" => "batteryVoltage",
        "unit" => "V",
        "low_threshold" => 2.5,
        "clear_threshold" => 2.8,
        "maximum_age_ms" => 3_600_000,
        "future_skew_ms" => 0,
        "accept_suspect" => false
      },
      "expected_generation" => "11"
    }

    request(context, "save_policy", prefix <> "/policies", body: policy, who: nil, status: 401)

    request(context, "save_policy", prefix <> "/policies",
      body: put_in(policy, ["parameters", "unit"], "mV"),
      status: 501
    )

    %{"generation" => "12", "data" => %{"policy_id" => "independent-battery"}} =
      data(context, "save_policy", prefix <> "/policies", body: policy)

    request(context, "save_policy", prefix <> "/policies", body: policy, status: 409)
    policy_path = prefix <> "/policies/independent-battery"
    definition = data(context, "get_policies", policy_path)["value"]
    %{"kind" => "battery", "revision" => "12", "thing_id" => ^thing} = definition
    false = Map.has_key?(definition, "actor")

    %{"items" => [%{"id" => "independent-battery", "value" => ^definition}]} =
      data(context, "list_policies", prefix <> "/policies")

    %{"generation" => "12", "value" => status} =
      data(context, "get_rules", prefix <> "/rules/battery%3Aindependent-battery")

    %{"status" => "normal", "rule" => %{"revision" => "12", "identity" => identity}} = status
    ^identity = definition["policy_identity"]
    %{"type" => "number", "value" => 2.977} = status["battery"]["measurement"]["value"]

    %{"generation" => "13", "data" => %{"action" => "deleted"}} =
      data(context, "delete_policy", prefix <> "/policy_deletions",
        body: %{"id" => "independent-battery", "expected_generation" => "12"}
      )

    request(context, "get_policies", policy_path, status: 404)

    [false, true] =
      context
      |> data("history_policies", policy_path <> "/history")
      |> Map.fetch!("items")
      |> Enum.map(& &1["deleted"])
  end

  defp query(thing, now, id, points) do
    query = %{
      "schema" => "wtr.query-spec.v1",
      "algorithm" => "absolute-utc-buckets-v1",
      "id" => id,
      "revision" => "http-query-v1",
      "dataset" => "measurements",
      "measurement" => "temperature",
      "unit" => "Cel",
      "series" => [thing],
      "qualities" => ["valid"],
      "from_at" => now,
      "to_at" => now + points,
      "timezone" => "Etc/UTC",
      "bucket_ms" => 1,
      "aggregation" => "last",
      "order" => "ascending",
      "max_points" => points,
      "window_semantics" => "from_inclusive_to_exclusive",
      "missing_values" => "excluded_and_disclosed"
    }

    Map.put(query, "identity", "wtr-json-v1:sha256:" <> Codec.digest(query))
  end

  defp observation(id) do
    %{
      "schema" => "wtr.observation.v1",
      "id" => id,
      "observed_at" => 1_700_000_000_000,
      "ingress" => "ble",
      "source" => %{
        "integer" => 1,
        "float" => 1.0,
        "wide" => 9_007_199_254_740_993,
        "zero" => 0,
        "false" => false,
        "null" => nil
      },
      "addressing" => %{"mac" => "private-hardware"},
      "radio" => %{},
      "transport" => %{"manufacturer_id" => 1_177},
      "provenance" => %{"kind" => "fixture"},
      "payload" => %{"kind" => "bytes", "encoding" => "base64", "data" => @payload}
    }
  end

  defp data(context, operation, path, options \\ []) do
    {value, _bytes} = request(context, operation, path, options)
    value["data"]
  end

  defp request(context, operation, path, options \\ []) do
    expected = Keyword.get(options, :status, 200)
    who = Keyword.get(options, :who, :token)
    body = Keyword.get(options, :body)
    validate? = Keyword.get(options, :validate, true)
    contract = contract!(context, operation)

    validate_request_body!(
      context,
      contract,
      body,
      Keyword.get(options, :validate_body, validate?)
    )

    method = Keyword.get(options, :method, request_method(body))
    bytes = request_bytes(body, Keyword.get(options, :raw))

    headers =
      context
      |> authorization(who)
      |> request_headers(contract, bytes, Keyword.get(options, :operation))
      |> put_headers(Keyword.get(options, :headers, []))

    {:ok, {{_version, status, _reason}, response_headers, response_body}} =
      send_request(method, context.base <> path, headers, bytes)

    validate_status!(status, expected, operation || path, response_body)
    validate_body_limit!(response_body)
    value = Codec.decode!(response_body)
    validate_response!(context, contract, status, response_headers, value, validate?)
    {value, response_body}
  end

  defp contract!(_context, nil), do: nil

  defp contract!(context, operation) do
    context.operations[operation] || raise("missing OpenAPI operation #{operation}")
  end

  defp validate_request_body!(context, contract, body, true) when not is_nil(body),
    do: validate_request!(context, contract, body)

  defp validate_request_body!(_context, _contract, _body, _validate?), do: :ok

  defp request_method(nil), do: :get
  defp request_method(_body), do: :post

  defp request_bytes(nil, raw), do: raw
  defp request_bytes(body, _raw), do: Codec.encode!(body)

  defp send_request(method, url, headers, nil) do
    input = {String.to_charlist(url), charlist_headers(headers)}
    :httpc.request(method, input, [timeout: 5_000, autoredirect: false], body_format: :binary)
  end

  defp send_request(method, url, headers, bytes) do
    media =
      headers
      |> Enum.find_value("application/json", fn {name, value} ->
        if name == "content-type", do: value
      end)

    headers = Enum.reject(headers, fn {name, _value} -> name == "content-type" end)

    input =
      {String.to_charlist(url), charlist_headers(headers), String.to_charlist(media), bytes}

    :httpc.request(method, input, [timeout: 5_000, autoredirect: false], body_format: :binary)
  end

  defp validate_status!(status, status, _operation, _body), do: :ok

  defp validate_status!(status, expected, operation, body),
    do: raise("#{operation} returned #{status}, expected #{expected}: #{body}")

  defp validate_body_limit!(body) when byte_size(body) <= @body_limit, do: :ok
  defp validate_body_limit!(_body), do: raise("response exceeded body limit")

  defp validate_response!(_context, _contract, _status, _headers, _value, false), do: :ok

  defp validate_response!(context, contract, status, headers, value, true) do
    normalized = normalize_headers(headers)

    response =
      contract["responses"][Integer.to_string(status)] || contract["responses"]["default"]

    [{media, %{"schema" => schema}}] = Map.to_list(response["content"])
    ^media = normalized["content-type"] |> String.split(";", parts: 2) |> hd()
    "no-store" = normalized["cache-control"]
    "nosniff" = normalized["x-content-type-options"]
    validate_schema!(context, schema, value)
  end

  defp authorization(_context, nil), do: []

  defp authorization(context, who),
    do: [{"authorization", "Bearer " <> Map.fetch!(context.credentials, who)}]

  defp put_headers(headers, additions) do
    Enum.reduce(additions, headers, fn {name, value}, result ->
      name = String.downcase(name)
      [{name, value} | Enum.reject(result, fn {existing, _} -> existing == name end)]
    end)
  end

  defp request_headers(headers, _contract, nil, _operation), do: headers

  defp request_headers(headers, contract, _bytes, operation) do
    headers = put_headers(headers, [{"content-type", "application/json"}])

    if idempotent?(contract),
      do: put_headers(headers, [{"idempotency-key", operation || Identifier.uuid()}]),
      else: headers
  end

  defp idempotent?(contract) do
    Enum.any?(contract["parameters"] || [], fn
      %{"$ref" => "#/components/parameters/Idempotency"} -> true
      _ -> false
    end)
  end

  defp validate_request!(context, contract, body) do
    schema = get_in(contract, ["requestBody", "content", "application/json", "schema"])
    validate_schema!(context, schema, body)
  end

  defp validate_schema!(context, schema, value) do
    case Validator.validate_fragment(context.schema, schema, value) do
      :ok -> :ok
      {:error, errors} -> raise("OpenAPI exchange validation failed: #{inspect(errors)}")
    end
  end

  defp open_stream(context, path, who, options \\ []) do
    uri = URI.parse(context.base)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false], 5_000)

    headers =
      context
      |> authorization(who)
      |> put_headers([{"accept", "text/event-stream"}, {"connection", "close"}])
      |> put_headers(Keyword.get(options, :headers, []))

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\nHost: ",
      uri.host,
      "\r\n",
      encode_headers(headers),
      "\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {head, rest} = receive_head(socket, <<>>)
    [status | header_lines] = String.split(head, "\r\n", trim: true)
    true = String.starts_with?(status, "HTTP/1.1 200 ")
    response_headers = parse_header_lines(header_lines)
    "text/event-stream" = response_headers["content-type"] |> String.split(";", parts: 2) |> hd()
    %{socket: socket, buffer: rest}
  end

  defp receive_head(_socket, bytes) when byte_size(bytes) > 8_192,
    do: raise("stream response headers exceeded limit")

  defp receive_head(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        receive_head(socket, bytes <> chunk)
    end
  end

  defp next_frame(stream) do
    case take_frame(stream.buffer) do
      {:ok, frame, rest} ->
        case decode_frame(frame) do
          nil -> next_frame(%{stream | buffer: rest})
          value -> {value, %{stream | buffer: rest}}
        end

      :more ->
        {:ok, bytes} = :gen_tcp.recv(stream.socket, 0, 5_000)

        if byte_size(stream.buffer) + byte_size(bytes) > 32_768,
          do: raise("SSE frame exceeded limit")

        next_frame(%{stream | buffer: stream.buffer <> bytes})
    end
  end

  defp take_frame(bytes) do
    case :binary.match(bytes, ["\n\n", "\r\n\r\n"]) do
      {index, length} ->
        <<frame::binary-size(index), _separator::binary-size(length), rest::binary>> = bytes
        {:ok, frame, rest}

      :nomatch ->
        :more
    end
  end

  defp decode_frame(frame) do
    fields =
      frame
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&String.starts_with?(&1, ":"))
      |> Enum.reduce(%{}, fn line, result ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            Map.update(
              result,
              name,
              String.trim_leading(value),
              &(&1 <> "\n" <> String.trim_leading(value))
            )

          _ ->
            result
        end
      end)

    if map_size(fields) == 0, do: nil, else: fields
  end

  defp await_close(stream) do
    case :gen_tcp.recv(stream.socket, 0, 3_000) do
      {:error, :closed} -> :closed
      {:ok, _heartbeat} -> await_close(stream)
      other -> raise("stream did not close after revocation: #{inspect(other)}")
    end
  end

  defp close_stream(stream), do: :gen_tcp.close(stream.socket)

  defp encode_headers(headers),
    do: Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

  defp charlist_headers(headers),
    do:
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> List.to_string() |> String.downcase(), List.to_string(value)}
    end)
  end

  defp parse_header_lines(lines) do
    Map.new(lines, fn line ->
      [name, value] = String.split(line, ":", parts: 2)
      {String.downcase(name), String.trim(value)}
    end)
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end

unless System.get_env("WOTEX_TRACKER_HTTP_NO_MAIN") == "1" do
  Wotex.Tracker.HTTPConsumer.main(System.argv())
end
