defmodule Wotex.Tracker.Mobile.HostTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Wotex.Tracker.Mobile.{
    Config,
    Endpoint,
    Host,
    NotificationRegistration,
    Runtime,
    SessionGate
  }

  defmodule ServiceTransport do
    @behaviour Wotex.Tracker.UI.RemoteTransport

    @impl true
    def request(agent, _authority, request) do
      Agent.get_and_update(agent, fn state ->
        response = if state[:offline], do: {:error, :offline}, else: respond(request)
        {response, Map.update!(state, :requests, fn requests -> [request | requests] end)}
      end)
    end

    defp respond(request) do
      data =
        cond do
          String.ends_with?(request.path, "/access") ->
            %{
              "schema" => "wtr.access.v1",
              "credential_id" => "mobile-credential",
              "principal" => "owner",
              "scope" => "bikes",
              "permissions" => ["read"],
              "expires_at" => 9_007_199_254_740_991
            }

          String.ends_with?(request.path, "/enrollments") ->
            %{"generation" => "0", "items" => [], "cursor" => nil}

          String.ends_with?(request.path, "/notification_endpoints") and
              request.method == "GET" ->
            %{"generation" => "0", "items" => []}

          String.ends_with?(request.path, "/notification_endpoints") and
              request.method == "POST" ->
            %{"outcome" => "committed"}

          true ->
            %{"generation" => "0", "items" => [], "cursor" => nil}
        end

      body = Jason.encode!(%{"schema" => "wtr.response.v1", "data" => data})
      {:ok, 200, [{"content-type", "application/json"}], body}
    end
  end

  defmodule SecureStore do
    def fetch(key, agent) do
      Agent.get(agent, fn state ->
        case {failed?(state, :fetch), Map.fetch(state, key)} do
          {true, _} -> {:error, :unavailable}
          {false, {:ok, value}} -> {:ok, value}
          {false, :error} -> {:error, :not_found}
        end
      end)
    end

    def put(key, value, agent) do
      Agent.get_and_update(agent, fn state ->
        if failed?(state, :put),
          do: {{:error, :unavailable}, state},
          else: {:ok, Map.put(state, key, value)}
      end)
    end

    def delete(key, agent) do
      Agent.get_and_update(agent, fn state ->
        if failed?(state, :delete),
          do: {{:error, :unavailable}, state},
          else: {:ok, Map.delete(state, key)}
      end)
    end

    defp failed?(state, operation), do: state[:failure] in [:all, operation]
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:plug)
    directory = Path.expand("_build/test/mobile-host/#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    agent = start_supervised!({Agent, fn -> %{requests: []} end})

    secure_store =
      start_supervised!(Supervisor.child_spec({Agent, fn -> %{} end}, id: :secure_store))

    capability = Config.generate_capability()
    port = port()

    options = [
      directory: directory,
      remote_origin: "https://service.example",
      port: port,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      capability: capability,
      remote_transport: {ServiceTransport, agent},
      map_pack: map_pack_document(),
      secure_store: {SecureStore, secure_store}
    ]

    {:ok, config} = Config.new(options)

    %{
      agent: agent,
      capability: capability,
      config: config,
      options: options,
      secure_store: secure_store,
      origin: config.origin,
      port: port
    }
  end

  test "serves the shared UI only inside a capability-bound loopback session", c do
    start_supervised!({Host, c.config})
    assert {:ok, {{127, 0, 0, 1}, c.port}} == Endpoint.server_info(:http)
    assert c.config.web_session == Runtime.web_session()
    assert Endpoint.config(:tracker_ui)[:map_pack] == c.config.map_pack

    assert {401, _, ""} = request(:get, c.origin <> "/sign-in", [], nil)
    assert {401, _, ""} = request(:get, c.origin <> "/assets/tracker.js", [], nil)

    assert {404, _, ""} =
             request(:get, c.origin <> "/_mobile/bootstrap/not-the-capability", [], nil)

    assert {404, _, ""} =
             request(
               :get,
               c.origin <> "/_mobile/bootstrap/" <> String.duplicate("x", 129),
               [],
               nil
             )

    {302, bootstrap_headers, bootstrap_body} =
      request(:get, c.origin <> "/_mobile/bootstrap/" <> c.capability, [], nil)

    bootstrap_cookie = cookie(bootstrap_headers)
    bootstrap_text = inspect(bootstrap_headers)
    assert bootstrap_text =~ "HttpOnly"
    assert bootstrap_text =~ "SameSite=Strict"
    refute bootstrap_text =~ c.capability
    refute bootstrap_body =~ c.capability
    assert header(bootstrap_headers, ~c"location") == "/sign-in"

    {200, sign_in_headers, sign_in} =
      request(:get, c.origin <> "/sign-in", [{~c"cookie", bootstrap_cookie}], nil)

    assert sign_in =~ "Sign in"
    assert sign_in =~ ~s(id="mob-bridge")
    refute sign_in =~ c.capability
    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, sign_in)
    sign_in_cookie = cookie(sign_in_headers)

    token = "private-remote-token"

    {302, login_headers, login_body} =
      request(
        :post,
        c.origin <> "/session",
        [{~c"cookie", sign_in_cookie}],
        URI.encode_query(%{"_csrf_token" => csrf, "scope" => "bikes", "token" => token})
      )

    refute inspect(login_headers) =~ token
    refute login_body =~ token
    browser_cookie = cookie(login_headers)

    assert {:ok, envelope} = Agent.get(c.secure_store, &Map.fetch(&1, :credential))

    assert %{"schema" => "wtr.mobile-credential.v1", "token" => ^token} =
             Jason.decode!(envelope)

    {200, asset_headers, assets} =
      request(:get, c.origin <> "/", [{~c"cookie", browser_cookie}], nil)

    asset_cookie = cookie(asset_headers)
    assert assets =~ "Your assets"
    assert assets =~ "No assets on this page"
    refute assets =~ token
    refute assets =~ c.capability

    requests = Agent.get(c.agent, & &1.requests)
    assert Enum.any?(requests, &({"authorization", "Bearer " <> token} in &1.headers))
    assert Enum.all?(requests, &String.starts_with?(&1.path, "/api/v1/scopes/bikes/"))

    {200, _, script} =
      request(:get, c.origin <> "/assets/tracker.js", [{~c"cookie", browser_cookie}], nil)

    assert script =~ "MobHook"
    assert script =~ "TargetBLEHook"
    assert script =~ ~s(hooks: { MobHook, TargetBLEHook })
    assert script =~ "wtr.mobile-share.v1"
    assert script =~ "wtr.mobile-ble-central-command.v1"
    assert script =~ "wotex:ble-central-command"
    assert script =~ "nativeMob.send"
    assert script =~ "URL.createObjectURL"

    [_, logout_csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, assets)

    {302, logout_headers, _} =
      request(
        :post,
        c.origin <> "/session/logout",
        [{~c"cookie", asset_cookie}],
        URI.encode_query(%{"_csrf_token" => logout_csrf})
      )

    signed_out_cookie = cookie(logout_headers)

    assert {200, _, signed_out} =
             request(:get, c.origin <> "/sign-in", [{~c"cookie", signed_out_cookie}], nil)

    assert signed_out =~ "Sign in"
    assert :error = Agent.get(c.secure_store, &Map.fetch(&1, :credential))
  end

  defp map_pack_document do
    %{
      "schema" => "wtr.map-pack.v1",
      "id" => "mobile-host-map",
      "revision" => "1",
      "attribution" => "Mobile host map",
      "coverage" => %{"west" => 17, "south" => 59, "east" => 19, "north" => 60},
      "features" => [%{"class" => "boundary", "points" => [[59.3, 18.0], [59.4, 18.1]]}]
    }
  end

  test "rejects foreign WebSocket origins and validates retained session digests", c do
    assert SessionGate.init(example: true) == [example: true]
    start_supervised!({Host, c.options})

    socket_headers = [
      {~c"connection", ~c"Upgrade"},
      {~c"upgrade", ~c"websocket"},
      {~c"sec-websocket-version", ~c"13"},
      {~c"sec-websocket-key", ~c"dGhlIHNhbXBsZSBub25jZQ=="},
      {~c"origin", ~c"http://foreign.example"}
    ]

    assert {403, _, _} =
             request(:get, c.origin <> "/live/websocket?vsn=2.0.0", socket_headers, nil)

    digest = c.config.capability_digest
    assert SessionGate.valid_session?(digest, %{"mobile_capability" => digest})
    refute SessionGate.valid_session?(digest, %{"mobile_capability" => <<0::256>>})
    refute SessionGate.valid_session?(digest, %{})
    refute SessionGate.valid_session?(digest, :invalid)

    assert %{"mobile_capability" => ^digest} =
             SessionGate.retained_session(digest, %{"mobile_capability" => digest})

    assert %{} = SessionGate.retained_session(digest, %{})
  end

  test "restores a secured credential and browser session after a cold host restart", c do
    start_supervised!({Host, c.config})
    {cookie, csrf} = bootstrap_sign_in(c)
    token = "restart-token"

    assert {302, login_headers, _} = sign_in(c, cookie, csrf, token)
    browser_cookie = cookie(login_headers)
    assert {200, _, body} = request(:get, c.origin <> "/", [{~c"cookie", browser_cookie}], nil)
    assert body =~ "Your assets"
    assert :ok = stop_supervised(Host)
    start_supervised!({Host, c.config})

    {302, headers, _} =
      request(:get, c.origin <> "/_mobile/bootstrap/" <> c.capability, [], nil)

    restored_cookie = cookie(headers)
    assert {200, _, body} = request(:get, c.origin <> "/", [{~c"cookie", restored_cookie}], nil)
    assert body =~ "Your assets"
    refute body =~ token
  end

  test "opens labelled cached overview data after an offline cold restart", c do
    start_supervised!({Host, c.config})
    {cookie, csrf} = bootstrap_sign_in(c)
    token = "offline-token"
    assert {302, login_headers, _} = sign_in(c, cookie, csrf, token)
    browser_cookie = cookie(login_headers)

    assert {200, _, online} =
             request(:get, c.origin <> "/", [{~c"cookie", browser_cookie}], nil)

    refute online =~ "Offline cached data"
    assert :ok = stop_supervised(Host)
    Agent.update(c.agent, &Map.put(&1, :offline, true))
    start_supervised!({Host, c.config})

    {302, bootstrap_headers, _} =
      request(:get, c.origin <> "/_mobile/bootstrap/" <> c.capability, [], nil)

    restored_cookie = cookie(bootstrap_headers)

    assert {200, _, offline} =
             request(:get, c.origin <> "/", [{~c"cookie", restored_cookie}], nil)

    assert offline =~ "Your assets"
    assert offline =~ "Offline cached data"
    assert offline =~ "complete for this request"
    refute offline =~ token
  end

  test "registers an explicitly configured push endpoint through the current session", c do
    options =
      c.options ++
        [
          notification_app_id: "org.wotex.tracker",
          notification_environment: "sandbox"
        ]

    {:ok, config} = Config.new(options)
    start_supervised!({Host, config})
    {cookie, csrf} = bootstrap_sign_in(c)
    assert {302, _, _} = sign_in(c, cookie, csrf, "notification-token")

    provider_token = String.duplicate("ab", 32)
    assert :ok = NotificationRegistration.register(NotificationRegistration, :ios, provider_token)
    assert %{state: :registered} = NotificationRegistration.status(NotificationRegistration)

    requests = Agent.get(c.agent, & &1.requests)

    registration =
      Enum.find(requests, fn request ->
        request.method == "POST" and
          String.ends_with?(request.path, "/notification_endpoints")
      end)

    assert Jason.decode!(registration.body) == %{
             "id" => Jason.decode!(registration.body)["id"],
             "provider" => "apns",
             "app_id" => "org.wotex.tracker",
             "environment" => "sandbox",
             "token" => provider_token,
             "expected_generation" => "0"
           }

    assert String.starts_with?(Jason.decode!(registration.body)["id"], "ios-")
    refute inspect(:sys.get_status(NotificationRegistration)) =~ provider_token
    refute inspect(config) =~ provider_token
  end

  test "failed secure storage keeps login atomic and logout retryable", c do
    start_supervised!({Host, c.config})
    {initial_cookie, csrf} = bootstrap_sign_in(c)
    Agent.update(c.secure_store, &Map.put(&1, :failure, :put))

    assert {401, _, failed} = sign_in(c, initial_cookie, csrf, "unstored-token")
    assert failed =~ "Sign-in failed"
    assert :error = Agent.get(c.secure_store, &Map.fetch(&1, :credential))

    Agent.update(c.secure_store, &Map.delete(&1, :failure))
    {cookie, csrf} = bootstrap_sign_in(c)
    assert {302, headers, _} = sign_in(c, cookie, csrf, "retained-token")
    browser_cookie = cookie(headers)

    {200, asset_headers, assets} =
      request(:get, c.origin <> "/", [{~c"cookie", browser_cookie}], nil)

    browser_cookie = cookie(asset_headers)
    [_, logout_csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, assets)

    Agent.update(c.secure_store, &Map.put(&1, :failure, :delete))

    {302, failed_headers, _} =
      request(
        :post,
        c.origin <> "/session/logout",
        [{~c"cookie", browser_cookie}],
        URI.encode_query(%{"_csrf_token" => logout_csrf})
      )

    assert header(failed_headers, ~c"location") == "/"
    retry_cookie = cookie(failed_headers)
    assert {:ok, _} = Agent.get(c.secure_store, &Map.fetch(&1, :credential))

    assert {200, retry_headers, retry_page} =
             request(:get, c.origin <> "/", [{~c"cookie", retry_cookie}], nil)

    assert retry_page =~ "Your assets"

    Agent.update(c.secure_store, &Map.delete(&1, :failure))
    [_, retry_csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, retry_page)
    retry_cookie = cookie(retry_headers)

    assert {302, _, _} =
             request(
               :post,
               c.origin <> "/session/logout",
               [{~c"cookie", retry_cookie}],
               URI.encode_query(%{"_csrf_token" => retry_csrf})
             )

    assert :error = Agent.get(c.secure_store, &Map.fetch(&1, :credential))
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

  defp header(headers, name) do
    headers |> List.keyfind(name, 0) |> elem(1) |> to_string()
  end

  defp bootstrap_sign_in(c) do
    {302, headers, _} =
      request(:get, c.origin <> "/_mobile/bootstrap/" <> c.capability, [], nil)

    bootstrap_cookie = cookie(headers)

    {200, sign_in_headers, body} =
      request(:get, c.origin <> "/sign-in", [{~c"cookie", bootstrap_cookie}], nil)

    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, body)
    {cookie(sign_in_headers), csrf}
  end

  defp sign_in(c, cookie, csrf, token) do
    request(
      :post,
      c.origin <> "/session",
      [{~c"cookie", cookie}],
      URI.encode_query(%{"_csrf_token" => csrf, "scope" => "bikes", "token" => token})
    )
  end

  defp request(method, url, headers, body) do
    arguments =
      if body,
        do: {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body},
        else: {String.to_charlist(url), headers}

    {:ok, {{_, status, _}, response_headers, response}} =
      :httpc.request(method, arguments, [timeout: 5_000, autoredirect: false],
        body_format: :binary
      )

    {status, response_headers, response}
  end
end
