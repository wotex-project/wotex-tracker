defmodule Wotex.Tracker.Nerves.ApplicationTest do
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Nerves.Application, as: HostApplication
  alias Wotex.Tracker.Nerves.Config
  alias Wotex.Tracker.Nerves.NativeResourceSampler
  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Service.{Codec, Credentials}
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
    previous_path = Application.get_env(:wotex_tracker_nerves, :config_path)
    previous_root = Application.get_env(:wotex_tracker_nerves, :data_root)

    on_exit(fn ->
      Application.put_env(:wotex_tracker_nerves, :config_path, previous_path)
      Application.put_env(:wotex_tracker_nerves, :data_root, previous_root)
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

  defp start_trapping_exit do
    previous = Process.flag(:trap_exit, true)

    try do
      HostApplication.start(:normal, [])
    after
      Process.flag(:trap_exit, previous)
    end
  end
end
