defmodule Wotex.Tracker.Host.ConfigTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Host.{Application, Config}
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.Server

  setup do
    directory = Path.expand("_build/test/host/#{System.unique_integer([:positive])}")
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
    System.delete_env("WOTEX_TRACKER_UI_CONFIG")

    on_exit(fn ->
      if previous,
        do: System.put_env("WOTEX_TRACKER_CONFIG", previous),
        else: System.delete_env("WOTEX_TRACKER_CONFIG")

      if previous_browser,
        do: System.put_env("WOTEX_TRACKER_UI_CONFIG", previous_browser),
        else: System.delete_env("WOTEX_TRACKER_UI_CONFIG")

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
    assert [{Server, server, :supervisor, _}] = Supervisor.which_children(host)
    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    assert port > 0
    assert {:ok, store} = Server.child(server, :store)
    assert Process.alive?(store)
    Supervisor.stop(host)
    refute Process.alive?(server)
    refute Process.alive?(store)
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
    refute inspect(config) =~ browser["secret_key_base"]

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
end
