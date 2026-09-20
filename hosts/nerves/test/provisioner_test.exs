defmodule Wotex.Tracker.Nerves.ProvisionerTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.Nerves.{Config, Provisioner}
  alias Wotex.Tracker.Service.{Codec, Credentials}

  setup do
    parent = Path.expand("_build/test/provisioner/#{System.unique_integer([:positive])}")
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o700)
    on_exit(fn -> File.rm_rf!(parent) end)
    %{root: Path.join(parent, "tracker")}
  end

  test "prepares a loadable private appliance tree without printing its token", c do
    arguments = [
      "--directory",
      c.root,
      "--instance-id",
      "pi-gateway",
      "--scope",
      "workshop",
      "--port",
      "4321",
      "--expires-in",
      "3600"
    ]

    assert {:ok, result} = Provisioner.run(["--" | arguments], 1_700_000_000_000, c.root)
    assert result["schema"] == "wtr.nerves-provisioning.v1"
    assert result["runtime_config_file"] == Path.join(c.root, "config.json")
    assert {:ok, options} = Config.load(result["config_file"], c.root)
    assert options[:port] == 4321
    assert options[:directory] == Path.join(c.root, "data")

    token = result["token_file"] |> File.read!() |> String.trim_trailing("\n")
    document = result["config_file"] |> File.read!() |> Codec.decode!()

    assert {:ok, hd(document["credentials"])["token_sha256"]} ==
             Credentials.token_digest(token)

    refute Codec.encode!(result) =~ token

    assert {:error, :configuration_exists} =
             Provisioner.run(arguments, 1_700_000_000_000, c.root)
  end

  test "staging keeps fixed appliance paths and rejects incomplete or excessive input", c do
    assert {:ok, result} =
             Provisioner.run(
               [
                 "--directory",
                 c.root,
                 "--instance-id",
                 "pi-gateway",
                 "--scope",
                 "workshop"
               ],
               1_700_000_000_000,
               "/root/tracker"
             )

    document = result["config_file"] |> File.read!() |> Codec.decode!()
    assert document["data_directory"] == "/root/tracker/data"
    assert result["runtime_config_file"] == "/root/tracker/config.json"

    assert {:error, :invalid_arguments} =
             Provisioner.run(["--directory", c.root], 1_700_000_000_000, c.root)

    assert {:error, :invalid_arguments} =
             Provisioner.run(
               ["--directory", "relative", "--instance-id", "pi", "--scope", "workshop"],
               1_700_000_000_000,
               c.root
             )

    assert {:error, :invalid_arguments} =
             Provisioner.run(
               [
                 "--directory",
                 c.root <> "-other",
                 "--instance-id",
                 "pi-gateway",
                 "--scope",
                 "workshop",
                 "--expires-in",
                 "604801"
               ],
               1_700_000_000_000,
               c.root
             )
  end
end
