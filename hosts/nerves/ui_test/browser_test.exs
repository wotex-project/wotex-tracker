defmodule Wotex.Tracker.Nerves.BrowserTest do
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Nerves.Application, as: HostApplication
  alias Wotex.Tracker.Nerves.Browser.Client
  alias Wotex.Tracker.Nerves.Browser.Endpoint
  alias Wotex.Tracker.Nerves.BrowserConfig
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
    port = free_port()

    browser = %{
      "schema" => "wtr.browser.v1",
      "listen" => %{"ip" => "127.0.0.1", "port" => port},
      "exposure" => "loopback",
      "public_origin" => "http://127.0.0.1:#{port}",
      "secret_key_base" => Base.encode64(:crypto.strong_rand_bytes(64))
    }

    browser_path = Path.join(root, "browser.json")
    write(browser_path, browser)

    previous =
      Map.new([:config_path, :data_root, :browser_config_path], fn key ->
        {key, Application.get_env(:wotex_tracker_nerves, key)}
      end)

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
      token: token
    }
  end

  test "a local control panel uses the shared screen and restarts without losing the store", c do
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

    url = ~c"http://127.0.0.1:#{port}/sign-in"

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert body =~ "Sign in"
    refute body =~ c.token

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
    {:ok, options} = Wotex.Tracker.Service.HTTP.FileConfig.load(c.service_path)
    assert {:ok, config} = BrowserConfig.load(c.browser_path, c.root, options)
    assert config.port == c.port
    refute inspect(config) =~ c.browser["secret_key_base"]

    for changed <- [
          Map.put(c.browser, "secret_key_base", "short"),
          Map.put(c.browser, "exposure", "proxy"),
          Map.put(c.browser, "public_origin", "http://foreign.example"),
          Map.put(c.browser, "extra", true)
        ] do
      write(c.browser_path, changed)

      assert {:error, :invalid_configuration} =
               BrowserConfig.load(c.browser_path, c.root, options)
    end

    write(c.browser_path, c.browser)
    File.chmod!(c.browser_path, 0o644)
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

  defp free_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)
    port
  end
end
