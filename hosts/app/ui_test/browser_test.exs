defmodule Wotex.Tracker.Host.BrowserTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Host.BrowserConfig
  alias Wotex.Tracker.Host.PromptConfig
  alias Wotex.Tracker.Host.Supervisor, as: HostSupervisor
  alias Wotex.Tracker.Host.Browser.{Client, Endpoint}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Codec, Credentials, Identifier}
  alias Wotex.Tracker.Service.HTTP.{Config, Server}
  alias Wotex.Tracker.UI.Presenter

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    directory = Path.expand("_build/test/browser/#{Identifier.uuid()}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)
    reader_token = Credentials.generate_token()
    {:ok, reader_digest} = Credentials.token_digest(reader_token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "browser-host-test",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "owner",
            principal: "owner",
            token_sha256: digest,
            grants: %{"workshop" => ~w(read ingest enroll admin)},
            expires_at: System.system_time(:millisecond) + 60_000
          },
          %{
            id: "reader",
            principal: "reader",
            token_sha256: reader_digest,
            grants: %{"workshop" => ~w(read)},
            expires_at: System.system_time(:millisecond) + 60_000
          }
        ]
      })

    service_options = [
      directory: directory,
      credentials: credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback
    ]

    %{
      directory: directory,
      token: token,
      reader_token: reader_token,
      service_options: service_options
    }
  end

  test "operational history rejects malformed requests and failed service providers before collector access" do
    no_collector = fn -> flunk("a denied request reached the collector") end
    now = System.system_time(:millisecond)

    assert {:error, %{"code" => "invalid_request"}} =
             Client.request(
               {no_collector, no_collector},
               "private-token",
               "workshop",
               :operational_history,
               %{},
               now
             )

    for provider <- [
          fn -> {:error, :storage_unavailable} end,
          fn -> raise "private provider detail" end,
          fn -> exit(:private_provider_detail) end
        ] do
      assert {:error, %{"code" => "storage_unavailable"}} =
               Client.request(
                 {provider, no_collector},
                 "private-token",
                 "workshop",
                 :operational_history,
                 %{"event" => nil, "cursor" => nil},
                 now
               )
    end
  end

  test "optional browser composition serves local assets, authenticates over HTTP and rejects foreign WebSocket origins",
       c do
    port = port()
    origin = "http://127.0.0.1:#{port}"

    browser = %BrowserConfig{
      ip: {127, 0, 0, 1},
      port: port,
      public_origin: origin,
      exposure: :loopback,
      tls: nil,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      prompt: %PromptConfig{
        endpoint: "https://api.openai.com/v1/responses",
        model: "gpt-5-mini",
        api_key: "sk-test-private-placeholder",
        timeout_ms: 5_000,
        max_request_bytes: 8_192,
        max_response_bytes: 16_384,
        max_output_tokens: 512,
        max_concurrent: 2,
        max_requests_per_minute: 12,
        max_cost_micro_usd: 10_000,
        input_price_micro_usd_per_million: 250_000,
        output_price_micro_usd_per_million: 2_000_000
      }
    }

    host = start_supervised!({HostSupervisor, service: c.service_options, browser: browser})
    {:ok, api} = Server.child(host, Server)
    {:ok, config} = Config.new(c.service_options)
    {:ok, service} = Server.context(api, config)
    assert {:ok, {{127, 0, 0, 1}, ^port}} = Endpoint.server_info(:http)

    {:ok, document} = File.read!("priv/examples/ruuvi-raw-v2.observation.json") |> Codec.decode()

    {:ok, imported} =
      Service.submit(
        service,
        c.token,
        "workshop",
        Identifier.uuid(),
        %{"observation" => document, "expected_generation" => "0"},
        System.system_time(:millisecond)
      )

    observation = imported["data"]["observation_id"]

    {:ok, enrolled} =
      Service.enroll(
        service,
        c.token,
        "workshop",
        Identifier.uuid(),
        %{
          "observation_id" => observation,
          "title" => "Workshop sensor",
          "owner_confirmed" => true,
          "expected_generation" => "1"
        },
        System.system_time(:millisecond)
      )

    thing = enrolled["data"]["thing_id"]

    {200, headers, body} = request(:get, origin <> "/sign-in", [], nil)
    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, body)
    cookie = cookie(headers)
    assert to_string(elem(List.keyfind(headers, ~c"set-cookie", 0), 1)) =~ "HttpOnly"
    refute to_string(elem(List.keyfind(headers, ~c"set-cookie", 0), 1)) =~ "; secure"

    {302, logged_in_headers, _} =
      request(
        :post,
        origin <> "/session",
        [{~c"cookie", cookie}],
        URI.encode_query(%{"_csrf_token" => csrf, "scope" => "workshop", "token" => c.token})
      )

    refute inspect(logged_in_headers) =~ c.token

    browser_cookie = cookie(logged_in_headers)

    {200, _, operations} =
      request(:get, origin <> "/operations", [{~c"cookie", browser_cookie}], nil)

    assert operations =~ "Operational history"
    assert operations =~ "Collector epoch"
    refute operations =~ c.token
    refute operations =~ browser.prompt.api_key

    {200, _, access_page} =
      request(:get, origin <> "/access", [{~c"cookie", browser_cookie}], nil)

    assert access_page =~ "Access and session"
    assert access_page =~ "owner"
    refute access_page =~ c.token
    refute access_page =~ browser.prompt.api_key

    {200, _, protection} =
      request(:get, origin <> "/protection", [{~c"cookie", browser_cookie}], nil)

    assert protection =~ "Tracking rules"
    assert protection =~ "No rule status on this page"
    refute protection =~ c.token

    {200, _, rule_form} =
      request(
        :get,
        origin <> Presenter.path(:asset, thing) <> "/protection",
        [{~c"cookie", browser_cookie}],
        nil
      )

    {200, _, alerts} =
      request(:get, origin <> "/protection/alerts", [{~c"cookie", browser_cookie}], nil)

    assert alerts =~ "No alerts on this page"
    refute alerts =~ c.token

    assert rule_form =~ "Add a rule for Workshop sensor"
    assert rule_form =~ "Provision this asset before adding a rule"
    refute rule_form =~ c.token

    host_client = {fn -> {:ok, service} end, fn -> {:ok, api} end}

    assert {:error, %{"code" => "forbidden"}} =
             Client.request(
               host_client,
               c.reader_token,
               "workshop",
               :operational_history,
               %{"event" => nil, "cursor" => nil},
               System.system_time(:millisecond)
             )

    {302, setup_headers, _} =
      request(:get, origin <> "/setup", [{~c"cookie", browser_cookie}], nil)

    setup_path = setup_headers |> List.keyfind(~c"location", 0) |> elem(1) |> to_string()
    assert setup_path =~ "/setup?operation="

    {200, _, setup} =
      request(:get, origin <> setup_path, [{~c"cookie", browser_cookie}], nil)

    assert setup =~ "Inspect observation"
    assert setup =~ "Import an observation capture"
    refute setup =~ c.token

    {200, _, picker} =
      request(
        :get,
        origin <> Presenter.path(:asset, thing) <> "/observations",
        [{~c"cookie", browser_cookie}],
        nil
      )

    assert picker =~ "Choose an observation for Workshop sensor"
    assert picker =~ "Inspect observation"

    {302, association_headers, _} =
      request(
        :get,
        origin <> Presenter.association_path(thing, observation),
        [{~c"cookie", browser_cookie}],
        nil
      )

    association_path =
      association_headers |> List.keyfind(~c"location", 0) |> elem(1) |> to_string()

    assert association_path =~ "?operation="

    {200, _, association} =
      request(:get, origin <> association_path, [{~c"cookie", browser_cookie}], nil)

    assert association =~ "Confirm association"
    refute association =~ c.token

    {:ok, _} =
      Service.materialize(
        service,
        c.token,
        "workshop",
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => "2"},
        System.system_time(:millisecond)
      )

    {200, _, analytics} =
      request(
        :get,
        origin <> Presenter.path(:asset, thing) <> "/analytics",
        [{~c"cookie", browser_cookie}],
        nil
      )

    assert analytics =~ "Workshop sensor analytics"
    assert analytics =~ "Run query"
    assert analytics =~ "Graph view"
    assert analytics =~ "Ask for a graph"
    refute analytics =~ c.token
    refute analytics =~ browser.prompt.api_key

    {:ok, %{"value" => state}} =
      Service.get(service, c.token, "workshop", "state", thing, System.system_time(:millisecond))

    observed_at = state["observed_at"]["value"]

    {:ok, spec} =
      QuerySpec.new(%{
        id: "browser-host-query",
        revision: "service-query-v1",
        dataset: :measurements,
        measurement: "temperature",
        unit: "Cel",
        series: [thing],
        qualities: [:valid],
        from_at: observed_at - 3_600_000,
        to_at: observed_at + 1,
        timezone: "Etc/UTC",
        bucket_ms: 3_600_000,
        aggregation: :mean,
        order: :ascending,
        max_points: 2
      })

    {:ok, query} = QuerySpec.to_map(spec)

    {:ok, _} =
      Service.save_query(
        service,
        c.token,
        "workshop",
        Identifier.uuid(),
        %{
          "id" => "browser-host-dashboard",
          "title" => "Host temperature",
          "query" => query,
          "visualization" => %{"type" => "line", "show_legend" => true, "show_points" => true},
          "expected_generation" => "3"
        },
        System.system_time(:millisecond)
      )

    {200, _, dashboards} =
      request(:get, origin <> "/dashboards", [{~c"cookie", browser_cookie}], nil)

    assert dashboards =~ "Host temperature"
    assert dashboards =~ Presenter.dashboard_path("browser-host-dashboard")

    {200, _, dashboard} =
      request(
        :get,
        origin <> Presenter.dashboard_path("browser-host-dashboard"),
        [{~c"cookie", browser_cookie}],
        nil
      )

    assert dashboard =~ "Run saved query"
    refute dashboard =~ c.token

    for path <- [
          "/assets/tracker.js",
          "/assets/tracker.css",
          "/assets/phoenix/phoenix.min.js",
          "/assets/liveview/phoenix_live_view.min.js"
        ] do
      assert {200, _, bytes} = request(:get, origin <> path, [], nil)
      assert byte_size(bytes) > 100
    end

    socket_headers = [
      {~c"connection", ~c"Upgrade"},
      {~c"upgrade", ~c"websocket"},
      {~c"sec-websocket-version", ~c"13"},
      {~c"sec-websocket-key", ~c"dGhlIHNhbXBsZSBub25jZQ=="},
      {~c"origin", ~c"http://foreign.example"}
    ]

    assert {403, _, _} = request(:get, origin <> "/live/websocket?vsn=2.0.0", socket_headers, nil)
  end

  test "a declared HTTPS proxy origin makes browser cookies Secure on the internal HTTP listener",
       c do
    port = port()

    browser = %BrowserConfig{
      ip: {127, 0, 0, 1},
      port: port,
      public_origin: "https://tracker.example",
      exposure: :proxy,
      tls: nil,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
    }

    start_supervised!({HostSupervisor, service: c.service_options, browser: browser})
    {200, headers, _} = request(:get, "http://127.0.0.1:#{port}/sign-in", [], nil)

    set_cookie =
      headers |> List.keyfind(~c"set-cookie", 0) |> elem(1) |> to_string() |> String.downcase()

    assert set_cookie =~ "; secure"
    assert set_cookie =~ "samesite=strict"
  end

  defp port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp cookie(headers) do
    headers
    |> List.keyfind(~c"set-cookie", 0)
    |> elem(1)
    |> to_string()
    |> String.split(";")
    |> hd()
    |> String.to_charlist()
  end

  defp request(method, url, headers, body) do
    args =
      if body,
        do: {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body},
        else: {String.to_charlist(url), headers}

    {:ok, {{_, code, _}, response_headers, response}} =
      :httpc.request(method, args, [timeout: 5000, autoredirect: false], body_format: :binary)

    {code, response_headers, response}
  end
end
