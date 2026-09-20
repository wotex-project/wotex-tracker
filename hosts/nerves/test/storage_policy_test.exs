defmodule Wotex.Tracker.Nerves.StoragePolicyTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Nerves.StoragePolicy
  alias Wotex.Tracker.Service.Codec

  setup do
    parent = Path.expand("_build/test/storage_policy")
    File.mkdir_p!(parent)
    root = Path.join(parent, Integer.to_string(System.unique_integer([:positive])))
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    data = Path.join(root, "data")
    File.mkdir!(data)
    File.chmod!(data, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, data: data, marker: Path.join(root, "storage.json")}
  end

  test "prepared storage permits one empty initialization then requires its database", c do
    marker = c.marker
    assert {:ok, ^marker} = StoragePolicy.provision(c.root, c.root, "pi-test")
    assert :ok = StoragePolicy.admit(c.root, "pi-test", c.data)

    File.write!(Path.join(c.data, "tracker.db"), "sqlite")
    File.chmod!(Path.join(c.data, "tracker.db"), 0o600)
    assert :ok = StoragePolicy.mark_initialized(c.root, "pi-test", c.data)
    assert {:ok, %{"state" => "initialized"}} = c.marker |> File.read!() |> Codec.decode()
    assert :ok = StoragePolicy.admit(c.root, "pi-test", c.data)
    assert StoragePolicy.initialized?(c.root, "pi-test", c.data)

    File.rm!(Path.join(c.data, "tracker.db"))
    assert {:error, :recovery_required} = StoragePolicy.admit(c.root, "pi-test", c.data)
    refute StoragePolicy.initialized?(c.root, "pi-test", c.data)
  end

  test "marker identity, paths, shape and privacy fail closed", c do
    assert {:ok, _} = StoragePolicy.provision(c.root, c.root, "pi-test")
    original = File.read!(c.marker)

    for {bytes, instance, directory} <- [
          {original, "other", c.data},
          {original, "pi-test", c.data <> ".other"},
          {"{}", "pi-test", c.data},
          {"not json", "pi-test", c.data}
        ] do
      File.write!(c.marker, bytes)
      assert {:error, :recovery_required} = StoragePolicy.admit(c.root, instance, directory)
    end

    File.write!(c.marker, original)
    File.chmod!(c.marker, 0o644)
    assert {:error, :recovery_required} = StoragePolicy.admit(c.root, "pi-test", c.data)
  end

  test "a missing marker is an explicit recovery state", c do
    assert {:error, :recovery_required} = StoragePolicy.require_marker(c.root)
    assert {:ok, _} = StoragePolicy.provision(c.root, c.root, "pi-test")
    assert :ok = StoragePolicy.require_marker(c.root)
  end

  test "occupied markers are never replaced", c do
    File.write!(c.marker, "occupied")
    File.chmod!(c.marker, 0o600)
    assert {:error, :configuration_exists} = StoragePolicy.provision(c.root, c.root, "pi-test")
    assert File.read!(c.marker) == "occupied"
  end

  test "an interrupted transition remains explicitly recoverable", c do
    assert {:ok, _} = StoragePolicy.provision(c.root, c.root, "pi-test")
    database = Path.join(c.data, "tracker.db")
    File.write!(database, "sqlite")
    File.chmod!(database, 0o600)

    assert {:error, :recovery_required} =
             StoragePolicy.mark_initialized(c.root, "pi-test", c.data, fn path, bytes ->
               File.write!(path, bytes, [:exclusive])
               File.chmod!(path, 0o600)
               {:error, :injected}
             end)

    assert File.exists?(Path.join(c.root, "storage.json.next"))
    assert {:error, :recovery_required} = StoragePolicy.admit(c.root, "pi-test", c.data)
  end

  test "nested startup reasons classify only storage failures as recovery", _c do
    assert StoragePolicy.recovery_failure?(
             {:shutdown, {:failed_to_start_child, :store, :storage_corrupt}}
           )

    refute StoragePolicy.recovery_failure?(
             {:shutdown, {:failed_to_start_child, :http, :eaddrinuse}}
           )
  end
end
