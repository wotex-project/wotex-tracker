defmodule Wotex.Tracker.Mobile.ConfigTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.Mobile.{Config, WebSession}

  defmodule Transport do
    @behaviour Wotex.Tracker.UI.RemoteTransport
    @impl true
    def request(_, _, _), do: {:error, :unused}
  end

  test "builds a loopback-only host around one exact remote HTTPS service" do
    capability = Config.generate_capability()

    assert {:ok, config} =
             Config.new(
               directory: Path.expand("_build/test/config-cache"),
               remote_origin: "https://service.example",
               port: 4_321,
               secret_key_base: String.duplicate("s", 64),
               capability: capability,
               remote_transport: {Transport, :context},
               notification_app_id: "org.wotex.tracker",
               notification_environment: "sandbox",
               timeout_ms: 1_000
             )

    assert config.origin == "http://127.0.0.1:4321"
    assert config.remote_origin == "https://service.example"
    assert config.capability_digest == :crypto.hash(:sha256, capability)
    assert %WebSession{} = config.web_session
    assert config.remote.origin == "https://service.example"
    assert config.remote.timeout_ms == 1_000
    assert config.notification == %{app_id: "org.wotex.tracker", environment: "sandbox"}
    assert config.web_session.notification == config.notification
    refute inspect(config) =~ capability
    refute inspect(config) =~ config.secret_key_base
  end

  test "rejects malformed or widened host configuration" do
    valid = [
      directory: Path.expand("_build/test/config-cache"),
      remote_origin: "https://service.example",
      port: 4_321,
      secret_key_base: String.duplicate("s", 64),
      capability: Config.generate_capability(),
      remote_transport: {Transport, :context}
    ]

    invalid = [
      Keyword.delete(valid, :directory),
      Keyword.put(valid, :directory, "relative"),
      Keyword.put(valid, :remote_origin, "http://service.example"),
      Keyword.put(valid, :remote_origin, "https://service.example/"),
      Keyword.put(valid, :port, 0),
      Keyword.put(valid, :port, 65_536),
      Keyword.put(valid, :secret_key_base, String.duplicate("s", 63)),
      Keyword.put(valid, :capability, "not-canonical"),
      Keyword.put(valid, :timeout_ms, 99),
      Keyword.put(valid, :secure_store, {String, nil}),
      Keyword.put(valid, :clock, :invalid),
      Keyword.put(valid, :notification_app_id, "invalid"),
      Keyword.put(valid, :notification_app_id, "org.wotex.tracker"),
      Keyword.put(valid, :notification_environment, "production"),
      valid ++ [notification_app_id: "invalid", notification_environment: "sandbox"],
      valid ++ [notification_app_id: "org.wotex.tracker", notification_environment: "other"],
      valid ++ [extra: true],
      valid ++ [port: 4_322]
    ]

    for options <- invalid do
      assert {:error, :invalid_configuration} = Config.new(options)
    end

    assert {:error, :invalid_configuration} = Config.new(:invalid)
  end

  test "default transport is a loaded OS-DNS wrapper" do
    assert {:ok, config} =
             Config.new(
               directory: Path.expand("_build/test/config-cache"),
               remote_origin: "https://service.example",
               port: 4_321,
               secret_key_base: String.duplicate("s", 64),
               capability: Config.generate_capability()
             )

    assert {Wotex.Tracker.Mobile.RemoteTransport, %{resolver: {Wotex.Tracker.Mobile.DNS, nil}}} =
             config.remote.transport

    assert {Wotex.Mobile.SecureStore, :wotex_secure_store_nif} = config.secure_store
    assert is_function(config.clock, 0)
  end
end
