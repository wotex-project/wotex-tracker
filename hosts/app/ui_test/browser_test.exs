defmodule Wotex.Tracker.Host.BrowserTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Host.BrowserConfig
  alias Wotex.Tracker.Host.Supervisor, as: HostSupervisor
  alias Wotex.Tracker.Host.Browser.Endpoint
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

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "browser-host-test",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "owner",
            principal: "owner",
            token_sha256: digest,
            grants: %{"workshop" => ~w(read ingest enroll)},
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

    %{directory: directory, token: token, service_options: service_options}
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
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))
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
    refute analytics =~ c.token

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
