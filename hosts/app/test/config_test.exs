defmodule Wotex.Tracker.Host.ConfigTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Host.{Application, Config, NativeResourceSampler}
  alias Wotex.Tracker.Host.Development.PassiveSimulatorConfig
  alias Wotex.Tracker.Host.Supervisor, as: HostSupervisor
  alias Wotex.Tracker.Protocols.Teltonika.{TAT140, TCPSession}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.APNsHostConfig
  alias Wotex.Tracker.Service.Cellular.Server, as: CellularServer
  alias Wotex.Tracker.Service.{Codec, Credentials, PassiveScanner}
  alias Wotex.Tracker.Service.HTTP.Config, as: ServerConfig
  alias Wotex.Tracker.Service.HTTP.Server

  defmodule NativeSource do
    def sample(result), do: result
  end

  setup do
    identifier = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    directory = Path.expand("_build/test/host/#{identifier}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    data = Path.join(directory, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    document = %{
      "schema" => "wtr.host.v1",
      "instance_id" => "host-test",
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
          "grants" => %{"workshop" => ~w(read raw ingest enroll admin interact)},
          "expires_at" => System.system_time(:millisecond) + 60_000
        }
      ]
    }

    path = Path.join(directory, "config.json")
    write(path, document)
    previous = System.get_env("WOTEX_TRACKER_CONFIG")
    previous_browser = System.get_env("WOTEX_TRACKER_UI_CONFIG")
    previous_cellular = System.get_env("WOTEX_TRACKER_CELLULAR_CONFIG")
    previous_apns = System.get_env("WOTEX_TRACKER_APNS_CONFIG")
    previous_passive_host = System.get_env("WOTEX_TRACKER_PASSIVE_CONFIG")
    previous_passive = System.get_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG")

    previous_passive_adapter =
      Elixir.Application.get_env(:wotex_tracker_host, :passive_adapter)

    System.delete_env("WOTEX_TRACKER_UI_CONFIG")
    System.delete_env("WOTEX_TRACKER_CELLULAR_CONFIG")
    System.delete_env("WOTEX_TRACKER_APNS_CONFIG")
    System.delete_env("WOTEX_TRACKER_PASSIVE_CONFIG")
    System.delete_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG")
    Elixir.Application.delete_env(:wotex_tracker_host, :passive_adapter)

    on_exit(fn ->
      if previous,
        do: System.put_env("WOTEX_TRACKER_CONFIG", previous),
        else: System.delete_env("WOTEX_TRACKER_CONFIG")

      if previous_browser,
        do: System.put_env("WOTEX_TRACKER_UI_CONFIG", previous_browser),
        else: System.delete_env("WOTEX_TRACKER_UI_CONFIG")

      if previous_cellular,
        do: System.put_env("WOTEX_TRACKER_CELLULAR_CONFIG", previous_cellular),
        else: System.delete_env("WOTEX_TRACKER_CELLULAR_CONFIG")

      if previous_apns,
        do: System.put_env("WOTEX_TRACKER_APNS_CONFIG", previous_apns),
        else: System.delete_env("WOTEX_TRACKER_APNS_CONFIG")

      if previous_passive_host,
        do: System.put_env("WOTEX_TRACKER_PASSIVE_CONFIG", previous_passive_host),
        else: System.delete_env("WOTEX_TRACKER_PASSIVE_CONFIG")

      if previous_passive,
        do: System.put_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG", previous_passive),
        else: System.delete_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG")

      if previous_passive_adapter,
        do:
          Elixir.Application.put_env(
            :wotex_tracker_host,
            :passive_adapter,
            previous_passive_adapter
          ),
        else: Elixir.Application.delete_env(:wotex_tracker_host, :passive_adapter)

      File.rm_rf!(directory)
    end)

    %{directory: directory, path: path, document: document, token: token}
  end

  test "a private closed document becomes explicit redacted instance configuration", c do
    assert {:ok, options} = Config.load(c.path)
    assert options[:ip] == {127, 0, 0, 1}
    assert options[:exposure] == :loopback
    assert options[:directory] == c.document["data_directory"]

    write(
      c.path,
      Map.put(c.document, "storage_limits", %{
        "max_pages" => 32,
        "max_rows" => 100,
        "busy_timeout" => 100,
        "timeout" => 1000
      })
    )

    assert {:ok, limited} = Config.load(c.path)

    assert limited[:store_options] |> Map.new() == %{
             max_pages: 32,
             max_rows: 100,
             busy_timeout: 100,
             timeout: 1000
           }

    write(
      c.path,
      Map.put(c.document, "privacy_policy", %{"domain_inactivity_retention_ms" => 86_400_000})
    )

    assert {:ok, private} = Config.load(c.path)
    assert private[:store_options] == [domain_inactivity_retention_ms: 86_400_000]

    refute inspect(options) =~ c.token
    refute inspect(options) =~ c.document["secret_key"]

    assert {:ok, _} =
             Credentials.authenticate(
               options[:credentials],
               c.token,
               "workshop",
               "read",
               System.system_time(:millisecond)
             )

    for change <- [
          %{"listen" => %{"ip" => "::1", "port" => 4000}},
          %{
            "exposure" => "proxy",
            "public_origin" => "https://tracker.example",
            "listen" => %{"ip" => "0.0.0.0", "port" => 4000}
          },
          %{
            "exposure" => "tls",
            "public_origin" => "https://tracker.example",
            "tls" => %{"certfile" => "/cert.pem", "keyfile" => "/key.pem"}
          }
        ] do
      write(c.path, Map.merge(c.document, change))
      assert {:ok, _} = Config.load(c.path)
    end
  end

  test "missing, public, linked, oversized and non-regular configuration files fail without details",
       c do
    for path <- [nil, "relative.json", c.path <> ".missing", c.directory] do
      assert {:error, :invalid_configuration} = Config.load(path)
    end

    File.chmod!(c.path, 0o644)
    assert {:error, :invalid_configuration} = Config.load(c.path)
    File.chmod!(c.path, 0o600)
    File.chmod!(c.directory, 0o755)
    assert {:error, :invalid_configuration} = Config.load(c.path)
    File.chmod!(c.directory, 0o700)
    link = Path.join(c.directory, "link.json")
    File.ln_s!(c.path, link)
    assert {:error, :invalid_configuration} = Config.load(link)
    hard = Path.join(c.directory, "hard.json")
    File.ln!(c.path, hard)
    assert {:error, :invalid_configuration} = Config.load(c.path)
    File.rm!(hard)
    ancestor = Path.join(c.directory, "alias")
    File.ln_s!(c.directory, ancestor)
    assert {:error, :invalid_configuration} = Config.load(Path.join(ancestor, "config.json"))

    for bytes <- ["", String.duplicate(" ", 65_537), "{\"schema\":1,\"schema\":2}", "not JSON"] do
      File.write!(c.path, bytes)
      assert {:error, :invalid_configuration} = Config.load(c.path)
    end
  end

  test "unknown fields and invalid secrets, credentials, origins and exposure are rejected", c do
    [entry] = c.document["credentials"]
    invalid = [nil, [], %{}, Map.delete(c.document, "instance_id")]

    changes = [
      %{"extra" => true},
      %{"schema" => "wtr.host.v2"},
      %{"secret_key" => nil},
      %{"secret_key" => "invalid"},
      %{"secret_key" => Base.encode64(<<1>>)},
      %{"instance_id" => ""},
      %{"credentials" => []},
      %{"credentials" => List.duplicate(entry, 33)},
      %{"credentials" => [nil]},
      %{"credentials" => [%{entry | "token_sha256" => "bad"}]},
      %{"credentials" => [%{entry | "grants" => %{"workshop" => ["invalid"]}}]},
      %{"listen" => nil},
      %{"listen" => %{"ip" => "localhost", "port" => 4000}},
      %{"listen" => %{"ip" => "127.0.0.1", "port" => -1}},
      %{"exposure" => "unknown"},
      %{"exposure" => "proxy"},
      %{"exposure" => "tls"},
      %{"public_origin" => "http://user:secret@host"},
      %{"tls" => %{}},
      %{"tls" => %{"certfile" => "relative", "keyfile" => "/key.pem"}}
    ]

    changes =
      changes ++
        Enum.map(
          [nil, [], %{"unknown" => 1}, %{"max_pages" => 262_145}, %{"max_rows" => 0}],
          &%{"storage_limits" => &1}
        )

    changes =
      changes ++
        Enum.map(
          [
            nil,
            [],
            %{"unknown" => 1},
            %{"domain_inactivity_retention_ms" => 59_999},
            %{"domain_inactivity_retention_ms" => 31_536_000_001}
          ],
          &%{"privacy_policy" => &1}
        )

    for document <- invalid ++ Enum.map(changes, &Map.merge(c.document, &1)) do
      write(c.path, document)
      assert {:error, :invalid_configuration} = Config.load(c.path)
    end
  end

  test "host startup requires configuration and owns the complete listener/store shutdown", c do
    System.delete_env("WOTEX_TRACKER_CONFIG")
    assert {:error, :invalid_configuration} = Application.start(:normal, [])
    System.put_env("WOTEX_TRACKER_CONFIG", c.path)
    assert {:ok, host} = Application.start(:normal, [])

    assert {Server, server, :supervisor, _} =
             List.keyfind(Supervisor.which_children(host), Server, 0)

    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    assert port > 0
    assert {:ok, store} = Server.child(server, :store)
    assert Process.alive?(store)
    Supervisor.stop(host)
    refute Process.alive?(server)
    refute Process.alive?(store)
  end

  test "an optional private cellular listener admits complete semantic records", c do
    imei = "123456789012345"
    identity_key = :binary.copy(<<12>>, 32)
    {:ok, identity_digest} = TCPSession.identity_digest(imei, identity_key)

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

    cellular_path = Path.join(c.directory, "cellular.json")
    write(cellular_path, cellular)
    write(c.path, Map.put(c.document, "contract", "teltonika.tat140.codec8e"))

    assert {:ok, service_options} = Config.load(c.path)
    assert {:ok, cellular_config} = Config.load_cellular(cellular_path, service_options)
    refute inspect(cellular_config) =~ c.token
    refute inspect(cellular_config) =~ cellular["identity_key"]

    System.put_env("WOTEX_TRACKER_CONFIG", c.path)
    System.put_env("WOTEX_TRACKER_CELLULAR_CONFIG", cellular_path)
    assert {:ok, host} = Application.start(:normal, [])
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

    assert {:ok, server_config} = ServerConfig.new(service_options)
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

    assert {:ok, %{"value" => %{"records" => [moving, stopped]}}} =
             Service.get(
               service,
               c.token,
               "workshop",
               "state",
               observation_id,
               System.system_time(:millisecond)
             )

    assert moving["index"]["value"] == 0
    assert stopped["index"]["value"] == 1
    assert stopped["positions"] == []

    assert {:ok, {{127, 0, 0, 1}, api_port}} = Server.listener_info(api)
    url = String.to_charlist("http://127.0.0.1:#{api_port}/api/v1/scopes/workshop/capabilities")
    headers = [{~c"authorization", String.to_charlist("Bearer " <> c.token)}]

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:get, {url, headers}, [timeout: 1_000], body_format: :binary)

    assert {:ok, %{"data" => %{"cellular" => "configured"}}} = Codec.decode(body)

    assert :ok = Supervisor.stop(host)
    refute Process.alive?(api)
    refute Process.alive?(listener)
  end

  test "cellular configuration is optional, private and contract-bound", c do
    assert {:ok, options} = Config.load(c.path)
    assert {:ok, nil} = Config.load_cellular(nil, options)
    assert {:error, :invalid_configuration} = Config.load_cellular("relative", options)

    path = Path.join(c.directory, "cellular.json")
    write(path, %{})
    assert {:error, :invalid_configuration} = Config.load_cellular(path, options)

    File.chmod!(path, 0o644)
    assert {:error, :invalid_configuration} = Config.load_cellular(path, options)
    assert {:error, :invalid_configuration} = Config.load_cellular(path, :invalid)
  end

  test "an explicit dev simulator admits finite passive advertisements", c do
    path = Path.join(c.directory, "passive-simulator.json")
    document = passive_simulator_document(c.token)
    write(path, document)

    assert {:ok, service_options} = Config.load(c.path)
    assert {:ok, simulator} = Config.load_passive_simulator(path, service_options)
    assert simulator.advertisement_count == 2
    assert simulator.adapter == "development-passive-simulator"
    refute inspect(simulator) =~ c.token

    private_address = document["advertisements"] |> hd() |> Map.fetch!("address")
    refute inspect(simulator) =~ private_address

    System.put_env("WOTEX_TRACKER_CONFIG", c.path)
    System.put_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG", path)
    assert {:ok, host} = Application.start(:normal, [])

    assert {Server, api, :supervisor, _} =
             List.keyfind(Supervisor.which_children(host), Server, 0)

    assert {Wotex.Tracker.Service.PassiveScanner, scanner, :worker, _} =
             List.keyfind(
               Supervisor.which_children(host),
               Wotex.Tracker.Service.PassiveScanner,
               0
             )

    eventually(fn ->
      PassiveScanner.status(scanner).lifecycle == :stopped
    end)

    assert {:ok, server_config} = ServerConfig.new(service_options)
    assert {:ok, service} = Server.context(api, server_config)

    assert {:ok, %{"generation" => "2", "items" => observations}} =
             Service.list(
               service,
               c.token,
               "workshop",
               "observations",
               %{"limit" => 10},
               System.system_time(:millisecond)
             )

    assert length(observations) == 2
    assert Enum.all?(observations, &(&1["value"]["ingress"] == "ble"))
    assert :ok = Supervisor.stop(host)
  end

  test "a private production scanner document composes a host-selected adapter", c do
    simulator_path = Path.join(c.directory, "passive-peer.json")
    write(simulator_path, passive_simulator_document(c.token))
    assert {:ok, service_options} = Config.load(c.path)
    assert {:ok, simulator} = Config.load_passive_simulator(simulator_path, service_options)

    passive_path = Path.join(c.directory, "passive.json")
    document = passive_host_document(c.token)
    write(passive_path, document)
    adapter = simulator.scanner[:adapter]

    assert {:ok, config} = Config.load_passive(passive_path, service_options, adapter)
    assert config.adapter_id == "bluez-hci0"
    assert config.adapter == adapter
    refute inspect(config) =~ c.token

    System.put_env("WOTEX_TRACKER_CONFIG", c.path)
    System.put_env("WOTEX_TRACKER_PASSIVE_CONFIG", passive_path)
    Elixir.Application.put_env(:wotex_tracker_host, :passive_adapter, adapter)
    assert {:ok, host} = Application.start(:normal, [])

    children = Supervisor.which_children(host)
    assert {Server, api, :supervisor, _} = List.keyfind(children, Server, 0)
    assert {PassiveScanner, scanner, :worker, _} = List.keyfind(children, PassiveScanner, 0)
    eventually(fn -> PassiveScanner.status(scanner).lifecycle == :stopped end)

    assert {:ok, %{"generation" => "2", "items" => observations}} =
             service_options
             |> ServerConfig.new()
             |> then(fn {:ok, server_config} -> Server.context(api, server_config) end)
             |> then(fn {:ok, service} ->
               Service.list(
                 service,
                 c.token,
                 "workshop",
                 "observations",
                 %{"limit" => 10},
                 System.system_time(:millisecond)
               )
             end)

    assert length(observations) == 2
    assert {:ok, {{127, 0, 0, 1}, api_port}} = Server.listener_info(api)
    url = ~c"http://127.0.0.1:#{api_port}/api/v1/scopes/workshop/capabilities"
    headers = [{~c"authorization", ~c"Bearer #{c.token}"}]

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:get, {url, headers}, [timeout: 1_000], body_format: :binary)

    assert {:ok, %{"data" => %{"ble_scan" => "configured"}}} = Codec.decode(body)
    assert :ok = Supervisor.stop(host)
  end

  test "production scanner configuration is private, adapter-bound and exclusive", c do
    assert {:ok, service_options} = Config.load(c.path)
    assert {:ok, nil} = Config.load_passive(nil, service_options, nil)

    assert {:error, :invalid_configuration} =
             Config.load_passive("relative", service_options, nil)

    path = Path.join(c.directory, "passive.json")
    write(path, passive_host_document(c.token))

    assert {:error, :invalid_configuration} = Config.load_passive(path, service_options, nil)
    assert {:error, :invalid_configuration} = Config.load_passive(path, :invalid, nil)

    simulator_path = Path.join(c.directory, "passive-simulator.json")
    write(simulator_path, passive_simulator_document(c.token))
    assert {:ok, simulator} = Config.load_passive_simulator(simulator_path, service_options)
    adapter = simulator.scanner[:adapter]
    assert {:ok, _} = Config.load_passive(path, service_options, adapter)

    File.chmod!(path, 0o644)
    assert {:error, :invalid_configuration} = Config.load_passive(path, service_options, adapter)
    File.chmod!(path, 0o600)

    System.put_env("WOTEX_TRACKER_CONFIG", c.path)
    System.put_env("WOTEX_TRACKER_PASSIVE_CONFIG", path)
    System.put_env("WOTEX_TRACKER_PASSIVE_SIMULATOR_CONFIG", simulator_path)
    Elixir.Application.put_env(:wotex_tracker_host, :passive_adapter, adapter)
    assert {:error, :invalid_configuration} = Application.start(:normal, [])
  end

  test "passive simulator configuration is optional, private and dev-only", c do
    assert {:ok, service_options} = Config.load(c.path)
    assert {:ok, nil} = Config.load_passive_simulator(nil, service_options)

    assert {:error, :invalid_configuration} =
             Config.load_passive_simulator("relative", service_options)

    path = Path.join(c.directory, "passive-simulator.json")
    valid = passive_simulator_document(c.token)

    advertisements =
      ~w(public random_private_resolvable random_private_non_resolvable unknown)
      |> Enum.with_index()
      |> Enum.map(fn {address_type, index} ->
        valid["advertisements"]
        |> hd()
        |> Map.put("id", "address-kind-#{index}")
        |> Map.put("address_type", address_type)
      end)

    write(path, Map.put(valid, "advertisements", advertisements))
    assert {:ok, %{advertisement_count: 4}} = Config.load_passive_simulator(path, service_options)

    invalid = [
      %{},
      Map.put(valid, "schema", "other"),
      Map.put(valid, "adapter", "physical"),
      Map.put(valid, "token", Credentials.generate_token()),
      Map.put(valid, "scope", "other"),
      Map.put(valid, "interval_ms", -1),
      Map.put(valid, "timeout_ms", 30_001),
      Map.put(valid, "advertisements", []),
      Map.put(valid, "advertisements", [
        Map.put(hd(valid["advertisements"]), "address_type", "forged")
      ]),
      Map.put(valid, "advertisements", [nil]),
      Map.put(valid, "advertisements", [Map.put(hd(valid["advertisements"]), "payload_hex", 1)]),
      Map.put(valid, "advertisements", [Map.put(hd(valid["advertisements"]), "payload_hex", "aa")]),
      Map.put(valid, "unknown", true)
    ]

    for document <- invalid do
      write(path, document)

      assert {:error, :invalid_configuration} =
               Config.load_passive_simulator(path, service_options)
    end

    write(path, valid)
    File.chmod!(path, 0o644)
    assert {:error, :invalid_configuration} = Config.load_passive_simulator(path, service_options)
    assert {:error, :invalid_configuration} = Config.load_passive_simulator(path, :invalid)
    assert {:error, :invalid_configuration} = PassiveSimulatorConfig.load(path, :invalid)
  end

  test "an optional private APNs configuration supervises provider delivery", c do
    apns = apns_document()
    path = Path.join(c.directory, "apns.json")
    write(path, apns)

    assert {:ok, service_options} = Config.load(c.path)
    assert {:ok, apns_config} = Config.load_apns(path, service_options)
    refute inspect(apns_config) =~ apns["private_key"]
    refute inspect(apns_config) =~ apns["body"]

    System.put_env("WOTEX_TRACKER_CONFIG", c.path)
    System.put_env("WOTEX_TRACKER_APNS_CONFIG", path)
    assert {:ok, host} = Application.start(:normal, [])

    assert {Server, api, :supervisor, _} =
             List.keyfind(Supervisor.which_children(host), Server, 0)

    assert {:ok, dispatcher} = Server.child(api, :notification_dispatcher)
    assert Process.alive?(dispatcher)

    assert {:ok, %{"schema" => "wtr.notification-dispatcher.v1"}} =
             Server.notification_dispatcher(api)

    assert {:ok, server_config} =
             service_options
             |> Keyword.put(
               :notification_dispatcher,
               APNsHostConfig.dispatcher_options(apns_config)
             )
             |> ServerConfig.new()

    assert {:ok, service} = Server.context(api, server_config)
    assert service.notification_delivery == :configured

    assert {:ok, {{127, 0, 0, 1}, api_port}} = Server.listener_info(api)
    url = String.to_charlist("http://127.0.0.1:#{api_port}/api/v1/scopes/workshop/capabilities")
    headers = [{~c"authorization", String.to_charlist("Bearer " <> c.token)}]

    assert {:ok, {{_, 200, _}, _, body}} =
             :httpc.request(:get, {url, headers}, [timeout: 1_000], body_format: :binary)

    assert {:ok, %{"data" => %{"notification_delivery" => "configured"}}} =
             Codec.decode(body)

    assert :ok = Supervisor.stop(host)
    refute Process.alive?(api)
    refute Process.alive?(dispatcher)
  end

  test "APNs configuration is optional, private and fail closed", c do
    assert {:ok, options} = Config.load(c.path)
    assert {:ok, nil} = Config.load_apns(nil, options)
    assert {:error, :invalid_configuration} = Config.load_apns("relative", options)

    path = Path.join(c.directory, "apns.json")
    write(path, %{})
    assert {:error, :invalid_configuration} = Config.load_apns(path, options)

    write(path, Map.put(apns_document(), "dispatch_timeout_ms", 1))
    assert {:error, :invalid_configuration} = Config.load_apns(path, options)

    write(path, apns_document())
    File.chmod!(path, 0o644)
    assert {:error, :invalid_configuration} = Config.load_apns(path, options)
    assert {:error, :invalid_configuration} = Config.load_apns(path, :invalid)
  end

  test "host supervision isolates an explicitly selected native resource adapter", c do
    assert {:ok, options} = Config.load(c.path)

    source =
      {:linux_procfs, NativeSource,
       {:ok,
        %{
          system_available_memory_bytes: 4_096,
          process_rss_bytes: 2_048,
          load_1m_milli: 125
        }}}

    assert {:ok, host} =
             HostSupervisor.start_link(service: options, browser: nil, native_resource: source)

    children = Supervisor.which_children(host)
    assert {Server, server, :supervisor, _} = List.keyfind(children, Server, 0)

    assert {NativeResourceSampler, sampler, :worker, _} =
             List.keyfind(children, NativeResourceSampler, 0)

    assert Process.alive?(server)
    assert Process.alive?(sampler)
    Supervisor.stop(host)
    refute Process.alive?(server)
    refute Process.alive?(sampler)
  end

  test "optional browser configuration reuses the private-file and listener security boundary",
       c do
    {:ok, service_options} = Config.load(c.path)
    assert {:ok, nil} = Config.load_browser(nil, service_options)

    browser = %{
      "schema" => "wtr.browser.v1",
      "listen" => %{"ip" => "127.0.0.1", "port" => 4040},
      "exposure" => "loopback",
      "public_origin" => "http://127.0.0.1:4040",
      "secret_key_base" => String.duplicate("s", 64)
    }

    path = Path.join(c.directory, "browser.json")
    write(path, browser)
    assert {:ok, config} = Config.load_browser(path, service_options)
    assert config.port == 4040 and config.exposure == :loopback
    assert config.map_pack == nil
    refute inspect(config) =~ browser["secret_key_base"]

    mapped =
      browser
      |> Map.put("schema", "wtr.browser.v2")
      |> Map.put("map_pack", map_pack_document())

    write(path, mapped)

    if Code.ensure_loaded?(Wotex.Tracker.UI.MapPack) do
      assert {:ok, mapped_config} = Config.load_browser(path, service_options)
      assert inspect(mapped_config.map_pack) =~ "test-map"
      refute inspect(mapped_config) =~ "Test map attribution"
    else
      assert {:error, :invalid_configuration} = Config.load_browser(path, service_options)
    end

    model = %{
      "provider" => "openai_responses",
      "endpoint" => "https://api.openai.com/v1/responses",
      "model" => "gpt-5-mini",
      "api_key" => "sk-test-private-placeholder",
      "disclosure" => "question_schema_utc",
      "timeout_ms" => 5_000,
      "max_request_bytes" => 8_192,
      "max_response_bytes" => 16_384,
      "max_output_tokens" => 512,
      "max_concurrent" => 2,
      "max_requests_per_minute" => 12,
      "max_cost_micro_usd" => 10_000,
      "input_price_micro_usd_per_million" => 250_000,
      "output_price_micro_usd_per_million" => 2_000_000
    }

    write(path, Map.put(browser, "model", model))
    assert {:ok, configured} = Config.load_browser(path, service_options)
    assert configured.prompt.model == "gpt-5-mini"
    refute inspect(configured) =~ model["api_key"]
    refute inspect(configured.prompt) =~ model["api_key"]

    for bad_model <- [
          Map.put(model, "endpoint", nil),
          Map.put(model, "endpoint", "http://api.openai.com/v1/responses"),
          Map.put(model, "endpoint", "https://api.openai.com/v1/responses?key=bad"),
          Map.put(model, "model", nil),
          Map.put(model, "api_key", "bad\r\nheader"),
          Map.put(model, "disclosure", "all_history"),
          Map.put(model, "timeout_ms", 0),
          Map.put(model, "max_concurrent", 0),
          Map.put(model, "extra", true)
        ] do
      write(path, Map.put(browser, "model", bad_model))
      assert {:error, :invalid_configuration} = Config.load_browser(path, service_options)
    end

    write(path, browser)

    unless Code.ensure_loaded?(Wotex.Tracker.Host.Browser) do
      System.put_env("WOTEX_TRACKER_CONFIG", c.path)
      System.put_env("WOTEX_TRACKER_UI_CONFIG", path)
      assert {:error, :ui_not_in_artifact} = Application.start(:normal, [])
    end

    for change <- [
          %{"exposure" => "proxy", "public_origin" => "https://tracker.example"},
          %{
            "exposure" => "tls",
            "public_origin" => "https://tracker.example",
            "tls" => %{"certfile" => "/cert.pem", "keyfile" => "/key.pem"}
          }
        ] do
      write(path, Map.merge(browser, change))
      assert {:ok, _} = Config.load_browser(path, service_options)
    end

    for bad <- [
          nil,
          %{},
          Map.put(browser, "extra", true),
          Map.put(browser, "secret_key_base", "short"),
          Map.put(browser, "public_origin", "listener"),
          Map.put(browser, "public_origin", "http://remote.example"),
          Map.put(browser, "listen", %{"ip" => "0.0.0.0", "port" => 4040}),
          Map.put(browser, "listen", %{"ip" => "127.0.0.1", "port" => 0}),
          Map.put(browser, "exposure", "unknown"),
          Map.put(browser, "tls", %{})
        ] do
      write(path, bad)
      assert {:error, :invalid_configuration} = Config.load_browser(path, service_options)
    end

    write(path, browser)
    File.chmod!(path, 0o644)
    assert {:error, :invalid_configuration} = Config.load_browser(path, service_options)
    assert {:error, :invalid_configuration} = Config.load_browser("relative", service_options)
  end

  defp write(path, document) do
    File.write!(path, Codec.encode!(document))
    File.chmod!(path, 0o600)
  end

  defp map_pack_document do
    %{
      "schema" => "wtr.map-pack.v1",
      "id" => "test-map",
      "revision" => "1",
      "attribution" => "Test map attribution",
      "coverage" => %{"west" => 17, "south" => 59, "east" => 19, "north" => 60},
      "features" => [%{"class" => "road", "points" => [[59.3, 18.0], [59.4, 18.1]]}]
    }
  end

  defp tat140_frame do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/tat140.json"))

    [vector] = fixture["vectors"]
    Base.decode16!(vector["hex"])
  end

  defp passive_simulator_document(token) do
    now = System.system_time(:millisecond)

    advertisement = %{
      "id" => "simulated-ruuvi-one",
      "observed_at" => now,
      "receiver" => "development-macos",
      "address" => "private-address-one",
      "address_type" => "random_private_resolvable",
      "manufacturer_id" => 1_177,
      "payload_hex" => "0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F",
      "rssi" => -42,
      "provenance" => %{
        "evidence_class" => "simulator",
        "scenario" => "ruuvi-raw-v2"
      }
    }

    %{
      "schema" => "wtr.passive-ble-simulator.v1",
      "adapter" => "development-passive-simulator",
      "token" => token,
      "scope" => "workshop",
      "interval_ms" => 0,
      "timeout_ms" => 1_000,
      "advertisements" => [
        advertisement,
        %{
          advertisement
          | "id" => "simulated-ruuvi-two",
            "observed_at" => now + 1,
            "address" => "private-address-two"
        }
      ]
    }
  end

  defp passive_host_document(token) do
    %{
      "schema" => "wtr.passive-ble-host.v1",
      "adapter" => "bluez-hci0",
      "token" => token,
      "scope" => "workshop",
      "interval_ms" => 0,
      "timeout_ms" => 1_000
    }
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
end
