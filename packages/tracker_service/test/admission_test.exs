defmodule Wotex.Tracker.Service.AdmissionTest do
  @moduledoc false

  use ExUnit.Case, async: true
  use ExUnitProperties
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Service.{Codec, Store, Update}

  property "durable observation encoding preserves arbitrary bytes and strict native JSON types" do
    check all(bytes <- binary(max_length: 512), value <- integer()) do
      observation =
        observation(%{
          payload: {:bytes, bytes},
          source: %{"n" => value, "f" => value / 1, "bool" => false, "nil" => nil}
        })

      {:ok, map} = Observation.to_map(observation)

      assert {:ok, restored} =
               map |> Codec.encode!() |> Codec.decode!() |> Observation.from_map()

      assert restored === observation
    end
  end

  test "malformed prepared transactions and forged structs are rejected before a store call" do
    invalid = [
      nil,
      [],
      %{},
      Map.delete(update_input(), :events),
      Map.put(update_input(), :extra, true)
    ]

    for value <- invalid, do: assert({:error, :invalid_update} = Update.new(value))

    for changes <- [
          %{principal: ""},
          %{scope: <<255>>},
          %{operation_id: String.duplicate("x", 257)},
          %{expected_generation: "01"},
          %{now: -1},
          %{request: %{atom: "no"}},
          %{observation: %{}},
          %{records: :bad},
          %{records: List.duplicate(%{kind: "state", id: "a", value: nil}, 17)},
          %{records: [%{kind: "custom", id: "a", value: 1}]},
          %{records: [%{kind: "state", id: "a"}]},
          %{records: [%{kind: "state", id: "a", value: 1}, %{kind: "state", id: "a", value: 2}]},
          %{events: [1]},
          %{events: [%{"type" => "custom", "data" => %{}}]},
          %{
            events: [
              %{"type" => "tracker.event", "data" => %{"large" => String.duplicate("x", 16_384)}}
            ]
          },
          %{publication: %{}},
          %{publication: %{thing_id: "thing", deployment_id: "1", td: %{}}}
        ],
        do: assert({:error, :invalid_update} = Update.new(update_input(changes)))

    assert {:error, :invalid_update} = Update.validate(nil)

    assert {:error, :invalid_update} =
             Store.mutate(%Store{pid: self(), slots: make_ref(), timeout: 1}, %{
               update()
               | now: :forged
             })
  end

  test "encoded byte limit accounts for escaping and framing, not only raw string length" do
    assert {:error, :invalid_json} = Codec.encode("\n\n\n", 4)
    assert {:error, :invalid_json} = Codec.encode(String.duplicate("x", 1_048_577))
    assert {:error, _} = Codec.decode(~s({"x":1,"x":2}))
    assert :error = Codec.generation("-1")
    assert :error = Codec.generation("1x")
    assert :error = Codec.generation(1)
    assert :error = Codec.generation("9223372036854775807")
    assert {:ok, 9_007_199_254_740_993} = Codec.generation("9007199254740993")
  end

  test "all admitted observation facts participate in idempotency even if request metadata is incomplete" do
    {store, _} = store()
    assert {:ok, _} = Store.mutate(store, update())

    assert {:error, :idempotency_conflict} =
             Store.mutate(store, update(%{observation: observation(%{observed_at: 1})}))
  end
end
