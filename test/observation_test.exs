defmodule Wotex.Tracker.ObservationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Wotex.Tracker.{Admission, Error, Fixtures, Limits, Observation}

  test "raw bytes and native JSON retain every type in versioned exports" do
    for payload <- [
          {:bytes, <<0, 255, 1>>},
          {:bytes, <<>>},
          {:json,
           %{
             "int" => 1,
             "float" => 1.0,
             "false" => false,
             "zero" => 0,
             "null" => nil,
             "wide" => 9_007_199_254_740_993,
             "unicode" => "å",
             "list" => [false, 0]
           }}
        ] do
      value = Fixtures.observation(%{payload: payload})
      assert {:ok, map} = Observation.to_map(value)
      assert {:ok, restored} = Observation.from_map(map)
      assert restored === value
      assert Observation.same?(restored, value)
      assert {:ok, _} = Observation.identity(value)
    end
  end

  test "every capture field affects content identity, including numeric type" do
    original = Fixtures.observation(%{payload: {:json, %{"value" => 1}}})
    {:ok, digest} = Observation.identity(original)

    changes = %{
      id: "other",
      observed_at: 0,
      ingress: "http",
      source: %{"receiver_id" => "other"},
      addressing: %{"address_type" => "public"},
      payload: {:json, %{"value" => 1.0}},
      radio: %{"rssi" => -70.0},
      transport: %{"retry" => false},
      provenance: %{"kind" => "replay"}
    }

    for {key, value} <- changes do
      changed = Map.put(original, key, value)
      assert {:ok, other} = Observation.identity(changed)
      refute digest == other
      refute Observation.same?(original, changed)
    end
  end

  test "malformed options, forged structs and all invalid field shapes fail" do
    for options <- [
          nil,
          %{},
          [1],
          [max_nodes: 1, max_nodes: 2],
          [unknown: 1],
          [max_nodes: 0],
          [max_nodes: -1],
          [max_nodes: 1.0],
          [{:max_nodes, 1} | :bad]
        ] do
      assert {:error, %Error{}} = Observation.new(Fixtures.observation_input(), options)
    end

    for input <- [
          nil,
          [],
          %{},
          Fixtures.observation(),
          Map.put(Fixtures.observation_input(), "id", "alias")
        ],
        do: assert({:error, %Error{}} = Observation.new(input))

    for {field, invalid} <- [
          id: "",
          id: <<255>>,
          observed_at: 1.0,
          ingress: :ble,
          ingress: "unspecified",
          source: [],
          radio: %{rssi: 0},
          addressing: %{Date.utc_today() => false},
          transport: %{__struct__: URI},
          provenance: %{"x" => <<255>>},
          payload: <<0>>,
          payload: {:json, [1 | 2]},
          payload: {:json, %{"x" => self()}},
          payload: {:bytes, []}
        ] do
      assert {:error, %Error{}} = Observation.new(Fixtures.observation_input(%{field => invalid}))
    end

    assert {:error, _} = Observation.validate(:bad)
    assert {:error, _} = Observation.to_map(%{Fixtures.observation() | observed_at: :bad})
    assert {:error, _} = Observation.identity(:bad)
    refute Observation.same?(:bad, :bad)
  end

  test "ID, raw payload and nested JSON limits are enforced at boundaries" do
    for size <- [255, 256] do
      assert {:ok, _} =
               Observation.new(Fixtures.observation_input(%{id: String.duplicate("x", size)}))
    end

    assert {:error, _} =
             Observation.new(Fixtures.observation_input(%{id: String.duplicate("x", 257)}))

    for size <- [65_535, 65_536] do
      assert {:ok, value} =
               Observation.new(
                 Fixtures.observation_input(%{payload: {:bytes, :binary.copy(<<255>>, size)}})
               )

      assert {:ok, _} = Observation.identity(value)
    end

    assert {:error, _} =
             Observation.new(
               Fixtures.observation_input(%{payload: {:bytes, :binary.copy(<<0>>, 65_537)}})
             )

    for {option, accepted, rejected} <- [
          {:max_nodes, %{}, %{"x" => 0}},
          {:max_depth, %{"x" => 0}, %{"x" => %{"y" => 0}}},
          {:max_collection_size, %{"x" => 0}, %{"x" => 0, "y" => 0}},
          {:max_string_bytes, "x", "xx"},
          {:max_bytes, "x", "xx"}
        ] do
      {:ok, limits} = Limits.new([{option, 1}])
      assert :ok = Admission.json(accepted, limits)
      assert {:error, _} = Admission.json(rejected, limits)
    end

    assert {:error, _} = Admission.fields(%{}, [:id])
    assert {:error, _} = Admission.digest(:bad, [])
    assert :ok = Admission.bounded_list([1], 1)
    assert {:error, _} = Admission.bounded_list([1, 2], 1)
    assert {:error, _} = Admission.bounded_list([1 | :bad], 2)
    assert {:error, _} = Admission.revision(:bad, elem(Limits.new(), 1))
  end

  test "malformed, noncanonical or oversized bytes envelopes fail" do
    {:ok, map} = Observation.to_map(Fixtures.observation())

    for payload <- [
          nil,
          %{},
          %{"kind" => "json", "value" => 0, "extra" => false},
          %{"kind" => "bytes", "encoding" => "base64", "data" => "?"},
          %{"kind" => "bytes", "encoding" => "base64", "data" => "AB=="},
          %{"kind" => "bytes", "encoding" => "base64", "data" => String.duplicate("A", 87_385)}
        ] do
      assert {:error, _} = Observation.from_map(%{map | "payload" => payload})
    end

    for input <- [
          nil,
          %{},
          Map.put(map, "schema", "v2"),
          Map.put(map, :schema, 1),
          Map.delete(map, "id")
        ],
        do: assert({:error, _} = Observation.from_map(input))

    {:ok, json_map} = Observation.to_map(Fixtures.observation(%{payload: {:json, 0}}))
    assert {:ok, _} = Observation.from_map(json_map)
  end

  test "wire JSON rejects duplicate and escaped alias keys before map conversion" do
    {:ok, map} = Observation.to_map(Fixtures.observation())
    {:ok, source} = Wotex.JSON.encode(map)
    assert {:ok, _} = Observation.from_json(source)

    for source <- ["{", <<255>>, 1, "{\"id\":1,\"id\":2}", ~S({"id":1,"\u0069d":2})] do
      assert {:error, _} = Observation.from_json(source)
    end

    assert {:error, _} = Observation.from_json(source, max_bytes: 0)
  end

  property "native integers and floats are never interchangeable identities" do
    check all(n <- integer(-1_000_000..1_000_000)) do
      a = Fixtures.observation(%{payload: {:json, n}})
      b = Fixtures.observation(%{payload: {:json, n / 1}})
      refute Observation.same?(a, b)
      refute Observation.identity(a) === Observation.identity(b)
    end
  end
end
