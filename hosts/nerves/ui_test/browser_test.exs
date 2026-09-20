defmodule Wotex.Tracker.Nerves.BrowserTest do
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Nerves.Application, as: HostApplication
  alias Wotex.Tracker.Nerves.Browser.Client
  alias Wotex.Tracker.Nerves.Browser.DeviceSession
  alias Wotex.Tracker.Nerves.Browser.DeviceSessionPlug
  alias Wotex.Tracker.Nerves.Browser.Endpoint
  alias Wotex.Tracker.Nerves.BrowserProvisioning
  alias Wotex.Tracker.Nerves.BrowserConfig
  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.Server

  setup do
    {:ok, _} = Application.ensure_all_started(:wotex_tracker_ui)
    root = Path.expand("_build/test/pi_browser/#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    data = Path.join(root, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    service = %{
      "schema" => "wtr.host.v1",
      "instance_id" => "pi-browser-test",
      "secret_key" => Base.encode64(:crypto.strong_rand_bytes(32)),
      "data_directory" => data,
      "listen" => %{"ip" => "127.0.0.1", "port" => 0},
      "exposure" => "loopback",
      "public_origin" => "listener",
      "credentials" => [
        %{
          "id" => "operator",
          "principal" => "owner",
          "token_sha256" => digest,
          "grants" => %{"workshop" => ~w(read ingest enroll admin)},
          "expires_at" => System.system_time(:millisecond) + 60_000
        }
      ]
    }

    service_path = Path.join(root, "config.json")
    write(service_path, service)
    token_path = Path.join(root, "operator.token")
    File.write!(token_path, token <> "\n")
    File.chmod!(token_path, 0o600)
    {:ok, _marker} = StoragePolicy.provision(root, root, "pi-browser-test")
    port = free_port()

    browser = %{
      "schema" => "wtr.browser.v3",
      "listen" => %{"ip" => "127.0.0.1", "port" => port},
      "exposure" => "loopback",
      "public_origin" => "http://127.0.0.1:#{port}",
      "secret_key_base" => Base.encode64(:crypto.strong_rand_bytes(64)),
      "device_session" => %{"scope" => "workshop"},
      "map_pack" => map_pack_document()
    }

    browser_path = Path.join(root, "browser.json")
    write(browser_path, browser)

    previous =
      Map.new([:config_path, :data_root, :browser_config_path, :cellular_config_path], fn key ->
        {key, Application.get_env(:wotex_tracker_nerves, key)}
      end)

    Application.put_env(:wotex_tracker_nerves, :cellular_config_path, nil)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        Application.put_env(:wotex_tracker_nerves, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{
      root: root,
      service_path: service_path,
      browser_path: browser_path,
      browser: browser,
      port: port,
      token: token,
      token_path: token_path
    }
  end

  test "the attached display exchanges a single-use nonce for an authorized setup session", c do
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)
    Application.put_env(:wotex_tracker_nerves, :config_path, c.service_path)
    Application.put_env(:wotex_tracker_nerves, :browser_config_path, c.browser_path)
    assert {:ok, host} = HostApplication.start(:normal, [])
    Process.unlink(host)
    on_exit(fn -> if Process.alive?(host), do: Supervisor.stop(host) end)
    assert {:ok, server} = Server.child(host, Server)
    assert {:ok, store} = Server.child(server, :store)
    assert {:ok, {{127, 0, 0, 1}, port}} = Endpoint.server_info(:http)
    assert port == c.port
    assert Endpoint.config(:tracker_ui)[:map_pack].id == "pi-test-map"

    url = ~c"http://127.0.0.1:#{port}/sign-in"

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert body =~ "Sign in"
    refute body =~ c.token

    launch = DeviceSession.launch_url(c.browser["public_origin"])
    nonce = URI.parse(launch).query |> URI.decode_query() |> Map.fetch!("nonce")
    refute launch =~ c.token

    denied =
      :get
      |> Plug.Test.conn(launch)
      |> Map.put(:remote_ip, {10, 0, 0, 2})
      |> DeviceSessionPlug.call([])

    assert denied.status == 404

    assert {:ok, {{_, 303, _}, headers, "See Other\n"}} =
             :httpc.request(:get, {String.to_charlist(launch), []}, [autoredirect: false],
               body_format: :binary
             )

    assert header(headers, "location") == "/setup"
    cookie = headers |> header("set-cookie") |> String.split(";", parts: 2) |> hd()

    assert {:ok, {{_, 200, _}, _, setup}} =
             :httpc.request(
               :get,
               {~c"http://127.0.0.1:#{port}/setup", [{~c"cookie", String.to_charlist(cookie)}]},
               [],
               body_format: :binary
             )

    assert setup =~ "Setup"
    refute setup =~ "Sign in"
    refute setup =~ c.token
    refute setup =~ nonce

    assert {:ok, {{_, 404, _}, _, "Not found\n"}} =
             :httpc.request(:get, {String.to_charlist(launch), []}, [], body_format: :binary)

    [{Wotex.Tracker.Nerves.Browser, browser, _, _} | _] =
      Enum.filter(Supervisor.which_children(host), fn {id, _, _, _} ->
        id == Wotex.Tracker.Nerves.Browser
      end)

    assert :ok = Supervisor.terminate_child(host, Wotex.Tracker.Nerves.Browser)
    refute Process.alive?(browser)

    assert {:ok, restarted_browser} =
             Supervisor.restart_child(host, Wotex.Tracker.Nerves.Browser)

    assert restarted_browser != browser
    assert {:ok, ^store} = Server.child(server, :store)
    assert Process.alive?(store)
  end

  test "browser configuration is private, loopback-only and keeps secrets out of inspection", c do
    File.rm!(c.browser_path)
    assert {:ok, browser_path} = BrowserProvisioning.provision(c.root, c.port, "workshop")
    browser = browser_path |> File.read!() |> Codec.decode!()
    {:ok, options} = Wotex.Tracker.Service.HTTP.FileConfig.load(c.service_path)
    assert {:ok, config} = BrowserConfig.load(c.browser_path, c.root, options)
    assert config.port == c.port
    assert config.device_session == %{scope: "workshop", token_file: c.token_path}
    refute inspect(config) =~ browser["secret_key_base"]
    refute inspect(config) =~ c.token_path

    legacy = browser |> Map.delete("device_session") |> Map.put("schema", "wtr.browser.v1")
    write(c.browser_path, legacy)
    assert {:ok, %{device_session: nil}} = BrowserConfig.load(c.browser_path, c.root, options)

    write(c.browser_path, c.browser)
    assert {:ok, %{map_pack: map_pack}} = BrowserConfig.load(c.browser_path, c.root, options)
    assert map_pack.id == "pi-test-map"
    refute inspect(map_pack) =~ "Pi test map"

    for changed <- [
          Map.put(browser, "secret_key_base", "short"),
          Map.put(browser, "exposure", "proxy"),
          Map.put(browser, "public_origin", "http://foreign.example"),
          put_in(browser, ["device_session", "scope"], "other"),
          Map.put(browser, "extra", true)
        ] do
      write(c.browser_path, changed)

      assert {:error, :invalid_configuration} =
               BrowserConfig.load(c.browser_path, c.root, options)
    end

    write(c.browser_path, browser)
    File.chmod!(c.browser_path, 0o644)
    assert {:error, :invalid_configuration} = BrowserConfig.load(c.browser_path, c.root, options)

    write(c.browser_path, browser)
    File.write!(c.token_path, Credentials.generate_token() <> "\n")
    File.chmod!(c.token_path, 0o600)
    assert {:error, :invalid_configuration} = BrowserConfig.load(c.browser_path, c.root, options)

    File.write!(c.token_path, c.token <> "\n")
    File.chmod!(c.token_path, 0o644)
    assert {:error, :invalid_configuration} = BrowserConfig.load(c.browser_path, c.root, options)

    source = c.token_path <> ".source"
    File.write!(source, c.token <> "\n")
    File.chmod!(source, 0o600)
    File.rm!(c.token_path)
    File.ln_s!(source, c.token_path)
    assert {:error, :invalid_configuration} = BrowserConfig.load(c.browser_path, c.root, options)
  end

  test "operational history denies missing admin authority before reading the collector" do
    providers = {fn -> {:error, :forbidden} end, fn -> flunk("collector read") end}

    assert {:error, %{"code" => "forbidden"}} =
             Client.request(
               providers,
               "private-token",
               "workshop",
               :operational_history,
               %{"event" => nil, "cursor" => nil, "window_ms" => 300_000},
               System.system_time(:millisecond)
             )
  end

  defp write(path, document) do
    File.write!(path, Codec.encode!(document))
    File.chmod!(path, 0o600)
  end

  defp map_pack_document do
    %{
      "schema" => "wtr.map-pack.v1",
      "id" => "pi-test-map",
      "revision" => "1",
      "attribution" => "Pi test map",
      "coverage" => %{"west" => 17, "south" => 59, "east" => 19, "north" => 60},
      "features" => [%{"class" => "road", "points" => [[59.3, 18.0], [59.4, 18.1]]}]
    }
  end

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp free_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    port
  end
end
