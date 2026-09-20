defmodule Wotex.Tracker.Nerves.ApplicationTest do
  use ExUnit.Case, async: false
  alias Config.Reader, as: ConfigReader
  alias Wotex.Tracker.Nerves.Application, as: HostApplication
  alias Wotex.Tracker.Nerves.Config
  alias Wotex.Tracker.Nerves.FirmwareHealth
  alias Wotex.Tracker.Nerves.NativeResourceSampler
  alias Wotex.Tracker.Nerves.Provisioner
  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Protocols.Teltonika.{TAT140, TCPSession}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Cellular.Server, as: CellularServer
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig
  alias Wotex.Tracker.Service.HTTP.Server

  setup do
    {:ok, _} = Application.ensure_all_started(:wotex_tracker_service)
    root = Path.expand("_build/test/nerves/#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    data = Path.join(root, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    document = %{
      "schema" => "wtr.host.v1",
      "instance_id" => "pi-test",
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

    path = Path.join(root, "config.json")
    File.write!(path, Codec.encode!(document))
    File.chmod!(path, 0o600)
    {:ok, marker} = StoragePolicy.provision(root, root, "pi-test")

    previous =
      Map.new(
        [:config_path, :data_root, :clock_synchronized, :cellular_config_path, :apns_config_path],
        fn key -> {key, Application.get_env(:wotex_tracker_nerves, key)} end
      )

    Application.put_env(:wotex_tracker_nerves, :cellular_config_path, nil)
    Application.put_env(:wotex_tracker_nerves, :apns_config_path, nil)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        Application.put_env(:wotex_tracker_nerves, key, value)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, data: data, path: path, marker: marker, document: document, token: token}
  end

  test "a configured appliance owns only the shared service listener and store", c do
    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)

    assert {:ok, host} = HostApplication.start(:normal, [])

    children = Supervisor.which_children(host)
    assert {Server, server, :supervisor, _} = List.keyfind(children, Server, 0)

    assert {NativeResourceSampler, sampler, :worker, _} =
             List.keyfind(children, NativeResourceSampler, 0)

    assert Process.alive?(sampler)
    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    assert port > 0
    assert {:ok, store} = Server.child(server, :store)
    assert Process.alive?(store)
    assert :ok = FirmwareHealth.check(host, c.root, "pi-test", c.data)

    assert {:ok, %{"state" => "initialized"}} =
             c.marker |> File.read!() |> Codec.decode()

    url = ~c"http://127.0.0.1:#{port}/api/v1/scopes/workshop/health/ready"

    assert {:ok, {{_, 401, _}, _, _}} =
             :httpc.request(:get, {url, []}, [], body_format: :binary)

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(
               :get,
               {url, [{~c"authorization", ~c"Bearer #{c.token}"}]},
               [],
               body_format: :binary
             )

    assert {:ok, %{"data" => %{"writable" => true}}} = Codec.decode(body)
    Supervisor.stop(host)
    refute Process.alive?(server)
    refute Process.alive?(store)
  end

  test "the appliance supervises an explicitly configured cellular listener", c do
    imei = "123456789012345"
    identity_key = :binary.copy(<<13>>, 32)
    {:ok, identity_digest} = TCPSession.identity_digest(imei, identity_key)
    cellular_path = Path.join(c.root, "cellular.json")

    cellular = %{
      "schema" => "wtr.cellular-host.v1",
      "transport" => "clear_tcp",
      "listen" => %{"ip" => "127.0.0.1", "port" => 0},
      "identity_key" => Base.encode64(identity_key),
      "devices" => [
        %{
          "identity_digest" => identity_digest,
          "token" => c.token,
          "scope" => "workshop",
          "id" => "asset-one",
          "profile" => TAT140.configured_profile()
        }
      ]
    }

    write_private(cellular_path, Codec.encode!(cellular))

    File.write!(
      c.path,
      Codec.encode!(Map.put(c.document, "contract", "teltonika.tat140.codec8e"))
    )

    File.chmod!(c.path, 0o600)

    assert {:ok, options} = Config.load(c.path, c.root)
    assert {:ok, configured} = Config.load_cellular(cellular_path, c.root, options)
    refute inspect(configured) =~ c.token

    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)
    Application.put_env(:wotex_tracker_nerves, :cellular_config_path, cellular_path)
    assert {:ok, host} = HostApplication.start(:normal, [])
    children = Supervisor.which_children(host)
    assert {Server, api, :supervisor, _} = List.keyfind(children, Server, 0)

    assert {CellularServer, listener, :supervisor, _} =
             List.keyfind(children, CellularServer, 0)

    assert {:ok, {{127, 0, 0, 1}, port}} = CellularServer.listener_info(listener)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(socket, <<byte_size(imei)::unsigned-big-16, imei::binary>>)
    assert {:ok, <<1>>} = :gen_tcp.recv(socket, 1, 1_000)
    :ok = :gen_tcp.send(socket, tat140_frame())
    assert {:ok, <<0, 0, 0, 2>>} = :gen_tcp.recv(socket, 4, 1_000)
    :ok = :gen_tcp.close(socket)

    assert {:ok, server_config} = ServerConfig.new(options)
    assert {:ok, service} = Server.context(api, server_config)

    assert {:ok, %{"items" => [%{"id" => observation_id}]}} =
             Service.list(
               service,
               c.token,
               "workshop",
               "observations",
               %{"limit" => 10},
               System.system_time(:millisecond)
             )

    assert {:ok, %{"value" => %{"records" => [_, _]}}} =
             Service.get(
               service,
               c.token,
               "workshop",
               "state",
               observation_id,
               System.system_time(:millisecond)
             )

    assert {:ok, %{"cellular" => "configured"}} = capabilities(api, c.token)

    assert :ok = Supervisor.stop(host)
    refute Process.alive?(api)
    refute Process.alive?(listener)
  end

  test "cellular appliance configuration is optional and root-bound", c do
    assert {:ok, options} = Config.load(c.path, c.root)
    assert {:ok, nil} = Config.load_cellular(nil, c.root, options)

    outside = Path.expand("../cellular.json", c.root)
    assert {:error, :invalid_configuration} = Config.load_cellular(outside, c.root, options)
    assert {:error, :invalid_configuration} = Config.load_cellular(c.path, c.root, options)
    assert {:error, :invalid_configuration} = Config.load_cellular("invalid", nil, :invalid)
  end

  test "the appliance supervises explicitly configured APNs delivery", c do
    apns_path = Path.join(c.root, "apns.json")
    apns = apns_document()
    write_private(apns_path, Codec.encode!(apns))

    assert {:ok, options} = Config.load(c.path, c.root)
    assert {:ok, configured} = Config.load_apns(apns_path, c.root, options)
    refute inspect(configured) =~ apns["private_key"]
    refute inspect(configured) =~ apns["body"]

    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)
    Application.put_env(:wotex_tracker_nerves, :apns_config_path, apns_path)
    Application.put_env(:wotex_tracker_nerves, :clock_synchronized, fn -> true end)
    assert {:ok, host} = HostApplication.start(:normal, [])
    children = Supervisor.which_children(host)
    assert {Server, api, :supervisor, _} = List.keyfind(children, Server, 0)
    assert {:ok, dispatcher} = Server.child(api, :notification_dispatcher)
    assert Process.alive?(dispatcher)

    assert {:ok, %{"schema" => "wtr.notification-dispatcher.v1"}} =
             Server.notification_dispatcher(api)

    assert {:ok, %{"notification_delivery" => "configured"}} =
             capabilities(api, c.token)

    assert :ok = Supervisor.stop(host)
    refute Process.alive?(api)
    refute Process.alive?(dispatcher)
  end

  test "APNs appliance configuration is optional and root-bound", c do
    assert {:ok, options} = Config.load(c.path, c.root)
    assert {:ok, nil} = Config.load_apns(nil, c.root, options)

    outside = Path.expand("../apns.json", c.root)
    assert {:error, :invalid_configuration} = Config.load_apns(outside, c.root, options)
    assert {:error, :invalid_configuration} = Config.load_apns(c.path, c.root, options)
    assert {:error, :invalid_configuration} = Config.load_apns("invalid", nil, :invalid)

    path = Path.join(c.root, "apns.json")
    write_private(path, Codec.encode!(%{}))
    assert {:error, :invalid_configuration} = Config.load_apns(path, c.root, options)
  end

  test "APNs appliance startup requires a synchronized clock before storage opens", c do
    path = Path.join(c.root, "apns.json")
    write_private(path, Codec.encode!(apns_document()))
    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)
    Application.put_env(:wotex_tracker_nerves, :apns_config_path, path)
    Application.put_env(:wotex_tracker_nerves, :clock_synchronized, fn -> false end)

    assert {:error, :clock_unsynchronized} = HostApplication.start(:normal, [])
    refute File.exists?(Path.join(c.data, "tracker.db"))
  end

  test "the target cellular build flag fails closed" do
    previous = System.get_env("WOTEX_TRACKER_CELLULAR")

    on_exit(fn ->
      if previous,
        do: System.put_env("WOTEX_TRACKER_CELLULAR", previous),
        else: System.delete_env("WOTEX_TRACKER_CELLULAR")
    end)

    System.delete_env("WOTEX_TRACKER_CELLULAR")
    assert target_config()[:cellular_config_path] == nil

    System.put_env("WOTEX_TRACKER_CELLULAR", "1")
    assert target_config()[:cellular_config_path] == "/root/tracker/cellular.json"

    System.put_env("WOTEX_TRACKER_CELLULAR", "invalid")

    assert_raise RuntimeError,
                 "WOTEX_TRACKER_CELLULAR accepts only 1 when building cellular ingress",
                 &target_config/0
  end

  test "the target APNs build flag fails closed" do
    previous = System.get_env("WOTEX_TRACKER_APNS")

    on_exit(fn ->
      if previous,
        do: System.put_env("WOTEX_TRACKER_APNS", previous),
        else: System.delete_env("WOTEX_TRACKER_APNS")
    end)

    System.delete_env("WOTEX_TRACKER_APNS")
    assert target_config()[:apns_config_path] == nil

    System.put_env("WOTEX_TRACKER_APNS", "1")
    assert target_config()[:apns_config_path] == "/root/tracker/apns.json"

    System.put_env("WOTEX_TRACKER_APNS", "invalid")

    assert_raise RuntimeError,
                 "WOTEX_TRACKER_APNS accepts only 1 when building notification delivery",
                 &target_config/0
  end

  test "firmware health fails closed for invalid runtime state", c do
    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)

    assert {:ok, host} = HostApplication.start(:normal, [])
    assert {:error, :firmware_health_failed} = FirmwareHealth.check(host, c.root, "other", c.data)

    database = Path.join(c.data, "tracker.db")
    File.chmod!(database, 0o644)

    assert {:error, :firmware_health_failed} =
             FirmwareHealth.check(host, c.root, "pi-test", c.data)

    File.chmod!(database, 0o600)
    assert :ok = FirmwareHealth.check(host, c.root, "pi-test", c.data)

    assert {:error, :firmware_health_failed} =
             FirmwareHealth.check(self(), c.root, "pi-test", c.data)

    assert :ok = Supervisor.stop(host)
  end

  defp target_config do
    "config/target.exs"
    |> ConfigReader.read!()
    |> Keyword.fetch!(:wotex_tracker_nerves)
  end

  test "unprovisioned, public and out-of-root material fails closed", c do
    assert {:error, :recovery_required} = HostApplication.start(:normal, [])
    assert {:error, :invalid_configuration} = Config.load(c.path, c.root <> ".other")

    File.chmod!(c.path, 0o644)
    assert {:error, :invalid_configuration} = Config.load(c.path, c.root)
    File.chmod!(c.path, 0o600)

    outside = Path.expand("../outside", c.root)
    File.write!(c.path, Codec.encode!(%{c.document | "data_directory" => outside}))
    assert {:error, :invalid_configuration} = Config.load(c.path, c.root)

    proxy = %{
      c.document
      | "listen" => %{"ip" => "0.0.0.0", "port" => 4000},
        "exposure" => "proxy",
        "public_origin" => "https://tracker.example"
    }

    File.write!(c.path, Codec.encode!(proxy))
    assert {:error, :invalid_configuration} = Config.load(c.path, c.root)
  end

  test "initialized missing and corrupt storage requires recovery", c do
    File.write!(Path.join(c.data, "tracker.db"), "not sqlite")
    File.chmod!(Path.join(c.data, "tracker.db"), 0o600)
    assert :ok = StoragePolicy.mark_initialized(c.root, "pi-test", c.data)

    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)
    assert {:error, :recovery_required} = start_trapping_exit()

    File.rm!(Path.join(c.data, "tracker.db"))
    assert {:error, :recovery_required} = HostApplication.start(:normal, [])
  end

  test "direct TLS exposure fails before startup while this boot is unsynchronized", c do
    cert = Path.join(c.root, "cert.pem")
    key = Path.join(c.root, "key.pem")
    File.write!(cert, "cert")
    File.write!(key, "key")
    File.chmod!(cert, 0o600)
    File.chmod!(key, 0o600)

    document = %{
      c.document
      | "listen" => %{"ip" => "0.0.0.0", "port" => 443},
        "exposure" => "tls",
        "public_origin" => "https://tracker.example"
    }

    document = Map.put(document, "tls", %{"certfile" => cert, "keyfile" => key})
    File.write!(c.path, Codec.encode!(document))
    Application.put_env(:wotex_tracker_nerves, :config_path, c.path)
    Application.put_env(:wotex_tracker_nerves, :data_root, c.root)
    Application.put_env(:wotex_tracker_nerves, :clock_synchronized, fn -> false end)

    assert {:error, :clock_unsynchronized} = HostApplication.start(:normal, [])
    refute File.exists?(Path.join(c.data, "tracker.db"))
  end

  test "TLS key and certificate must be private files under the provisioned root", c do
    cert = Path.join(c.root, "cert.pem")
    key = Path.join(c.root, "key.pem")
    File.write!(cert, "cert")
    File.write!(key, "key")
    File.chmod!(cert, 0o600)
    File.chmod!(key, 0o600)

    document = %{
      c.document
      | "listen" => %{"ip" => "0.0.0.0", "port" => 443},
        "exposure" => "tls",
        "public_origin" => "https://tracker.example"
    }

    document = Map.put(document, "tls", %{"certfile" => cert, "keyfile" => key})
    File.write!(c.path, Codec.encode!(document))
    assert {:ok, _} = Config.load(c.path, c.root)

    File.chmod!(key, 0o644)
    assert {:error, :invalid_configuration} = Config.load(c.path, c.root)
    File.chmod!(key, 0o600)
    File.write!(c.path, Codec.encode!(put_in(document, ["tls", "keyfile"], "/etc/key.pem")))
    assert {:error, :invalid_configuration} = Config.load(c.path, c.root)
  end

  test "provisioned direct TLS completes an authenticated health request", c do
    tls_root = Path.join(c.root, "tls-root")
    certificate_source = Path.join(c.root, "source-cert.pem")
    key_source = Path.join(c.root, "source-key.pem")
    {certificate, private_key} = test_pair()
    write_private(certificate_source, certificate)
    write_private(key_source, private_key)
    port = free_port()

    assert {:ok, result} =
             Provisioner.run(
               [
                 "--directory",
                 tls_root,
                 "--instance-id",
                 "pi-tls",
                 "--scope",
                 "workshop",
                 "--port",
                 Integer.to_string(port),
                 "--listen-ip",
                 "127.0.0.1",
                 "--public-origin",
                 "https://127.0.0.1:#{port}",
                 "--tls-cert",
                 certificate_source,
                 "--tls-key",
                 key_source
               ],
               System.system_time(:millisecond),
               tls_root
             )

    Application.put_env(:wotex_tracker_nerves, :config_path, result["config_file"])
    Application.put_env(:wotex_tracker_nerves, :data_root, tls_root)
    Application.put_env(:wotex_tracker_nerves, :clock_synchronized, fn -> true end)

    assert {:ok, host} = HostApplication.start(:normal, [])
    token = result["token_file"] |> File.read!() |> String.trim_trailing("\n")
    url = ~c"https://127.0.0.1:#{port}/api/v1/scopes/workshop/health/ready"

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(
               :get,
               {url, [{~c"authorization", ~c"Bearer #{token}"}]},
               [ssl: [verify: :verify_none]],
               body_format: :binary
             )

    assert {:ok, %{"data" => %{"writable" => true, "schema" => "8"}}} = Codec.decode(body)
    assert :ok = Supervisor.stop(host)
  end

  defp start_trapping_exit do
    previous = Process.flag(:trap_exit, true)

    try do
      HostApplication.start(:normal, [])
    after
      Process.flag(:trap_exit, previous)
    end
  end

  defp test_pair do
    configuration =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2_048, 65_537}],
        peer: [key: {:rsa, 2_048, 65_537}]
      })

    certificate = Keyword.fetch!(configuration, :cert)
    {key_type, key} = Keyword.fetch!(configuration, :key)

    {
      :public_key.pem_encode([{:Certificate, certificate, :not_encrypted}]),
      :public_key.pem_encode([{key_type, key, :not_encrypted}])
    }
  end

  defp write_private(path, bytes) do
    with :ok <- File.write(path, bytes, [:exclusive]), do: File.chmod(path, 0o600)
  end

  defp tat140_frame do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/tat140.json"))

    [vector] = fixture["vectors"]
    Base.decode16!(vector["hex"])
  end

  defp apns_document do
    key = :public_key.generate_key({:namedCurve, {1, 2, 840, 10_045, 3, 1, 7}})
    entry = :public_key.pem_entry_encode(:PrivateKeyInfo, key)

    %{
      "schema" => "wtr.apns-host.v1",
      "team_id" => "TEAMID1234",
      "key_id" => "KEYID12345",
      "private_key" => :public_key.pem_encode([entry]),
      "topics" => ["org.wotex.tracker"],
      "scopes" => ["workshop"],
      "title" => "WotEx alert",
      "body" => "Open WotEx to review this alert.",
      "provider_timeout_ms" => 5_000,
      "interval_ms" => 60_000,
      "retry_after_ms" => 60_000,
      "max_batch" => 8,
      "dispatch_timeout_ms" => 6_000
    }
  end

  defp capabilities(server, token) do
    with {:ok, {{127, 0, 0, 1}, port}} <- Server.listener_info(server),
         url = ~c"http://127.0.0.1:#{port}/api/v1/scopes/workshop/capabilities",
         headers = [{~c"authorization", ~c"Bearer #{token}"}],
         {:ok, {{_, 200, _}, _, body}} <-
           :httpc.request(:get, {url, headers}, [timeout: 1_000], body_format: :binary),
         {:ok, %{"data" => data}} <- Codec.decode(body) do
      {:ok, data}
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
