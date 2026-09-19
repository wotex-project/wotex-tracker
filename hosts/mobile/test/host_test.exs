defmodule Wotex.Tracker.Mobile.HostTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias Wotex.Tracker.Mobile.{Config, Endpoint, Host, Runtime, SessionGate}

  defmodule ServiceTransport do
    @behaviour Wotex.Tracker.UI.RemoteTransport

    @impl true
    def request(agent, _authority, request) do
      Agent.update(agent, &Map.update!(&1, :requests, fn requests -> [request | requests] end))
      respond(request.path)
    end

    defp respond(path) do
      data =
        cond do
          String.ends_with?(path, "/access") ->
            %{
              "schema" => "wtr.access.v1",
              "credential_id" => "mobile-credential",
              "principal" => "owner",
              "scope" => "bikes",
              "permissions" => ["read"],
              "expires_at" => 9_007_199_254_740_991
            }

          String.ends_with?(path, "/enrollments") ->
            %{"generation" => "0", "items" => [], "cursor" => nil}

          true ->
            %{"generation" => "0", "items" => [], "cursor" => nil}
        end

      body = Jason.encode!(%{"schema" => "wtr.response.v1", "data" => data})
      {:ok, 200, [{"content-type", "application/json"}], body}
    end
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
    capability = Config.generate_capability()
    port = port()

    options = [
      directory: directory,
      remote_origin: "https://service.example",
      port: port,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      capability: capability,
      remote_transport: {ServiceTransport, agent}
    ]

    {:ok, config} = Config.new(options)

    %{
      agent: agent,
      capability: capability,
      config: config,
      options: options,
      origin: config.origin,
      port: port
    }
  end

  test "serves the shared UI only inside a capability-bound loopback session", c do
    start_supervised!({Host, c.config})
    assert {:ok, {{127, 0, 0, 1}, c.port}} == Endpoint.server_info(:http)
    assert c.config.web_session == Runtime.web_session()

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
    assert script =~ ~s(hooks: { MobHook })

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
  end

  test "rejects foreign WebSocket origins and validates retained session digests", c do
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
