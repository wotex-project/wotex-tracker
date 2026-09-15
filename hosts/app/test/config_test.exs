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

    on_exit(fn ->
      if previous,
        do: System.put_env("WOTEX_TRACKER_CONFIG", previous),
        else: System.delete_env("WOTEX_TRACKER_CONFIG")

      File.rm_rf!(directory)
    end)

    %{directory: directory, path: path, document: document, token: token}
  end

  test "a private closed document becomes explicit redacted instance configuration", c do
    assert {:ok, options} = Config.load(c.path)
    assert options[:ip] == {127, 0, 0, 1}
    assert options[:exposure] == :loopback
    assert options[:directory] == c.document["data_directory"]
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

  defp write(path, document) do
    File.write!(path, Codec.encode!(document))
    File.chmod!(path, 0o600)
  end
end
