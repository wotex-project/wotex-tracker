defmodule Wotex.Tracker.Mobile.DevelopmentSimulatorTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Wotex.Mobile.SecureStore

  alias Wotex.Tracker.Mobile.{Config, NativeAdapters, WebSession}

  alias Wotex.Tracker.Mobile.Development.{
    NativeSimulator,
    RemoteService,
    ScreenSimulator,
    Simulator
  }

  @authority %{scheme: :https, host: "mobile-simulator.invalid", port: 443}

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:plug)

    directory =
      Path.expand("_build/test/mobile-simulator/#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory}
  end

  test "boots the real mobile host around deterministic native and service peers", c do
    assert {:ok, port} = Simulator.available_port()
    start_supervised!({Simulator, directory: c.directory, port: port})

    assert %{
             bootstrap_url: bootstrap_url,
             origin: origin,
             scope: "workshop",
             token: "development-token"
           } = Simulator.connection()

    assert String.starts_with?(bootstrap_url, origin <> "/_mobile/bootstrap/")
    assert %{type: :web_view, props: %{url: ^bootstrap_url}} = ScreenSimulator.render()

    eventually(fn ->
      status = Simulator.status()

      status.screen.notification_permission == :granted and
        status.screen.push_registration and status.native.subscriber_count == 1
    end)

    {302, bootstrap_headers, _} = request(:get, bootstrap_url, [], nil)
    bootstrap_cookie = cookie(bootstrap_headers)

    {200, sign_in_headers, sign_in} =
      request(:get, origin <> "/sign-in", [{~c"cookie", bootstrap_cookie}], nil)

    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, sign_in)

    {302, _, _} =
      request(
        :post,
        origin <> "/session",
        [{~c"cookie", cookie(sign_in_headers)}],
        URI.encode_query(%{
          "_csrf_token" => csrf,
          "scope" => "workshop",
          "token" => "development-token"
        })
      )

    eventually(fn ->
      status = Simulator.status()

      status.credentials.credential and status.credentials.session and
        status.notifications.state == :registered and status.remote.endpoint_count == 1
    end)

    assert :ok = Simulator.exercise()

    eventually(fn ->
      status = Simulator.status()
      effects = status.native.effects

      status.screen.app == :active and status.screen.network == :online and
        status.screen.shared and status.screen.webview_effect and
        Enum.all?(
          ~w(ble_scan ble_stop_scan ble_connect ble_disconnect ble_discover ble_read ble_write)a,
          &(effects[&1] == 1)
        ) and effects.webview_script >= 10 and effects.external_url == 1 and
        effects.share == 1 and effects.emitted_event == 5
    end)

    status = Simulator.status()
    assert status.native.secure_slots == ~w(credential installation_id)
    refute inspect(status) =~ "development-token"
    refute inspect(status) =~ "development-apns-token"
    refute inspect(status) =~ bootstrap_url
  end

  test "the native peer implements the exact secure, event and effect callbacks" do
    assert %{mode: :development, state: :unavailable} = NativeSimulator.status()
    assert {:error, :invalid_event} = NativeSimulator.emit(:online)
    assert {:error, :invalid_configuration} = NativeSimulator.start_link(unknown: true)
    assert {:error, :invalid_configuration} = NativeSimulator.start_link(:invalid)

    start_supervised!(NativeSimulator)

    assert {:ok, %NativeAdapters{mode: :development}} = NativeAdapters.development()
    assert %NativeAdapters{mode: :production} = NativeAdapters.production()

    assert {:error, :not_found} = SecureStore.fetch(:credential, NativeSimulator)
    assert :ok = SecureStore.put(:credential, "opaque", NativeSimulator)
    assert {:ok, "opaque"} = SecureStore.fetch(:credential, NativeSimulator)
    assert :ok = SecureStore.delete(:credential, NativeSimulator)
    assert {:error, :not_found} = SecureStore.fetch(:credential, NativeSimulator)

    assert {:error, :unavailable} = NativeSimulator.fetch("other")
    assert {:error, :unavailable} = NativeSimulator.put("other", "value")
    assert {:error, :unavailable} = NativeSimulator.delete("other")
    assert {:error, :unavailable} = NativeSimulator.subscribe([:location])
    assert :ok = NativeSimulator.subscribe([:app, :network])
    assert :ok = NativeSimulator.subscribe([:app, :network])

    for {event, message} <- [
          {:offline, {:mob_device, :connectivity_changed, %{online: false}}},
          {:online, {:mob_device, :connectivity_changed, %{online: true}}},
          {:background, {:mob_device, :did_enter_background}},
          {:active, {:mob_device, :did_become_active}}
        ] do
      assert :ok = NativeSimulator.emit(event)
      assert_receive ^message
    end

    assert :ok = NativeSimulator.emit({:notification, "alert/one"})

    assert_receive {:notification,
                    %{data: %{schema: "wtr.notification-reference.v1", event_ref: "alert/one"}}}

    for invalid <- [nil, {:notification, ""}, {:notification, <<255>>}] do
      assert {:error, :invalid_event} = NativeSimulator.emit(invalid)
    end

    socket = Mob.Socket.new(Wotex.Tracker.Mobile.MobScreen)
    assert %Mob.Socket{} = NativeSimulator.request(socket, :notifications)
    assert_receive {:permission, :notifications, :granted}
    assert NativeSimulator.request(socket, :location) == socket

    assert %Mob.Socket{} = NativeSimulator.register_push(socket)
    assert_receive {:push_token, :ios, "development-apns-token"}
    assert NativeSimulator.register_push(:invalid) == :invalid

    assert %Mob.Socket{} = NativeSimulator.text(socket, "share")
    assert NativeSimulator.text(socket, nil) == socket
    assert %Mob.Socket{} = NativeSimulator.eval_js(socket, "script")
    assert NativeSimulator.eval_js(socket, nil) == socket
    assert :ok = NativeSimulator.open_url("https://example.com")
    assert {:error, :unavailable} = NativeSimulator.open_url(nil)

    subscriber =
      spawn(fn ->
        NativeSimulator.subscribe([:app, :network])
      end)

    monitor = Process.monitor(subscriber)
    assert_receive {:DOWN, ^monitor, :process, ^subscriber, _}
    eventually(fn -> NativeSimulator.status().subscriber_count == 1 end)

    send(Process.whereis(NativeSimulator), {:DOWN, make_ref(), :process, self(), :normal})
    send(Process.whereis(NativeSimulator), :ignored)

    status = NativeSimulator.status()
    assert status.effects.subscription == 3
    assert status.effects.share == 1
    refute inspect(status) =~ "opaque"
    refute inspect(status) =~ ~s("share")

    assert %{state: :redacted, message: :redacted, log: []} =
             NativeSimulator.format_status(%{state: :secret, message: :secret, log: [:secret]})
  end

  test "the native BLE peer emits the fixed finite central scenario" do
    start_supervised!(NativeSimulator)
    request = "123e4567-e89b-42d3-a456-426614174000"
    peripheral = "123e4567-e89b-12d3-a456-426614174000"

    assert :ok = NativeSimulator.scan(request, ["180a"], 1_000)
    assert_receive {:ble_central, ^request, :scan_result, {^peripheral, _, -42, ["180a"]}}
    assert_receive {:ble_central, ^request, :scan_complete, nil}

    assert :ok = NativeSimulator.stop_scan(request)
    assert_receive {:ble_central, ^request, :scan_stopped, nil}
    assert :ok = NativeSimulator.connect(request, peripheral)
    assert_receive {:ble_central, ^request, :connected, ^peripheral}
    assert :ok = NativeSimulator.disconnect(request, peripheral)
    assert_receive {:ble_central, ^request, :disconnected, ^peripheral}

    assert :ok = NativeSimulator.discover(request, peripheral, ["180a"])
    assert_receive {:ble_central, ^request, :services, {^peripheral, ["180a"]}}

    assert_receive {:ble_central, ^request, :characteristics,
                    {^peripheral, "180a", [{"2a29", [:read, :write]}]}}

    assert_receive {:ble_central, ^request, :discovery_complete, nil}

    assert :ok = NativeSimulator.read(request, peripheral, "180a", "2a29")
    assert_receive {:ble_central, ^request, :value, {^peripheral, "180a", "2a29", <<1, 2>>}}

    assert :ok = NativeSimulator.write(request, peripheral, "180a", "2a29", <<3, 4>>)
    assert_receive {:ble_central, ^request, :written, {^peripheral, "180a", "2a29", <<3, 4>>}}

    eventually(fn -> map_size(NativeSimulator.status().effects) == 7 end)
    refute inspect(NativeSimulator.status()) =~ Base.encode16(<<3, 4>>)
  end

  test "the remote peer admits one development authority and bounded mutations" do
    assert %{mode: :development, state: :unavailable} = RemoteService.status()
    assert {:error, :offline} = RemoteService.request(:missing, @authority, %{})
    assert {:error, :invalid_configuration} = RemoteService.start_link(unknown: true)
    assert {:error, :invalid_configuration} = RemoteService.start_link(:invalid)

    start_supervised!(RemoteService)
    base = remote_request("GET", "access", "")

    assert {200, %{"data" => %{"schema" => "wtr.access.v1"}}} = remote(base)

    unauthorized = %{base | headers: [{"authorization", "Bearer wrong"}]}
    assert {401, %{"error" => %{"code" => "unauthorized"}}} = remote(unauthorized)

    duplicate = %{
      base
      | headers: [
          {"authorization", "Bearer development-token"},
          {"authorization", "Bearer development-token"}
        ]
    }

    assert {401, _} = remote(duplicate)

    assert {:ok, 400, _, _} =
             RemoteService.request(RemoteService, %{scheme: :http}, base)

    assert {404, _} = remote(%{base | path: "/foreign"})
    assert {400, _} = remote(Map.delete(base, :body))

    endpoint = %{
      "id" => "ios-development",
      "provider" => "apns",
      "app_id" => "org.wotex.tracker",
      "environment" => "sandbox",
      "token" => "not-retained",
      "expected_generation" => "0"
    }

    assert {200, %{"data" => %{"outcome" => "committed"}}} =
             remote(remote_request("POST", "notification_endpoints", Jason.encode!(endpoint)))

    assert RemoteService.status().endpoint_count == 1
    refute inspect(RemoteService.status()) =~ endpoint["token"]

    assert {200, %{"data" => %{"items" => [stored]}}} =
             remote(remote_request("GET", "notification_endpoints", ""))

    assert stored == Map.take(endpoint, ~w(id provider app_id environment))

    assert {200, _} =
             remote(
               remote_request(
                 "POST",
                 "notification_endpoint_deletions",
                 Jason.encode!(%{"id" => endpoint["id"]})
               )
             )

    assert RemoteService.status().endpoint_count == 0
    assert {400, _} = remote(remote_request("POST", "notification_endpoints", "{}"))
    assert {200, _} = remote(remote_request("POST", "other", "{}"))
    assert {400, _} = remote(remote_request("DELETE", "other", ""))
    assert {200, %{"data" => %{"items" => []}}} = remote(remote_request("GET", "things", ""))

    assert %{state: :redacted, message: :redacted, log: []} =
             RemoteService.format_status(%{state: :secret, message: :secret, log: [:secret]})
  end

  test "simulator and root-screen configuration fail closed", c do
    assert {:error, :invalid_configuration} = Simulator.start_link([])
    assert {:error, :invalid_configuration} = Simulator.start_link(:invalid)
    assert {:error, :invalid_configuration} = Simulator.start_link(directory: "relative")

    assert {:error, :invalid_configuration} =
             Simulator.start_link(directory: c.directory, port: 0)

    assert {:error, :invalid_configuration} =
             Simulator.start_link(directory: c.directory, unknown: true)

    assert {:error, :invalid_configuration} =
             Simulator.start_link(directory: c.directory, directory: c.directory)

    File.chmod!(c.directory, 0o755)
    assert {:error, :invalid_configuration} = Simulator.start_link(directory: c.directory)
    File.chmod!(c.directory, 0o700)

    assert {:ok, port} = Simulator.available_port()
    assert port in 1..65_535
    assert {:error, :unavailable} = Simulator.connection()
    assert %{state: :unavailable} = ScreenSimulator.status()
    assert {:error, :unavailable} = ScreenSimulator.message(%{})

    assert {:error, :invalid_configuration} = ScreenSimulator.start_link([])
    assert {:error, :invalid_configuration} = ScreenSimulator.start_link(:invalid)

    capability = Config.generate_capability()
    assert {:ok, session} = WebSession.new("http://127.0.0.1:#{port}", capability)

    assert {:error, :invalid_configuration} =
             ScreenSimulator.start_link(session: session, bad: true)

    assert %{state: :redacted, message: :redacted, log: []} =
             ScreenSimulator.format_status(%{state: :secret, message: :secret, log: [:secret]})
  end

  defp remote_request(method, resource, body) do
    %{
      method: method,
      path: "/api/v1/scopes/workshop/#{resource}",
      headers: [{"authorization", "Bearer development-token"}],
      body: body,
      timeout_ms: 1_000
    }
  end

  defp remote(request) do
    assert {:ok, status, [{"content-type", "application/json"}], body} =
             RemoteService.request(RemoteService, @authority, request)

    {status, Jason.decode!(body)}
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

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, attempts) do
    if function.() do
      :ok
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end
end
