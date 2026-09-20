defmodule Wotex.Tracker.Mobile.NativeBootstrapTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import Bitwise

  alias Wotex.Tracker.Mobile.{Config, NativeBootstrap, NativeConfiguration, Runtime, WebSession}

  setup do
    root = Path.expand("_build/test/native-bootstrap/#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, directory: Path.join(root, "wotex_tracker")}
  end

  test "admits only exact canonical HTTPS service origins" do
    assert {:ok, %NativeConfiguration{remote_origin: "https://tracker.example"}} =
             NativeConfiguration.new("https://tracker.example")

    assert {:ok, %NativeConfiguration{remote_origin: "https://tracker.example:8443"}} =
             NativeConfiguration.new("https://tracker.example:8443")

    for origin <- [
          "http://tracker.example",
          "https://TRACKER.example",
          "https://tracker.example:443",
          "https://user@tracker.example",
          "https://tracker.example/path",
          "https://tracker.example?query=1",
          "https://tracker.example#fragment",
          "not a URL",
          String.duplicate("x", 2_049),
          nil
        ] do
      assert {:error, :invalid_configuration} = NativeConfiguration.new(origin)
    end
  end

  test "persists only the private bounded origin document", c do
    File.mkdir!(c.directory)
    File.chmod!(c.directory, 0o700)
    assert :missing = NativeConfiguration.load(c.directory)
    assert {:ok, config} = NativeConfiguration.new("https://tracker.example")
    assert :ok = NativeConfiguration.save(c.directory, config)
    assert {:ok, ^config} = NativeConfiguration.load(c.directory)

    assert {:error, :configuration_unavailable} =
             NativeConfiguration.save(c.directory, %NativeConfiguration{
               remote_origin: "http://tracker.example"
             })

    path = Path.join(c.directory, "native-configuration.json")
    assert {:ok, %{type: :regular, links: 1, mode: mode, size: size}} = File.lstat(path)
    assert (mode &&& 0o777) == 0o600
    assert size in 1..4_096

    assert Jason.decode!(File.read!(path)) == %{
             "schema" => "wtr.mobile-native-configuration.v1",
             "remote_origin" => "https://tracker.example"
           }

    refute File.read!(path) =~ "capability"
    refute File.read!(path) =~ "secret"
    refute File.read!(path) =~ "credential"
  end

  test "rejects widened, linked, malformed and overlarge configuration files", c do
    File.mkdir!(c.directory)
    File.chmod!(c.directory, 0o700)
    path = Path.join(c.directory, "native-configuration.json")

    malformed = [
      ~s({"schema":"wtr.mobile-native-configuration.v1","remote_origin":"https://tracker.example","extra":true}),
      ~s({"schema":"wtr.mobile-native-configuration.v1","remote_origin":"https://one.example","remote_origin":"https://two.example"}),
      ~s({"schema":"other","remote_origin":"https://tracker.example"}),
      "not json"
    ]

    for bytes <- malformed do
      File.write!(path, bytes)
      File.chmod!(path, 0o600)
      assert {:error, :invalid_configuration} = NativeConfiguration.load(c.directory)
    end

    File.write!(path, String.duplicate("x", 4_097))
    File.chmod!(path, 0o600)
    assert {:error, :invalid_configuration} = NativeConfiguration.load(c.directory)

    File.write!(
      path,
      ~s({"schema":"wtr.mobile-native-configuration.v1","remote_origin":"https://tracker.example"})
    )

    File.chmod!(path, 0o644)
    assert {:error, :invalid_configuration} = NativeConfiguration.load(c.directory)

    File.rm!(path)
    target = Path.join(c.root, "target")
    File.write!(target, "{}")
    File.ln_s!(target, path)
    assert {:error, :invalid_configuration} = NativeConfiguration.load(c.directory)

    File.chmod!(c.directory, 0o755)
    assert {:error, :invalid_configuration} = NativeConfiguration.load(c.directory)
  end

  test "first run requests setup and configured starts use fresh ephemeral secrets", c do
    data_directory = fn -> c.root end
    assert :missing = NativeBootstrap.boot(data_directory: data_directory)

    capability = Config.generate_capability()
    {:ok, session} = WebSession.new("http://127.0.0.1:4321", capability)
    owner = self()

    replace_host = fn options ->
      send(owner, {:replaced_host, options})
      {:ok, owner}
    end

    assert {:ok, ^session} =
             NativeBootstrap.configure("https://tracker.example",
               data_directory: data_directory,
               port: 43_210,
               notification_environment: "sandbox",
               replace_host: replace_host,
               web_session: fn -> session end
             )

    assert_received {:replaced_host, first}
    assert first[:directory] == c.directory
    assert first[:remote_origin] == "https://tracker.example"
    assert first[:port] == 43_210
    assert first[:notification_app_id] == "org.wotex.tracker"
    assert first[:notification_environment] == "sandbox"
    assert byte_size(first[:secret_key_base]) in 64..256
    assert is_binary(first[:capability])

    start_host = fn options ->
      send(owner, {:started_host, options})
      {:ok, owner}
    end

    assert {:ok, ^session} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               port: fn -> 43_211 end,
               start_host: start_host,
               web_session: fn -> session end
             )

    assert_received {:started_host, second}
    assert second[:remote_origin] == "https://tracker.example"
    assert second[:port] == 43_211
    refute second[:capability] == first[:capability]
    refute second[:secret_key_base] == first[:secret_key_base]
    refute Keyword.has_key?(second, :notification_app_id)

    persisted = File.read!(Path.join(c.directory, "native-configuration.json"))
    refute persisted =~ first[:capability]
    refute persisted =~ first[:secret_key_base]
  end

  test "contains storage and host startup failures", c do
    assert {:error, :invalid_configuration} =
             NativeBootstrap.configure("http://tracker.example",
               data_directory: fn -> c.root end
             )

    assert {:error, :configuration_unavailable} =
             NativeBootstrap.boot(data_directory: fn -> "relative" end)

    assert :missing = NativeBootstrap.boot(data_directory: fn -> c.root end)

    assert {:error, :host_failed} =
             NativeBootstrap.configure("https://tracker.example",
               data_directory: fn -> c.root end,
               port: 43_212,
               replace_host: fn _ -> {:error, :host_failed} end,
               web_session: fn -> raise "must not run" end
             )

    assert {:error, :invalid_configuration} =
             NativeBootstrap.configure("https://tracker.example", :invalid)
  end

  test "contains malformed persisted state and exceptional native seams", c do
    data_directory = fn -> c.root end
    directory = c.directory
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    path = Path.join(directory, "native-configuration.json")
    File.write!(path, "not json")
    File.chmod!(path, 0o600)

    assert {:error, :invalid_configuration} =
             NativeBootstrap.boot(data_directory: data_directory)

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(data_directory: fn -> raise "private failure" end)

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(data_directory: fn -> throw(:private_failure) end)

    File.rm!(path)
    assert {:ok, config} = NativeConfiguration.new("https://tracker.example")
    assert :ok = NativeConfiguration.save(directory, config)

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               port: 0,
               start_host: fn _ -> raise "must not start" end
             )

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               port: 43_213,
               start_host: fn _ -> :invalid end,
               web_session: fn -> raise "must not run" end
             )

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               port: 43_214,
               start_host: fn _ -> {:ok, self()} end,
               web_session: fn -> :invalid end
             )

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               port: 43_215,
               start_host: fn _ -> {:ok, self()} end,
               web_session: fn -> raise "private failure" end
             )

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               port: 43_216,
               start_host: fn _ -> {:ok, self()} end,
               web_session: fn -> throw(:private_failure) end
             )
  end

  test "selects an available loopback port and reuses an already running session", c do
    data_directory = fn -> c.root end
    directory = c.directory
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    assert {:ok, config} = NativeConfiguration.new("https://tracker.example")
    assert :ok = NativeConfiguration.save(directory, config)

    capability = Config.generate_capability()
    {:ok, session} = WebSession.new("http://127.0.0.1:4321", capability)
    owner = self()

    assert {:ok, ^session} =
             NativeBootstrap.boot(
               data_directory: data_directory,
               start_host: fn options ->
                 send(owner, {:selected_port, options[:port]})
                 {:ok, owner}
               end,
               web_session: fn -> session end
             )

    assert_received {:selected_port, port}
    assert port in 1..65_535

    runtime = start_supervised!({Runtime, session})
    assert {:ok, ^session} = NativeBootstrap.boot(web_session: fn -> session end)
    assert :ok = stop_supervised(Runtime)
    refute Process.alive?(runtime)
  end

  test "rejects a symlinked native data root without changing its target", c do
    target = Path.join(c.root, "target")
    linked = Path.join(c.root, "linked")
    File.mkdir!(target)
    File.chmod!(target, 0o755)
    File.ln_s!(target, linked)

    assert {:error, :configuration_unavailable} =
             NativeBootstrap.boot(data_directory: fn -> linked end)

    assert {:ok, %{mode: mode}} = File.lstat(target)
    assert (mode &&& 0o777) == 0o755
  end

  test "default native data lookup contains an unavailable application supervisor", c do
    previous = System.get_env("MOB_DATA_DIR")
    System.put_env("MOB_DATA_DIR", c.root)

    on_exit(fn ->
      if previous,
        do: System.put_env("MOB_DATA_DIR", previous),
        else: System.delete_env("MOB_DATA_DIR")
    end)

    assert {:error, :native_runtime_unavailable} =
             NativeBootstrap.configure("https://tracker.example")
  end
end
