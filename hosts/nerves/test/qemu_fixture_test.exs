Code.require_file("../qemu/qemu_fixture.ex", __DIR__)

defmodule Wotex.Tracker.Nerves.QemuFixtureTest do
  use ExUnit.Case, async: false
  alias Wotex.Tracker.Nerves.{Config, QemuFixture, StoragePolicy}

  test "a virtual first boot creates one private, valid service document" do
    parent = Path.expand("_build/test/qemu_fixture")
    File.mkdir_p!(parent)
    root = Path.join(parent, Integer.to_string(System.unique_integer([:positive])))
    on_exit(fn -> File.rm_rf!(root) end)

    assert :ok = QemuFixture.prepare(root)
    assert {:ok, options} = Config.load(Path.join(root, "config.json"), root)
    assert options[:directory] == Path.join(root, "data")
    assert options[:exposure] == :loopback
    assert :ok = StoragePolicy.admit(root, "qemu-smoke", Path.join(root, "data"))
    assert File.stat!(root).mode |> Bitwise.band(0o777) == 0o700
    assert File.stat!(Path.join(root, "config.json")).mode |> Bitwise.band(0o777) == 0o600

    original = File.read!(Path.join(root, "config.json"))
    assert :ok = QemuFixture.prepare(root)
    assert File.read!(Path.join(root, "config.json")) == original
  end

  test "the boot probe requires store, health and a retained native sample" do
    calls = :atomics.new(1, [])

    history = fn ->
      case :atomics.add_get(calls, 1, 1) do
        1 -> {:ok, %{"samples" => []}}
        _ -> {:ok, %{"samples" => [%{"event" => "native.sample"}]}}
      end
    end

    assert :ok =
             QemuFixture.probe(
               regular?: fn -> true end,
               initialized?: fn -> true end,
               health: fn -> :ok end,
               history: history,
               attempts: 2,
               interval_ms: 0
             )

    for options <- [
          [
            regular?: fn -> false end,
            initialized?: fn -> true end,
            health: fn -> :ok end,
            history: history
          ],
          [
            regular?: fn -> true end,
            initialized?: fn -> false end,
            health: fn -> :ok end,
            history: history
          ],
          [
            regular?: fn -> true end,
            initialized?: fn -> true end,
            health: fn -> :error end,
            history: history
          ],
          [
            regular?: fn -> true end,
            initialized?: fn -> true end,
            health: fn -> :ok end,
            history: fn -> {:ok, %{"samples" => []}} end,
            attempts: 1,
            interval_ms: 0
          ],
          [
            regular?: fn -> raise "private path" end,
            initialized?: fn -> true end,
            health: fn -> :ok end,
            history: history
          ]
        ] do
      assert :error = QemuFixture.probe(options)
    end
  end
end
