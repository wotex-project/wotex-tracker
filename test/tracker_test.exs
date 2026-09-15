defmodule Wotex.TrackerTest do
  use ExUnit.Case, async: true
  doctest Wotex.Tracker
  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.Fixtures

  test "facade imports known and unknown observations without dropping capture evidence" do
    input = Fixtures.materialisation_input()
    {:ok, catalogue} = Tracker.catalogue(input.catalogue.profiles)
    {:ok, observation} = Tracker.observation(Map.from_struct(input.observation))

    assert {:ok, result} =
             Tracker.import_observation(
               observation,
               catalogue,
               {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
             )

    assert result.resolution === input.resolution
    assert result.decoded === input.decoded
    assert {:ok, _} = Tracker.materialize(input)
    {:ok, empty} = Tracker.catalogue([])

    assert {:ok, %{decoded: nil, observation: ^observation, resolution: %{status: :unknown}}} =
             Tracker.import_observation(observation, empty, :absent)

    assert {:error, _} = Tracker.import_observation(:bad, empty, :absent)
    assert {:error, _} = Tracker.import_observation(observation, catalogue, :absent)
  end
end
