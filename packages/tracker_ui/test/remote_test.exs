defmodule Wotex.Tracker.UI.RemoteTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service.HTTP.Server
  alias Wotex.Tracker.UI.Remote

  @operation "2f8e7a8c-ea0f-4bf1-918e-b0852b124a72"
  @token "private-mobile-token"

  defmodule Transport do
    @behaviour Wotex.Tracker.UI.RemoteTransport

    @impl true
    def request({owner, responder}, origin, request) do
      send(owner, {:remote_request, origin, request})

      case responder do
        responder when is_function(responder, 1) -> responder.(request)
        :raise -> raise "private transport defect"
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end
  end

  test "configuration admits explicit HTTPS and test-only loopback without exposing transport state" do
    assert {:ok, remote} = remote(fn _ -> json(%{}) end)
    assert remote.origin == "https://service.example"
    assert remote.authority == %{scheme: :https, host: "service.example", port: 443}

    assert inspect(remote) ==
             "#Wotex.Tracker.UI.Remote<origin: \"https://service.example\", timeout_ms: 5000, ...>"

    assert {:ok, loopback} =
             Remote.new(
               origin: "http://127.0.0.1:4567",
               allow_loopback: true,
               transport: {Transport, {self(), {:error, :offline}}},
               timeout_ms: 100
             )

    assert loopback.authority == %{scheme: :http, host: "127.0.0.1", port: 4567}

    assert {:ok, default_loopback} =
             Remote.new(
               origin: "http://127.0.0.1",
               allow_loopback: true,
               transport: transport()
             )

    assert default_loopback.origin == "http://127.0.0.1"
    assert default_loopback.authority.port == 80

    for options <- [
          :invalid,
          [],
          [origin: "ftp://service.example", transport: transport()],
          [origin: "http://service.example", transport: transport()],
          [origin: "http://localhost", allow_loopback: true, transport: transport()],
          [origin: "https://user:secret@service.example", transport: transport()],
          [origin: "https://service.example/api", transport: transport()],
          [origin: "https://service.example?private=yes", transport: transport()],
          [origin: "https://service.example#fragment", transport: transport()],
          [origin: "https://service.example:0", transport: transport()],
          [origin: "https://service.example", timeout_ms: 99, transport: transport()],
          [origin: "https://service.example", timeout_ms: 30_001, transport: transport()],
          [origin: "https://service.example", transport: {String, nil}],
          [origin: "https://service.example", transport: :invalid],
          [origin: "https://service.example", origin: "https://other.example"],
          [origin: "https://service.example", unknown: true]
        ] do
      assert {:error, :invalid_configuration} = Remote.new(options)
    end
  end

  test "revocation context requires exact administrator access and generation" do
    reader = %{access() | "permissions" => ["read"]}
    {:ok, remote} = remote(fn _ -> json(reader) end)

    assert {:error, %{"code" => "forbidden"}} =
             Remote.request(remote, @token, "workshop", :revocation_context, %{}, 0)

    {:ok, denied} = remote(fn _ -> json_error("forbidden", 403) end)

    assert {:error, %{"code" => "forbidden"}} =
             Remote.request(denied, @token, "workshop", :revocation_context, %{}, 0)

    responder = fn request ->
      if String.ends_with?(request.path, "/access"),
        do: json(access()),
        else: json(%{"not_generation" => true})
    end

    {:ok, malformed} = remote(responder)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Remote.request(malformed, @token, "workshop", :revocation_context, %{}, 0)
  end

  test "request construction rejects malformed identities, queries and JSON" do
    {:ok, remote} = remote(fn _ -> json(%{}) end)

    for {action, arguments} <- [
          {:arming, %{"id" => ""}},
          {:operations, %{"params" => %{"extra" => "no"}}},
          {:operations, %{"params" => "invalid"}},
          {:operations,
           %{
             "params" => %{
               "cursor" => "next",
               "from_at" => 1,
               "limit" => 25,
               "to_at" => 2,
               "x" => 3
             }
           }},
          {:access_audit, %{"params" => "invalid"}},
          {:privacy, %{"extra" => true}},
          {:submit, %{"operation" => "", "request" => %{}}},
          {:analytics, %{"query" => String.duplicate("x", 1_048_577)}},
          {:analytics, %{"query" => self()}}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               Remote.request(remote, @token, "workshop", action, arguments, 0)
    end

    assert {:error, %{"code" => "invalid_request"}} =
             Remote.request(:invalid, @token, "workshop", :authorize, %{}, 0)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Remote.request(
               %{remote | transport: :invalid},
               @token,
               "workshop",
               :authorize,
               %{},
               0
             )
  end

  test "strict response admission contains malformed projections and raw outcomes" do
    malformed_access = [
      %{"schema" => "not-access"},
      %{access() | "permissions" => "read"}
    ]

    for access <- malformed_access, action <- [:authorize, :session_context, :access] do
      {:ok, remote} = remote(fn _ -> json(access) end)

      assert {:error, %{"code" => "storage_unavailable"}} =
               Remote.request(remote, @token, "workshop", action, %{}, 0)
    end

    cases = [
      {:get, %{"resource" => "state", "id" => "asset"}, json(%{}, 300),
       {:error, %{"code" => "storage_unavailable"}}},
      {:submit, %{"operation" => @operation, "request" => %{}}, json(%{}, 300),
       {:ok, %{"outcome" => "unknown", "operation_id" => @operation}}},
      {:raw_observation, %{"id" => "capture"}, json_error("forbidden", 403),
       {:error, %{"code" => "forbidden"}}},
      {:raw_observation, %{"id" => "capture"},
       {:ok, 201, [{"content-type", "application/vnd.wotex.tracker.observation+json"}], "{}"},
       {:error, %{"code" => "storage_unavailable"}}},
      {:get, %{"resource" => "state", "id" => "asset"},
       {:ok, 200, [:malformed], Jason.encode!(%{"schema" => "wtr.response.v1", "data" => %{}})},
       {:error, %{"code" => "storage_unavailable"}}}
    ]

    for {action, arguments, response, expected} <- cases do
      {:ok, remote} = remote(response)
      assert Remote.request(remote, @token, "workshop", action, arguments, 0) == expected
    end

    {:ok, throwing} = remote({:throw, :private})

    assert {:error, %{"code" => "storage_unavailable"}} =
             Remote.request(throwing, @token, "workshop", :authorize, %{}, 0)

    assert {:ok, %{"outcome" => "unknown", "operation_id" => @operation}} =
             Remote.request(
               throwing,
               @token,
               "workshop",
               :submit,
               %{"operation" => @operation, "request" => %{}},
               0
             )
  end

  test "closed UI actions map to the versioned HTTP contract" do
    responder = fn request ->
      if String.ends_with?(request.path, "/raw"),
        do: {:ok, 200, [{"content-type", header(request, "accept")}], ~s({"raw":true})},
        else: json(%{"ok" => true})
    end

    {:ok, remote} = remote(responder)

    cases = [
      {:events, %{"cursor" => "a+b"}, "GET", "/events?cursor=a%2Bb", nil},
      {:operations, %{"params" => %{"limit" => 25}}, "GET", "/operations?limit=25", nil},
      {:credentials, %{}, "GET", "/credentials", nil},
      {:access_audit, %{"params" => %{"cursor" => "next"}}, "GET", "/access_audit?cursor=next",
       nil},
      {:privacy, %{}, "GET", "/privacy", nil},
      {:list, %{"resource" => "observations", "params" => %{"limit" => 25}}, "GET",
       "/observations?limit=25", nil},
      {:list, %{"resource" => "notification_endpoints"}, "GET", "/notification_endpoints", nil},
      {:get, %{"resource" => "rules", "id" => "motion:one"}, "GET", "/rules/motion%3Aone", nil},
      {:arming, %{"id" => "asset"}, "GET", "/arming/asset", nil},
      {:owner_presence, %{"id" => "asset"}, "GET", "/owner_presence/asset", nil},
      {:thing_policies, %{"thing" => "asset"}, "GET", "/things/asset/policies", nil},
      {:thing_rules, %{"thing" => "asset"}, "GET", "/things/asset/rules", nil},
      {:thing_alerts, %{"thing" => "asset", "params" => %{"cursor" => "next"}}, "GET",
       "/things/asset/alerts?cursor=next", nil},
      {:thing_trips,
       %{"thing" => "asset", "params" => %{"from_at" => 1, "limit" => 25, "to_at" => 2}}, "GET",
       "/things/asset/trips?from_at=1&limit=25&to_at=2", nil},
      {:trip_summary, %{"thing" => "asset", "trip" => "trip-1"}, "GET",
       "/things/asset/trips/trip-1", nil},
      {:read_property, %{"thing" => "asset", "name" => "temperature"}, "GET",
       "/things/asset/properties/temperature", nil},
      {:raw_observation, %{"id" => "capture"}, "GET", "/observations/capture/raw", nil},
      {:raw_evidence, %{"id" => "capture"}, "GET", "/evidence/capture/raw", nil},
      {:history, %{"resource" => "state", "id" => "asset", "params" => %{"limit" => 50}}, "GET",
       "/state/asset/history?limit=50", nil},
      {:analytics, %{"query" => %{"schema" => "query"}}, "POST", "/analytics/query",
       %{"schema" => "query"}},
      {:route_history, %{"request" => %{"schema" => "route"}}, "POST", "/routes/pages",
       %{"schema" => "route"}},
      {:execute_saved_query, %{"id" => "query-1"}, "GET", "/saved_queries/query-1/execute", nil},
      {:operation, %{"id" => @operation}, "GET", "/operations/#{@operation}", nil}
    ]

    mutation_cases = [
      acknowledge_alert: "alert_acknowledgements",
      associate: "associations",
      delete_domain_data: "domain_data_deletions",
      delete_policy: "policy_deletions",
      delete_query: "saved_query_deletions",
      enroll: "enrollments",
      materialize: "materialisations",
      register_notification_endpoint: "notification_endpoints",
      revoke: "revocations",
      save_policy: "policies",
      save_query: "saved_queries",
      set_arming: "arming",
      submit: "observations",
      unregister_notification_endpoint: "notification_endpoint_deletions",
      unenroll: "unenrollments"
    ]

    cases =
      cases ++
        Enum.map(mutation_cases, fn {action, path} ->
          {action, %{"operation" => @operation, "request" => %{"action" => path}}, "POST",
           "/#{path}", %{"action" => path}}
        end)

    for {action, arguments, method, suffix, body} <- cases do
      assert {:ok, result} = Remote.request(remote, @token, "workshop", action, arguments, 0)

      if action in [:raw_observation, :raw_evidence],
        do: assert(result == ~s({"raw":true})),
        else: assert(result == %{"ok" => true})

      assert_receive {:remote_request, %{host: "service.example"}, request}
      assert request.method == method
      assert request.path == "/api/v1/scopes/workshop" <> suffix
      assert header(request, "authorization") == "Bearer " <> @token

      if body do
        assert Jason.decode!(request.body) == body
        assert header(request, "content-type") == "application/json"
      else
        assert request.body == ""
      end

      if action in Keyword.keys(mutation_cases),
        do: assert(header(request, "idempotency-key") == @operation),
        else: assert(is_nil(header(request, "idempotency-key")))
    end
  end

  test "access drives login, identity and current-credential revocation context" do
    access = access()

    responder = fn request ->
      cond do
        String.ends_with?(request.path, "/access") -> json(access)
        String.ends_with?(request.path, "/enrollments?limit=1") -> json(%{"generation" => "7"})
      end
    end

    {:ok, remote} = remote(responder)

    assert {:ok,
            %{
              "scope" => "workshop",
              "can_enroll" => true,
              "can_ingest" => true,
              "can_read_raw" => true,
              "can_manage_queries" => true
            }} = Remote.request(remote, @token, "workshop", :authorize, %{}, 0)

    assert_receive {:remote_request, _, %{path: "/api/v1/scopes/workshop/access"}}

    assert {:ok,
            %{
              "identity" => %{
                "scope" => "workshop",
                "can_enroll" => true,
                "can_ingest" => true,
                "can_read_raw" => true,
                "can_manage_queries" => true
              },
              "access" => %{
                "credential_id" => "admin",
                "principal" => "owner",
                "scope" => "workshop",
                "expires_at" => 9_999
              }
            }} = Remote.request(remote, @token, "workshop", :session_context, %{}, 0)

    assert_receive {:remote_request, _, %{path: "/api/v1/scopes/workshop/access"}}

    assert {:ok, %{"principal" => "owner", "scope" => "workshop", "expires_at" => 9_999}} =
             Remote.request(remote, @token, "workshop", :access, %{}, 0)

    assert_receive {:remote_request, _, %{path: "/api/v1/scopes/workshop/access"}}

    assert {:ok, %{"credential_id" => "admin", "expected_generation" => "7"}} =
             Remote.request(remote, @token, "workshop", :revocation_context, %{}, 0)

    assert_receive {:remote_request, _, %{path: "/api/v1/scopes/workshop/access"}}

    assert_receive {:remote_request, _,
                    %{
                      path: "/api/v1/scopes/workshop/enrollments?limit=1"
                    }}

    refute inspect(remote) =~ @token
  end

  test "wire failures preserve service errors and make mutation ambiguity explicit" do
    service_error =
      {:ok, 409, [{"content-type", "application/json"}],
       Jason.encode!(%{
         "schema" => "wtr.response.v1",
         "error" => %{
           "code" => "conflict",
           "path" => "/request",
           "outcome" => "not_committed",
           "operation_id" => @operation
         }
       })}

    {:ok, remote} = remote(service_error)

    assert {:error, %{"code" => "conflict", "outcome" => "not_committed"}} =
             Remote.request(
               remote,
               @token,
               "workshop",
               :get,
               %{
                 "resource" => "state",
                 "id" => "asset"
               },
               0
             )

    for result <- [
          {:error, :timeout},
          {:ok, 200, [{"content-type", "text/plain"}], "private"},
          {:ok, 302, [{"content-type", "application/json"}], Jason.encode!(%{})},
          {:ok, 200, [{"content-type", "application/json"}], String.duplicate("x", 4_194_305)}
        ] do
      {:ok, failed} = remote(result)

      assert {:error, %{"code" => "storage_unavailable"}} =
               Remote.request(
                 failed,
                 @token,
                 "workshop",
                 :get,
                 %{
                   "resource" => "state",
                   "id" => "asset"
                 },
                 0
               )

      assert {:ok, %{"outcome" => "unknown", "operation_id" => @operation}} =
               Remote.request(
                 failed,
                 @token,
                 "workshop",
                 :submit,
                 %{
                   "operation" => @operation,
                   "request" => %{}
                 },
                 0
               )
    end

    {:ok, crashing} = remote(:raise)

    assert {:ok, %{"outcome" => "unknown", "operation_id" => @operation}} =
             Remote.request(
               crashing,
               @token,
               "workshop",
               :submit,
               %{
                 "operation" => @operation,
                 "request" => %{}
               },
               0
             )

    assert {:error, %{"code" => "unauthorized"}} =
             Remote.request(crashing, "", "workshop", :authorize, %{}, 0)

    assert {:error, %{"code" => "unsupported"}} =
             Remote.request(crashing, @token, "workshop", :arbitrary, %{}, 0)
  end

  test "the production transport calls a loopback service without changing service semantics" do
    context = service()
    server = start_supervised!({Server, server_options(context)})
    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    assert {:ok, remote} = Remote.new(origin: "http://127.0.0.1:#{port}", allow_loopback: true)

    assert {:ok, %{"can_manage_queries" => true, "scope" => "workshop"}} =
             Remote.request(remote, context.admin, context.scope, :authorize, %{}, context.now)

    assert {:ok, %{"generation" => "0", "items" => []}} =
             Remote.request(
               remote,
               context.admin,
               context.scope,
               :thing_trips,
               %{
                 "thing" => "unknown-asset",
                 "params" => %{"from_at" => 1, "limit" => 25, "to_at" => 2}
               },
               context.now
             )

    assert {:ok, %{"outcome" => "committed", "operation_id" => operation}} =
             Remote.request(
               remote,
               context.admin,
               context.scope,
               :submit,
               %{
                 "operation" => @operation,
                 "request" => import_request()
               },
               context.now
             )

    assert operation == @operation
  end

  defp remote(responder) do
    Remote.new(
      origin: "https://service.example",
      transport: {Transport, {self(), responder}}
    )
  end

  defp transport, do: {Transport, {self(), {:error, :offline}}}

  defp access do
    %{
      "schema" => "wtr.access.v1",
      "credential_id" => "admin",
      "principal" => "owner",
      "scope" => "workshop",
      "permissions" => ~w(admin enroll ingest interact raw read),
      "expires_at" => 9_999
    }
  end

  defp json(data, status \\ 200) do
    {:ok, status, [{"content-type", "application/json; charset=utf-8"}],
     Jason.encode!(%{"schema" => "wtr.response.v1", "data" => data})}
  end

  defp json_error(code, status) do
    {:ok, status, [{"content-type", "application/json"}],
     Jason.encode!(%{"schema" => "wtr.response.v1", "error" => %{"code" => code}})}
  end

  defp header(%{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp server_options(context),
    do: [
      directory: context.directory,
      credentials: context.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> context.now end,
      poll_interval: 25
    ]
end

defmodule Wotex.Tracker.UI.RemoteMintTransportTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.UI.RemoteMintTransport

  defmodule HTTPFixture do
    def connect(scheme, host, port, options) do
      send(owner(), {:connect, scheme, host, port, options})

      if delay = Process.get(:remote_connect_delay), do: Process.sleep(delay)

      case Process.get(:remote_connect, :ok) do
        :ok -> {:ok, %{host: host}}
        {:error, reason} -> {:error, reason}
        :invalid -> :invalid
      end
    end

    def request(connection, method, path, headers, body) do
      send(owner(), {:http_request, method, path, headers, body})

      case Process.get(:remote_request_result, :ok) do
        :ok ->
          reference = make_ref()
          Process.put(:remote_reference, reference)
          {:ok, connection, reference}

        {:error, reason} ->
          {:error, connection, reason}

        :invalid ->
          :invalid
      end
    end

    def recv(connection, _bytes, timeout) do
      send(owner(), {:recv, timeout})

      case Process.get(:remote_responses, []) do
        [batch | rest] ->
          Process.put(:remote_responses, rest)
          reference = Process.get(:remote_reference)
          {:ok, connection, materialize(batch, reference)}

        {:error, reason} ->
          {:error, connection, reason, []}

        {:error, reason, responses} ->
          reference = Process.get(:remote_reference)
          {:error, connection, reason, materialize(responses, reference)}

        :invalid ->
          :invalid

        _ ->
          {:error, connection, :timeout, []}
      end
    end

    def close(_connection) do
      send(owner(), :closed)

      case Process.get(:remote_close, :ok) do
        :raise -> raise "private close defect"
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end

    defp materialize(batch, reference) do
      Enum.map(batch, fn
        {:status, status} -> {:status, reference, status}
        {:headers, headers} -> {:headers, reference, headers}
        {:data, data} -> {:data, reference, data}
        :done -> {:done, reference}
        {:error, error} -> {:error, reference, error}
      end)
    end

    defp owner, do: Process.get(:remote_owner)
  end

  setup do
    Process.put(:remote_owner, self())
    :ok
  end

  test "performs one passive verified request and assembles fragmented response" do
    Process.put(:remote_responses, [
      [{:status, 200}, {:headers, [{"content-type", "application/json"}]}],
      [{:data, "{\"ok\":"}, {:data, "true}"}, :done]
    ])

    assert {:ok, 200, [{"content-type", "application/json"}], ~s({"ok":true})} =
             RemoteMintTransport.request(
               {HTTPFixture, fn -> [:certificate] end},
               %{scheme: :https, host: "service.example", port: 443},
               request()
             )

    assert_receive {:connect, :https, "service.example", 443, options}
    assert options[:mode] == :passive
    assert options[:protocols] == [:http1]
    assert options[:transport_opts][:verify] == :verify_peer
    assert options[:transport_opts][:cacerts] == [:certificate]
    assert options[:transport_opts][:server_name_indication] == ~c"service.example"
    assert_receive {:http_request, "GET", "/api/v1/scopes/workshop/access", _, ""}
    assert_receive {:recv, timeout} when timeout in 1..1_000
    assert_receive :closed
  end

  test "bounds responses and contains transport failures while always closing" do
    for response <- [
          [[{:status, 200}, {:data, String.duplicate("x", 4_194_305)}, :done]],
          [[{:status, 200}, {:headers, List.duplicate({"x", "y"}, 65)}, :done]],
          [[{:error, :closed}]],
          {:error, :timeout}
        ] do
      Process.put(:remote_responses, response)
      assert {:error, _} = transport(request())
      assert_receive :closed
    end

    Process.put(:remote_responses, {
      :error,
      :closed,
      [{:status, 200}, {:headers, [{"content-type", "application/json"}]}, {:data, "{}"}, :done]
    })

    assert {:ok, 200, [{"content-type", "application/json"}], "{}"} = transport(request())
    assert_receive :closed

    Process.put(:remote_connect, {:error, :timeout})
    assert {:error, :timeout} = transport(request())

    Process.put(:remote_connect, {:error, %Mint.TransportError{reason: :timeout}})
    assert {:error, :timeout} = transport(request())

    Process.put(:remote_connect, {:error, %Mint.HTTPError{reason: :timeout}})
    assert {:error, :timeout} = transport(request())

    Process.put(:remote_connect, :invalid)
    assert {:error, :unavailable} = transport(request())

    Process.put(:remote_connect, :ok)
    Process.put(:remote_request_result, {:error, :timeout})
    assert {:error, :timeout} = transport(request())
    assert_receive :closed

    Process.put(:remote_request_result, :invalid)
    assert {:error, :unavailable} = transport(request())
    assert_receive :closed

    Process.put(:remote_request_result, :ok)
    Process.put(:remote_responses, :invalid)
    assert {:error, :unavailable} = transport(request())
    assert_receive :closed

    Process.put(:remote_connect_delay, 110)
    assert {:error, :timeout} = transport(%{request() | timeout_ms: 100})
    assert_receive :closed

    Process.delete(:remote_connect_delay)
    Process.put(:remote_responses, [[:done]])
    assert {:error, :response_rejected} = transport(request())
    assert_receive :closed

    Process.put(:remote_responses, {:error, :closed, [:done]})
    assert {:error, :response_rejected} = transport(request())
    assert_receive :closed

    for close <- [:raise, {:throw, :private}] do
      Process.put(:remote_close, close)
      Process.put(:remote_responses, [[{:status, 200}, :done]])
      assert {:ok, 200, [], ""} = transport(request())
      assert_receive :closed
    end

    assert {:error, :unavailable} =
             RemoteMintTransport.request(
               {HTTPFixture, fn -> [] end},
               %{scheme: :https, host: "service.example", port: 443},
               request()
             )

    for certificates <- [fn -> raise "private certificate defect" end, fn -> throw(:private) end] do
      assert {:error, :unavailable} =
               RemoteMintTransport.request(
                 {HTTPFixture, certificates},
                 %{scheme: :https, host: "service.example", port: 443},
                 request()
               )
    end
  end

  test "rejects malformed origins and requests before opening a connection" do
    for {origin, request} <- [
          {:invalid, request()},
          {%{scheme: :ftp, host: "service.example", port: 443}, request()},
          {%{scheme: :https, host: "", port: 443}, request()},
          {%{scheme: :https, host: "service.example", port: 0}, request()},
          {%{scheme: :https, host: "service.example", port: 443}, %{request() | method: "PUT"}},
          {%{scheme: :https, host: "service.example", port: 443},
           %{request() | path: "/private"}},
          {%{scheme: :https, host: "service.example", port: 443},
           %{request() | body: String.duplicate("x", 1_048_577)}},
          {%{scheme: :https, host: "service.example", port: 443}, :invalid},
          {%{scheme: :https, host: "service.example", port: 443}, %{request() | headers: [:bad]}}
        ] do
      assert {:error, :unavailable} =
               RemoteMintTransport.request(
                 {HTTPFixture, fn -> [:certificate] end},
                 origin,
                 request
               )
    end

    refute_received {:connect, _, _, _, _}
  end

  defp transport(request) do
    RemoteMintTransport.request(
      {HTTPFixture, fn -> [:certificate] end},
      %{scheme: :https, host: "service.example", port: 443},
      request
    )
  end

  defp request do
    %{
      method: "GET",
      path: "/api/v1/scopes/workshop/access",
      headers: [{"authorization", "Bearer private"}],
      body: "",
      timeout_ms: 1_000
    }
  end
end
