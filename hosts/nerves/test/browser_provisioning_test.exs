defmodule Wotex.Tracker.Nerves.BrowserProvisioningTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Nerves.BrowserProvisioning
  alias Wotex.Tracker.Service.Codec

  setup do
    root = Path.expand("_build/test/browser_provisioning/#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, path: Path.join(root, "browser.json")}
  end

  test "creates one private loopback document without returning its secret", c do
    assert {:ok, path} = BrowserProvisioning.provision(c.root, 4000)
    assert path == c.path
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert {:ok, document} = path |> File.read!() |> Codec.decode()
    assert document["schema"] == "wtr.browser.v1"
    assert document["listen"] == %{"ip" => "127.0.0.1", "port" => 4000}
    assert document["exposure"] == "loopback"
    assert document["public_origin"] == "http://127.0.0.1:4000"
    assert byte_size(document["secret_key_base"]) in 64..128
    refute path =~ document["secret_key_base"]

    original = File.read!(path)
    assert {:error, :configuration_exists} = BrowserProvisioning.provision(c.root, 4001)
    assert File.read!(path) == original
  end

  test "invalid and malformed writes leave no browser document", c do
    for port <- [nil, 0, 65_536] do
      assert {:error, :invalid_configuration} = BrowserProvisioning.provision(c.root, port)
    end

    assert {:error, :provisioning_failed} =
             BrowserProvisioning.provision(c.root, 4000, fn path, _bytes ->
               File.write!(path, "{}", [:exclusive])
               File.chmod!(path, 0o600)
             end)

    refute File.exists?(c.path)
  end
end
