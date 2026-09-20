defmodule Wotex.Tracker.Nerves.RecoveryValidationTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Nerves.{Provisioner, RecoveryValidation}
  alias Wotex.Tracker.Service.Codec

  @runtime_root "/root/tracker"

  setup do
    parent = Path.expand("_build/test/recovery_validation")
    File.mkdir_p!(parent)
    root = Path.join(parent, Integer.to_string(System.unique_integer([:positive])))

    assert {:ok, result} =
             Provisioner.run(
               [
                 "--directory",
                 root,
                 "--instance-id",
                 "pi-recovery",
                 "--scope",
                 "workshop"
               ],
               1_700_000_000_000,
               @runtime_root
             )

    database = Path.join(result["staged_data_directory"], "tracker.db")
    create_database(database)
    initialize_marker(result["storage_marker"])
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      database: database,
      marker: result["storage_marker"],
      config: result["config_file"]
    }
  end

  test "read-only validation admits an exact initialized backup tree without secrets", c do
    database_before = File.read!(c.database)
    marker_before = File.read!(c.marker)

    assert {:ok, result} = RecoveryValidation.run(["--directory", c.root], @runtime_root)
    assert result["schema"] == "wtr.nerves-recovery-validation.v1"
    assert result["database_file"] == c.database
    assert result["storage_state"] == "initialized"
    assert result["database_schema"] == "8"
    assert result["integrity_check"] == "ok"
    refute Map.has_key?(result, "instance_id")
    refute Map.has_key?(result, "storage_id")
    assert File.read!(c.database) == database_before
    assert File.read!(c.marker) == marker_before
    refute File.exists?(c.database <> "-wal")
    refute File.exists?(c.database <> "-shm")
  end

  test "prepared, mismatched and interrupted marker generations fail closed", c do
    marker = c.marker |> File.read!() |> Codec.decode!()

    for changed <- [
          Map.put(marker, "state", "prepared"),
          Map.put(marker, "instance_id", "other-instance"),
          Map.put(marker, "data_directory", "/root/other/data"),
          Map.put(marker, "extra", true)
        ] do
      write(c.marker, changed)
      assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)
    end

    write(c.marker, marker)
    next = Path.join(c.root, "storage.json.next")
    File.write!(next, Codec.encode!(marker))
    File.chmod!(next, 0o600)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)
  end

  test "missing, unsafe, corrupt and unsupported databases fail closed", c do
    File.chmod!(c.database, 0o644)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)
    File.chmod!(c.database, 0o600)

    File.write!(c.database <> "-wal", "unexpected")
    File.chmod!(c.database <> "-wal", 0o600)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)
    File.rm!(c.database <> "-wal")

    set_schema(c.database, 9)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)

    File.rm!(c.database)
    create_incomplete_database(c.database)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)

    File.write!(c.database, "corrupt")
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)

    File.rm!(c.database)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)
  end

  test "configuration identity and argument errors do not disclose the candidate", c do
    config = c.config |> File.read!() |> Codec.decode!()
    write(c.config, Map.put(config, "instance_id", "other-instance"))
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)

    assert {:error, :invalid_arguments} = RecoveryValidation.run([], @runtime_root)

    assert {:error, :invalid_arguments} =
             RecoveryValidation.run(["--directory", "relative"], @runtime_root)

    assert {:error, :recovery_required} = RecoveryValidation.validate(nil, @runtime_root)
  end

  test "direct TLS recovery maps private runtime material into the staged tree", c do
    cert = Path.join(c.root, "cert.pem")
    key = Path.join(c.root, "key.pem")
    File.write!(cert, "certificate")
    File.write!(key, "private key")
    File.chmod!(cert, 0o600)
    File.chmod!(key, 0o600)

    config = c.config |> File.read!() |> Codec.decode!()

    config =
      config
      |> Map.put("listen", %{"ip" => "0.0.0.0", "port" => 443})
      |> Map.put("exposure", "tls")
      |> Map.put("public_origin", "https://tracker.example")
      |> Map.put("tls", %{
        "certfile" => Path.join(@runtime_root, "cert.pem"),
        "keyfile" => Path.join(@runtime_root, "key.pem")
      })

    write(c.config, config)
    assert {:ok, _} = RecoveryValidation.validate(c.root, @runtime_root)

    File.chmod!(key, 0o644)
    assert {:error, :recovery_required} = RecoveryValidation.validate(c.root, @runtime_root)
  end

  defp create_database(path) do
    {:ok, database} = Sqlite3.open(path)

    :ok =
      :wotex_tracker_service
      |> :code.priv_dir()
      |> Path.join("schema/8.sql")
      |> File.read!()
      |> then(&Sqlite3.execute(database, &1))

    :ok = Sqlite3.close(database)
    File.chmod!(path, 0o600)
  end

  defp initialize_marker(path) do
    path
    |> File.read!()
    |> Codec.decode!()
    |> Map.put("state", "initialized")
    |> then(&write(path, &1))
  end

  defp set_schema(path, version) do
    {:ok, database} = Sqlite3.open(path)
    :ok = Sqlite3.execute(database, "PRAGMA user_version=#{version}")
    :ok = Sqlite3.close(database)
  end

  defp create_incomplete_database(path) do
    {:ok, database} = Sqlite3.open(path)
    :ok = Sqlite3.execute(database, "PRAGMA application_id=1465143857; PRAGMA user_version=8")
    :ok = Sqlite3.close(database)
    File.chmod!(path, 0o600)
  end

  defp write(path, document) do
    File.write!(path, Codec.encode!(document) <> "\n")
    File.chmod!(path, 0o600)
  end
end
