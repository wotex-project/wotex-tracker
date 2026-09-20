defmodule Wotex.Tracker.Service.HostProvisioningTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Wotex.Tracker.Service.{Codec, Credentials, HostProvisioning}
  alias Wotex.Tracker.Service.HTTP.FileConfig

  setup do
    parent = Path.expand("_build/test/host-provisioning/#{System.unique_integer([:positive])}")
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o700)
    on_exit(fn -> File.rm_rf!(parent) end)
    %{parent: parent, destination: Path.join(parent, "tracker")}
  end

  test "creates one private staged loopback configuration without returning its token", c do
    runtime = "/root/tracker"
    input = input(c.destination, runtime)

    assert {:ok, paths} = HostProvisioning.initialize(input)
    assert paths.runtime_config == "/root/tracker/config.json"
    assert paths.runtime_data_directory == "/root/tracker/data"
    assert mode(c.destination) == 0o700
    assert mode(paths.data_directory) == 0o700
    assert mode(paths.config) == 0o600
    assert mode(paths.token_file) == 0o600

    token = paths.token_file |> File.read!() |> String.trim_trailing("\n")
    document = paths.config |> File.read!() |> Codec.decode!()
    credential = hd(document["credentials"])
    assert {:ok, credential["token_sha256"]} == Credentials.token_digest(token)
    assert document["data_directory"] == paths.runtime_data_directory
    refute File.read!(paths.config) =~ token
    refute inspect(paths) =~ token

    assert {:ok, options} = FileConfig.load(paths.config)
    assert options[:directory] == paths.runtime_data_directory

    original = Map.new([paths.config, paths.token_file], &{&1, File.read!(&1)})
    assert {:error, :configuration_exists} = HostProvisioning.initialize(input)
    assert Map.new([paths.config, paths.token_file], &{&1, File.read!(&1)}) == original
  end

  test "creates one private staged direct-TLS configuration", c do
    runtime = "/root/tracker"
    input = tls_input(c.destination, runtime)

    assert {:ok, paths} = HostProvisioning.initialize_tls(input)
    document = paths.config |> File.read!() |> Codec.decode!()
    token = paths.token_file |> File.read!() |> String.trim_trailing("\n")

    assert document["listen"] == %{"ip" => "0.0.0.0", "port" => 443}
    assert document["exposure"] == "tls"
    assert document["public_origin"] == "https://tracker.example"

    assert document["tls"] == %{
             "certfile" => "/root/tracker/tls-cert.pem",
             "keyfile" => "/root/tracker/tls-key.pem"
           }

    assert {:ok, hd(document["credentials"])["token_sha256"]} ==
             Credentials.token_digest(token)

    refute File.read!(paths.config) =~ token
    assert {:ok, options} = FileConfig.load(paths.config)
    assert options[:exposure] == :tls
  end

  test "rejects unsafe roots, widened inputs and occupied targets", c do
    assert {:error, :invalid_configuration} = HostProvisioning.initialize(nil)

    assert {:error, :invalid_configuration} =
             HostProvisioning.initialize(%{
               input(c.destination, "/root/tracker")
               | destination_root: :not_a_path
             })

    assert {:error, :invalid_configuration} =
             HostProvisioning.initialize(%{input(c.destination, "/root/tracker") | port: 0})

    assert {:error, :invalid_configuration} =
             HostProvisioning.initialize(
               Map.put(input(c.destination, "/root/tracker"), :extra, true)
             )

    File.mkdir!(c.destination)
    File.chmod!(c.destination, 0o755)

    assert {:error, :private_directory_required} =
             HostProvisioning.initialize(input(c.destination, "/root/tracker"))

    File.chmod!(c.destination, 0o700)
    File.write!(Path.join(c.destination, "config.json"), "occupied")

    assert {:error, :configuration_exists} =
             HostProvisioning.initialize(input(c.destination, "/root/tracker"))

    refute File.exists?(Path.join(c.destination, "operator.token"))
    refute File.exists?(Path.join(c.destination, "data"))
  end

  test "rejects unsafe direct-TLS endpoints before creating paths", c do
    input = tls_input(c.destination, "/root/tracker")

    for invalid <- [
          %{input | public_origin: "http://tracker.example"},
          %{input | certfile: "/etc/cert.pem"},
          %{input | keyfile: input.certfile},
          %{input | ip: "not-an-address"}
        ] do
      assert {:error, :invalid_configuration} = HostProvisioning.initialize_tls(invalid)
      refute File.exists?(c.destination)
    end

    assert {:error, :invalid_configuration} =
             input |> Map.delete(:keyfile) |> HostProvisioning.initialize_tls()
  end

  test "uses an existing private root and leaves failed root targets untouched", c do
    File.mkdir!(c.destination)
    File.chmod!(c.destination, 0o700)
    assert {:ok, paths} = HostProvisioning.initialize(input(c.destination, c.destination))
    assert File.regular?(paths.config)

    regular = Path.join(c.parent, "regular")
    File.write!(regular, "keep")

    assert {:error, :private_directory_required} =
             HostProvisioning.initialize(input(regular, "/root/tracker"))

    assert File.read!(regular) == "keep"

    unavailable = Path.join(c.parent, "missing/child")

    assert {:error, :private_directory_required} =
             HostProvisioning.initialize(input(unavailable, "/root/tracker"))

    refute File.exists?(unavailable)
  end

  test "rolls back only its new paths across bounded writer failures", c do
    assert {:error, :invalid_configuration} =
             HostProvisioning.initialize(input(c.destination, "/root/tracker"), :not_a_writer)

    token_failure = Path.join(c.parent, "token-failure")

    assert {:error, :provisioning_failed} =
             HostProvisioning.initialize(input(token_failure, "/root/tracker"), fn _, _ ->
               {:error, :provisioning_failed}
             end)

    refute File.exists?(token_failure)

    invalid_writer = Path.join(c.parent, "invalid-writer")

    assert {:error, :provisioning_failed} =
             HostProvisioning.initialize(input(invalid_writer, "/root/tracker"), fn _, _ ->
               :unexpected
             end)

    refute File.exists?(invalid_writer)

    config_failure = Path.join(c.parent, "config-failure")

    assert {:error, :configuration_exists} =
             HostProvisioning.initialize(input(config_failure, "/root/tracker"), fn path, bytes ->
               if Path.basename(path) == "operator.token",
                 do: write_private(path, bytes),
                 else: {:error, :configuration_exists}
             end)

    refute File.exists?(config_failure)

    malformed = Path.join(c.parent, "malformed")

    assert {:error, :provisioning_failed} =
             HostProvisioning.initialize(input(malformed, "/root/tracker"), fn path, bytes ->
               if Path.basename(path) == "config.json",
                 do: write_private(path, "not-json"),
                 else: write_private(path, bytes)
             end)

    refute File.exists?(malformed)

    mismatched = Path.join(c.parent, "mismatched")

    assert {:error, :provisioning_failed} =
             HostProvisioning.initialize(input(mismatched, "/root/tracker"), fn path, bytes ->
               if Path.basename(path) == "config.json" do
                 document = bytes |> Codec.decode!() |> Map.put("data_directory", "/other/data")
                 write_private(path, Codec.encode!(document))
               else
                 write_private(path, bytes)
               end
             end)

    refute File.exists?(mismatched)
  end

  defp input(destination, runtime) do
    %{
      destination_root: destination,
      runtime_root: runtime,
      instance_id: "pi-gateway",
      scope: "workshop",
      ip: "127.0.0.1",
      port: 4000,
      expires_at: 1_700_086_400_000
    }
  end

  defp tls_input(destination, runtime) do
    input(destination, runtime)
    |> Map.merge(%{
      ip: "0.0.0.0",
      port: 443,
      public_origin: "https://tracker.example",
      certfile: Path.join(runtime, "tls-cert.pem"),
      keyfile: Path.join(runtime, "tls-key.pem")
    })
  end

  defp mode(path) do
    {:ok, stat} = File.lstat(path)
    stat.mode &&& 0o777
  end

  defp write_private(path, bytes) do
    case File.write(path, bytes, [:exclusive]) do
      :ok -> File.chmod(path, 0o600)
      error -> error
    end
  end
end
