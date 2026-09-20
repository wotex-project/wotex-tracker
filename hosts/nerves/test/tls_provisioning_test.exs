defmodule Wotex.Tracker.Nerves.TLSProvisioningTest do
  use ExUnit.Case, async: true

  import Bitwise
  alias Wotex.Tracker.Nerves.TLSProvisioning

  setup do
    parent = Path.expand("_build/test/tls_provisioning/#{System.unique_integer([:positive])}")
    root = Path.join(parent, "tracker")
    source = Path.join(parent, "source")
    File.mkdir_p!(root)
    File.mkdir!(source)
    File.chmod!(parent, 0o700)
    File.chmod!(root, 0o700)
    File.chmod!(source, 0o700)
    {cert, key} = test_pair()
    cert_source = Path.join(source, "cert.pem")
    key_source = Path.join(source, "key.pem")
    write_private(cert_source, cert)
    write_private(key_source, key)
    on_exit(fn -> File.rm_rf!(parent) end)

    %{
      root: root,
      cert: cert,
      key: key,
      cert_source: cert_source,
      key_source: key_source
    }
  end

  test "copies decoded private TLS material to fixed create-only paths", c do
    assert {:ok, paths} =
             TLSProvisioning.provision(
               c.root,
               "/root/tracker",
               c.cert_source,
               c.key_source
             )

    assert paths.certfile == Path.join(c.root, "tls-cert.pem")
    assert paths.keyfile == Path.join(c.root, "tls-key.pem")
    assert paths.runtime_certfile == "/root/tracker/tls-cert.pem"
    assert paths.runtime_keyfile == "/root/tracker/tls-key.pem"
    assert File.read!(paths.certfile) == c.cert
    assert File.read!(paths.keyfile) == c.key
    assert mode(paths.certfile) == 0o600
    assert mode(paths.keyfile) == 0o600
    refute inspect(paths) =~ c.key

    original = Map.new([paths.certfile, paths.keyfile], &{&1, File.read!(&1)})

    assert {:error, :configuration_exists} =
             TLSProvisioning.provision(
               c.root,
               "/root/tracker",
               c.cert_source,
               c.key_source
             )

    assert Map.new([paths.certfile, paths.keyfile], &{&1, File.read!(&1)}) == original
  end

  test "rejects unsafe or malformed sources without creating targets", c do
    File.chmod!(c.key_source, 0o644)

    assert {:error, :invalid_configuration} =
             TLSProvisioning.provision(c.root, "/root/tracker", c.cert_source, c.key_source)

    File.chmod!(c.key_source, 0o600)
    File.write!(c.cert_source, "not a certificate")

    assert {:error, :invalid_configuration} =
             TLSProvisioning.provision(c.root, "/root/tracker", c.cert_source, c.key_source)

    refute File.exists?(Path.join(c.root, "tls-cert.pem"))
    refute File.exists?(Path.join(c.root, "tls-key.pem"))
  end

  test "rejects a private key that does not match the leaf certificate", c do
    {_other_certificate, other_key} = test_pair()
    File.write!(c.key_source, other_key)

    assert {:error, :invalid_configuration} =
             TLSProvisioning.provision(c.root, "/root/tracker", c.cert_source, c.key_source)

    refute File.exists?(Path.join(c.root, "tls-cert.pem"))
    refute File.exists?(Path.join(c.root, "tls-key.pem"))
  end

  test "a failed private-key write removes only the new certificate", c do
    writer = fn path, bytes ->
      if Path.basename(path) == "tls-key.pem",
        do: {:error, :provisioning_failed},
        else: write_private(path, bytes)
    end

    assert {:error, :provisioning_failed} =
             TLSProvisioning.provision(
               c.root,
               "/root/tracker",
               c.cert_source,
               c.key_source,
               writer
             )

    refute File.exists?(Path.join(c.root, "tls-cert.pem"))
    refute File.exists?(Path.join(c.root, "tls-key.pem"))
    assert File.read!(c.cert_source) == c.cert
    assert File.read!(c.key_source) == c.key
  end

  defp test_pair do
    configuration =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2_048, 65_537}],
        peer: [key: {:rsa, 2_048, 65_537}]
      })

    certificate = Keyword.fetch!(configuration, :cert)
    {key_type, key} = Keyword.fetch!(configuration, :key)

    {
      :public_key.pem_encode([{:Certificate, certificate, :not_encrypted}]),
      :public_key.pem_encode([{key_type, key, :not_encrypted}])
    }
  end

  defp write_private(path, bytes) do
    with :ok <- File.write(path, bytes, [:exclusive]), do: File.chmod(path, 0o600)
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777
end
