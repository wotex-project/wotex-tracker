defmodule Wotex.Tracker.Service.HTTP.FileConfigTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Service.{Codec, Credentials}
  alias Wotex.Tracker.Service.HTTP.{Config, FileConfig}

  setup do
    directory = Path.expand("_build/test/private_config/#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    data = Path.join(directory, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    document = %{
      "schema" => "wtr.host.v1",
      "instance_id" => "file-test",
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
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, path: path, document: document, token: token}
  end

  test "a private document yields validated options usable by the HTTP service", c do
    assert {:ok, options} = FileConfig.load(c.path)
    assert {:ok, _} = Config.new(options)
    assert options[:directory] == c.document["data_directory"]
    assert options[:ip] == {127, 0, 0, 1}
    assert options[:public_origin] == :listener
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

    write(c.path, Map.put(c.document, "storage_limits", %{"max_rows" => 100}))
    assert {:ok, limited} = FileConfig.load(c.path)
    assert limited[:store_options] == [max_rows: 100]

    for change <- [
          %{"listen" => %{"ip" => "::1", "port" => 4000}},
          %{
            "listen" => %{"ip" => "0.0.0.0", "port" => 4000},
            "exposure" => "proxy",
            "public_origin" => "https://tracker.example"
          },
          %{
            "exposure" => "tls",
            "public_origin" => "https://tracker.example",
            "tls" => %{"certfile" => "/cert.pem", "keyfile" => "/key.pem"}
          }
        ] do
      write(c.path, Map.merge(c.document, change))
      assert {:ok, _} = FileConfig.load(c.path)
    end
  end

  test "missing and unsafe files fail with one redacted error", c do
    for path <- [nil, "relative.json", c.path <> ".missing", c.directory] do
      assert {:error, :invalid_configuration} = FileConfig.read_document(path)
      assert {:error, :invalid_configuration} = FileConfig.load(path)
    end

    File.chmod!(c.path, 0o644)
    assert {:error, :invalid_configuration} = FileConfig.load(c.path)
    File.chmod!(c.path, 0o600)
    File.chmod!(c.directory, 0o755)
    assert {:error, :invalid_configuration} = FileConfig.load(c.path)
    File.chmod!(c.directory, 0o700)

    link = Path.join(c.directory, "link.json")
    File.ln_s!(c.path, link)
    assert {:error, :invalid_configuration} = FileConfig.load(link)
    alias_path = Path.join(c.directory, "alias")
    File.ln_s!(c.directory, alias_path)

    assert {:error, :invalid_configuration} =
             FileConfig.load(Path.join(alias_path, "config.json"))

    hard = Path.join(c.directory, "hard.json")
    File.ln!(c.path, hard)
    assert {:error, :invalid_configuration} = FileConfig.load(c.path)
    File.rm!(hard)

    for bytes <- ["", "not JSON", "{\"schema\":1,\"schema\":2}", String.duplicate("x", 65_537)] do
      File.write!(c.path, bytes)
      assert {:error, :invalid_configuration} = FileConfig.load(c.path)
    end
  end

  test "closed schema rejects malformed credentials, exposure and limits", c do
    [entry] = c.document["credentials"]

    for change <- [
          %{"schema" => "unknown"},
          %{"secret_key" => "bad"},
          %{"instance_id" => ""},
          %{"credentials" => []},
          %{"credentials" => List.duplicate(entry, 33)},
          %{"credentials" => [%{entry | "token_sha256" => "bad"}]},
          %{"listen" => %{"ip" => "localhost", "port" => 4000}},
          %{"exposure" => "proxy"},
          %{"exposure" => "tls"},
          %{"public_origin" => "http://user:secret@host"},
          %{"tls" => %{}},
          %{"storage_limits" => %{"max_rows" => 100_001}},
          %{"storage_limits" => %{"extra" => 1}},
          %{"unknown" => 1}
        ] do
      write(c.path, Map.merge(c.document, change))
      assert {:error, :invalid_configuration} = FileConfig.load(c.path)
    end

    for document <- [nil, %{}, [], Map.delete(c.document, "instance_id")] do
      write(c.path, document)
      assert {:error, :invalid_configuration} = FileConfig.load(c.path)
    end
  end

  defp write(path, document) do
    File.write!(path, Codec.encode!(document))
    File.chmod!(path, 0o600)
  end
end
