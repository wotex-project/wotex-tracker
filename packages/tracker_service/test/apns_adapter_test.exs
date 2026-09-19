defmodule Wotex.Tracker.Service.APNsAdapterTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service

  alias Wotex.Tracker.Service.{
    APNsAdapter,
    APNsMintTransport,
    Codec,
    NotificationTarget
  }

  @p256_oid {1, 2, 840, 10_045, 3, 1, 7}

  defmodule Transport do
    @behaviour Wotex.Tracker.Service.APNsTransport

    @impl true
    def request({owner, result}, request) do
      send(owner, {:apns_request, request})

      case result do
        :raise -> raise "private transport failure"
        {:throw, reason} -> throw(reason)
        result -> result
      end
    end
  end

  defmodule HTTP2Fixture do
    def connect(scheme, host, port, options) do
      send(owner(), {:connect, scheme, host, port, options})

      case Process.get(:apns_connect, :ok) do
        :ok ->
          {:ok, %{host: host}}

        :delay ->
          Process.sleep(5)
          {:ok, %{host: host}}

        {:error, reason} ->
          {:error, reason}

        :raise ->
          raise "private connect failure"

        :throw ->
          throw(:private_connect_failure)

        :invalid ->
          :invalid
      end
    end

    def request(connection, method, path, headers, body) do
      send(owner(), {:http_request, method, path, headers, body})

      case Process.get(:apns_request_result, :ok) do
        :ok ->
          reference = make_ref()
          Process.put(:apns_reference, reference)
          {:ok, connection, reference}

        {:error, reason} ->
          {:error, connection, reason}

        :invalid ->
          :invalid
      end
    end

    def recv(connection, _bytes, _timeout) do
      case Process.get(:apns_responses, []) do
        [batch | rest] ->
          Process.put(:apns_responses, rest)
          reference = Process.get(:apns_reference)
          batch = Enum.map(batch, &reference(&1, reference))
          {:ok, connection, batch}

        {:error, reason} ->
          {:error, connection, reason, []}

        :invalid ->
          :invalid

        [] ->
          {:error, connection, :closed, []}
      end
    end

    def close(connection) do
      send(owner(), {:close, connection})

      case Process.get(:apns_close, :ok) do
        :ok -> {:ok, connection}
        :raise -> raise "private close failure"
        :throw -> throw(:private_close_failure)
      end
    end

    defp reference({kind, :request, value}, reference), do: {kind, reference, value}
    defp reference({kind, :request}, reference), do: {kind, reference}
    defp reference(value, _reference), do: value

    defp owner, do: Process.get(:apns_owner, self())
  end

  test "a sandbox request carries a verified ES256 token and only the opaque event reference" do
    c = service()
    {config, key} = config(c, {:ok, 200, [{"apns-id", "provider-id"}], ""})
    target = target(c, token: "aabbCCDDee", environment: "sandbox")
    payload = %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-1"}

    assert {:accepted, reference} = APNsAdapter.deliver(config, target, payload)
    assert Codec.id?(reference)
    assert_receive {:apns_request, request}
    assert request.host == "api.sandbox.push.apple.com"
    assert request.path == "/3/device/aabbCCDDee"
    assert request.timeout_ms == 250
    assert header(request, "apns-id") == reference
    assert header(request, "apns-topic") == "org.wotex.tracker"
    assert header(request, "apns-push-type") == "alert"
    assert header(request, "apns-priority") == "10"
    assert header(request, "apns-expiration") == "0"

    assert {:ok, body} = Codec.decode(request.body)

    assert body == %{
             "aps" => %{
               "alert" => %{
                 "title" => "WotEx alert",
                 "body" => "Open WotEx to review this alert."
               },
               "thread-id" => "wotex-alerts"
             },
             "schema" => "wtr.notification-reference.v1",
             "event_ref" => "alert-1"
           }

    authorization = header(request, "authorization")
    assert "bearer " <> jwt = authorization
    [protected, claims, signature] = String.split(jwt, ".")
    assert decode_segment(protected) == %{"alg" => "ES256", "kid" => "KEYID12345"}

    assert decode_segment(claims) == %{
             "iss" => "TEAMID1234",
             "iat" => div(c.now, 1_000)
           }

    raw = Base.url_decode64!(signature, padding: false)
    assert byte_size(raw) == 64
    <<r::unsigned-big-size(256), s::unsigned-big-size(256)>> = raw

    der =
      :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    assert :public_key.verify(protected <> "." <> claims, :sha256, der, key)
    refute request.body =~ target.token
    refute request.body =~ c.admin
    refute inspect(config) =~ "PRIVATE KEY"
    refute inspect(config) =~ Base.encode16(elem(key, 2))
  end

  test "production uses the production endpoint and permits reviewed generic copy" do
    c = service()

    {config, _key} =
      config(c, {:ok, 200, [], ""},
        title: "Asset alert",
        body: "Open the app to review.",
        topics: ["com.example.secondary", "org.wotex.tracker"]
      )

    assert {:accepted, _} =
             APNsAdapter.deliver(
               config,
               target(c, environment: "production"),
               %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-2"}
             )

    assert_receive {:apns_request, request}
    assert request.host == "api.push.apple.com"
    assert {:ok, body} = Codec.decode(request.body)

    assert body["aps"]["alert"] == %{
             "title" => "Asset alert",
             "body" => "Open the app to review."
           }
  end

  test "APNs response classes remain distinct" do
    c = service()
    target = target(c)
    payload = %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-3"}

    cases = [
      {{:ok, 400, [], ~s({"reason":"BadDeviceToken"})}, :invalid_token},
      {{:ok, 400, [], ~s({"reason":"DeviceTokenNotForTopic"})}, :invalid_token},
      {{:ok, 410, [], ~s({"reason":"Unregistered","timestamp":1700000000000})}, :invalid_token},
      {{:ok, 410, [], "malformed"}, :invalid_token},
      {{:ok, 400, [], ~s({"reason":"BadTopic"})}, :rejected},
      {{:ok, 400, [], ""}, :rejected},
      {{:ok, 403, [], ~s({"reason":"InvalidProviderToken"})}, :rejected},
      {{:ok, 429, [], ~s({"reason":"TooManyRequests"})}, {:retry, :rate_limited}},
      {{:ok, 500, [], ~s({"reason":"InternalServerError"})}, {:retry, :server_error}},
      {{:ok, 503, [], ~s({"reason":"Shutdown"})}, {:retry, :server_error}},
      {{:ok, 200, [], ~s({"unexpected":true})}, {:retry, :unavailable}},
      {{:error, :timeout}, {:retry, :timeout}},
      {{:error, :unavailable}, {:retry, :unavailable}},
      {:invalid, {:retry, :unavailable}}
    ]

    Enum.each(cases, fn {response, expected} ->
      {config, _key} = config(c, response)
      result = APNsAdapter.deliver(config, target, payload)

      case {result, expected} do
        {{status, reference}, status} when status in [:invalid_token, :rejected] ->
          assert Codec.id?(reference)

        {^expected, ^expected} ->
          :ok

        _ ->
          flunk("unexpected classification #{inspect(result)} for #{inspect(response)}")
      end
    end)
  end

  test "target and payload admission fail closed before transport" do
    c = service()
    {config, _key} = config(c, {:ok, 200, [], ""})
    valid = %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-4"}

    for invalid_target <- [
          target(c, provider: "fcm"),
          target(c, app_id: "org.other.app"),
          target(c, environment: "development"),
          target(c, token: "not-a-hex-token"),
          target(c, token: nil)
        ] do
      assert {:rejected, reference} = APNsAdapter.deliver(config, invalid_target, valid)
      assert Codec.id?(reference)
    end

    for invalid_payload <- [
          %{},
          %{"schema" => "wrong", "event_ref" => "alert-4"},
          %{"schema" => "wtr.notification-reference.v1", "event_ref" => ""},
          Map.put(valid, "private", true)
        ] do
      assert {:rejected, reference} = APNsAdapter.deliver(config, target(c), invalid_payload)
      assert Codec.id?(reference)
    end

    refute_received {:apns_request, _}
    assert {:retry, :unavailable} = APNsAdapter.deliver(:invalid, target(c), valid)
    assert {:retry, :unavailable} = APNsAdapter.deliver(config, :invalid, valid)
  end

  test "configuration rejects malformed identifiers, keys, topics and budgets" do
    c = service()
    {_config, _key, pem} = config_with_pem(c, {:ok, 200, [], ""})
    base = base_options(c, pem, {:ok, 200, [], ""})

    invalid = [
      Keyword.delete(base, :team_id),
      Keyword.put(base, :team_id, "short"),
      Keyword.put(base, :key_id, "lowercase1"),
      Keyword.put(base, :private_key, "not a pem"),
      Keyword.put(base, :topics, []),
      Keyword.put(base, :topics, ["org..wotex"]),
      Keyword.put(base, :topics, [123]),
      Keyword.put(base, :topics, ["z.topic", "a.topic"]),
      Keyword.put(base, :topics, ["org.wotex", "org.wotex"]),
      Keyword.put(base, :timeout_ms, 0),
      Keyword.put(base, :clock, :not_a_function),
      Keyword.put(base, :transport, {String, nil}),
      Keyword.put(base, :transport, :invalid),
      Keyword.put(base, :title, "bad\ncopy"),
      Keyword.put(base, :body, ""),
      Keyword.put(base, :unknown, true),
      base ++ [team_id: "DUPLICATE1"]
    ]

    Enum.each(invalid, fn options ->
      assert {:error, :invalid_configuration} = APNsAdapter.new(options)
    end)

    rsa = :public_key.generate_key({:rsa, 2_048, 65_537})
    rsa_pem = pem(:RSAPrivateKey, rsa)

    assert {:error, :invalid_configuration} =
             APNsAdapter.new(Keyword.put(base, :private_key, rsa_pem))

    assert {:error, :invalid_configuration} = APNsAdapter.validate(%{not: :a_config})
  end

  test "clock, signing and transport defects remain retryable and secret-free" do
    c = service()
    payload = %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-5"}

    for options <- [
          [clock: fn -> :invalid end],
          [clock: fn -> raise "private clock marker" end],
          [clock: fn -> exit(:private_clock_exit) end],
          [transport: {Transport, {self(), :raise}}],
          [transport: {Transport, {self(), {:throw, :private_throw}}}]
        ] do
      {config, _key} = config(c, {:ok, 200, [], ""}, options)
      assert {:retry, :unavailable} = APNsAdapter.deliver(config, target(c), payload)
    end

    {config, _key} = config(c, {:ok, 200, [], ""})
    damaged = %{config | private_key: :damaged}
    assert {:error, :invalid_configuration} = APNsAdapter.validate(damaged)
    assert {:retry, :unavailable} = APNsAdapter.deliver(damaged, target(c), payload)

    {_configured, _key, pem} = config_with_pem(c, {:ok, 200, [], ""})
    defaults = base_options(c, pem, {:ok, 200, [], ""}) |> Keyword.delete(:clock)
    assert {:ok, default_clock} = APNsAdapter.new(defaults)
    assert {:accepted, _} = APNsAdapter.deliver(default_clock, target(c), payload)
  end

  test "the Mint transport bounds and assembles one passive HTTP/2 response" do
    Process.put(:apns_owner, self())
    reference = make_ref()
    Process.put(:apns_reference, reference)

    Process.put(:apns_responses, [
      [{:status, :request, 200}],
      [
        {:headers, :request, [{"apns-id", "request-1"}]},
        {:data, :request, ""},
        {:done, :request}
      ]
    ])

    assert {:ok, 200, [{"apns-id", "request-1"}], ""} =
             APNsMintTransport.request(HTTP2Fixture, mint_request())

    assert_receive {:connect, :https, "api.sandbox.push.apple.com", 443, options}
    assert options[:mode] == :passive
    assert options[:log] == false
    assert options[:client_settings] == [enable_push: false]
    assert options[:transport_opts][:send_timeout_close]

    assert_receive {:http_request, "POST", "/3/device/aabb", headers, "{}"}
    assert {"authorization", "bearer fixture"} in headers
    assert_receive {:close, %{host: "api.sandbox.push.apple.com"}}
  end

  test "the Mint transport rejects malformed and excessive responses" do
    Process.put(:apns_owner, self())
    Process.put(:apns_reference, make_ref())

    cases = [
      {[[{:status, :request, 200}, {:data, :request, String.duplicate("x", 4_097)}]],
       :response_rejected},
      {[[{:status, :request, 200}, {:headers, :request, List.duplicate({"x", "y"}, 33)}]],
       :response_rejected},
      {[[{:status, :request, 200}, {:status, :request, 200}]], :response_rejected},
      {[[{:done, :request}]], :response_rejected},
      {[[{:error, :request, :closed}]], :unavailable},
      {[[{:unknown, :request, :value}]], :response_rejected},
      {{:error, :timeout}, :timeout},
      {:invalid, :unavailable}
    ]

    Enum.each(cases, fn {responses, expected} ->
      Process.put(:apns_responses, responses)
      assert {:error, ^expected} = APNsMintTransport.request(HTTP2Fixture, mint_request())
    end)

    Process.put(:apns_connect, {:error, %Mint.TransportError{reason: :timeout}})
    assert {:error, :timeout} = APNsMintTransport.request(HTTP2Fixture, mint_request())
    Process.put(:apns_connect, :invalid)
    assert {:error, :unavailable} = APNsMintTransport.request(HTTP2Fixture, mint_request())
  end

  test "the Mint transport rejects invalid requests, clients and request failures" do
    Process.put(:apns_owner, self())
    request = mint_request()

    for invalid <- [
          %{request | host: "example.test"},
          %{request | path: "/wrong"},
          %{request | body: ""},
          %{request | body: String.duplicate("x", 4_097)},
          %{request | headers: List.duplicate({"x", "y"}, 33)},
          %{request | timeout_ms: 0}
        ] do
      assert {:error, :unavailable} = APNsMintTransport.request(HTTP2Fixture, invalid)
    end

    assert {:error, :unavailable} = APNsMintTransport.request(String, request)
    assert {:error, :unavailable} = APNsMintTransport.request(nil, :invalid)

    Process.put(:apns_request_result, {:error, %Mint.TransportError{reason: :timeout}})
    assert {:error, :timeout} = APNsMintTransport.request(HTTP2Fixture, request)
    Process.put(:apns_request_result, :invalid)
    assert {:error, :unavailable} = APNsMintTransport.request(HTTP2Fixture, request)

    Process.put(:apns_request_result, :ok)
    Process.put(:apns_responses, [[{:status, :request, 200}, {:done, :request}]])
    Process.put(:apns_close, :raise)
    assert {:ok, 200, [], ""} = APNsMintTransport.request(HTTP2Fixture, request)
    Process.put(:apns_close, :throw)
    Process.put(:apns_responses, [[{:status, :request, 200}, {:done, :request}]])
    assert {:ok, 200, [], ""} = APNsMintTransport.request(HTTP2Fixture, request)

    Process.put(:apns_close, :ok)
    Process.put(:apns_connect, {:error, :connection_refused})
    assert {:error, :unavailable} = APNsMintTransport.request(HTTP2Fixture, request)
    Process.put(:apns_connect, {:error, %Mint.HTTPError{reason: :timeout}})
    assert {:error, :timeout} = APNsMintTransport.request(HTTP2Fixture, request)
    Process.put(:apns_connect, :raise)
    assert {:error, :unavailable} = APNsMintTransport.request(HTTP2Fixture, request)
    Process.put(:apns_connect, :throw)
    assert {:error, :unavailable} = APNsMintTransport.request(HTTP2Fixture, request)

    Process.put(:apns_connect, :delay)

    assert {:error, :timeout} =
             APNsMintTransport.request(HTTP2Fixture, %{request | timeout_ms: 1})
  end

  defp config(c, result, changes \\ []) do
    {config, key, _pem} = config_with_pem(c, result, changes)
    {config, key}
  end

  defp config_with_pem(c, result, changes \\ []) do
    key = :public_key.generate_key({:namedCurve, @p256_oid})
    private_pem = pem(:PrivateKeyInfo, key)
    options = Keyword.merge(base_options(c, private_pem, result), changes)
    assert {:ok, config} = APNsAdapter.new(options)
    {config, key, private_pem}
  end

  defp base_options(c, private_pem, result),
    do: [
      team_id: "TEAMID1234",
      key_id: "KEYID12345",
      private_key: private_pem,
      topics: ["org.wotex.tracker"],
      timeout_ms: 250,
      clock: fn -> c.now end,
      transport: {Transport, {self(), result}}
    ]

  defp target(c, changes \\ []) do
    assert {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now)

    struct!(
      NotificationTarget,
      Keyword.merge(
        [
          scope: c.scope,
          internal_id: "endpoint-internal",
          id: "phone",
          provider: "apns",
          app_id: "org.wotex.tracker",
          environment: "sandbox",
          revision: "notification-endpoint-1",
          token: "aabbccdd",
          access: access
        ],
        changes
      )
    )
  end

  defp pem(type, key) do
    entry = :public_key.pem_entry_encode(type, key)
    :public_key.pem_encode([entry])
  end

  defp header(request, name), do: request.headers |> Map.new() |> Map.fetch!(name)

  defp decode_segment(segment) do
    segment
    |> Base.url_decode64!(padding: false)
    |> Codec.decode!()
  end

  defp mint_request,
    do: %{
      host: "api.sandbox.push.apple.com",
      path: "/3/device/aabb",
      headers: [{"authorization", "bearer fixture"}],
      body: "{}",
      timeout_ms: 100
    }
end
