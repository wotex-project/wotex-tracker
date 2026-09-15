defmodule Wotex.Tracker.ResolutionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Wotex.Tracker.{Catalogue, DeviceProfile, Error, Fixtures, Predicate, Resolution}

  test "resolution preserves exact, unknown, ambiguous and candidate-only outcomes" do
    exact = Fixtures.profile()
    strong = Fixtures.profile(%{id: "strong", confidence: :strong})
    candidate = Fixtures.profile(%{id: "candidate", confidence: :candidate})
    weak = Fixtures.profile(%{id: "weak", confidence: :unknown})
    other = Fixtures.profile(%{id: "other"})

    cases = [
      {[], :unknown, :no_match, nil},
      {[exact], :resolved, :unique_best_match, exact},
      {[strong], :resolved, :unique_best_match, strong},
      {[candidate, weak], :unknown, :insufficient_evidence, nil},
      {[strong, exact, candidate], :resolved, :unique_best_match, exact},
      {[exact, other, strong], :ambiguous, :equal_best_matches, nil}
    ]

    for {profiles, status, reason, selected} <- cases do
      {:ok, catalogue} = Catalogue.new(profiles)
      assert {:ok, resolution} = Resolution.resolve(Fixtures.observation(), catalogue)
      assert resolution.status == status
      assert resolution.reason == reason
      assert resolution.selected === selected

      assert {:ok, ^resolution} =
               Resolution.validate(resolution, Fixtures.observation(), catalogue)

      assert resolution.candidates == Enum.sort_by(resolution.candidates, & &1.profile)
    end

    {:ok, catalogue} = Catalogue.new([exact])

    assert {:ok, %{status: :unknown}} =
             Resolution.resolve(Fixtures.observation(%{payload: {:bytes, <<7>>}}), catalogue)
  end

  test "all predicates are conjunctive and native comparisons are type-strict" do
    definitions = [
      {%{"op" => "byte", "offset" => 0, "value" => 5}, true},
      {%{"op" => "byte", "offset" => 2, "value" => 5}, false},
      {%{"op" => "length", "value" => 2}, true},
      {%{"op" => "eq", "field" => "ingress", "pointer" => "", "value" => "ble"}, true},
      {%{
         "op" => "eq",
         "field" => "source",
         "pointer" => "/receiver_id",
         "value" => "fixture-receiver"
       }, true},
      {%{
         "op" => "eq",
         "field" => "addressing",
         "pointer" => "/address_type",
         "value" => "random"
       }, true},
      {%{"op" => "eq", "field" => "radio", "pointer" => "/rssi", "value" => -70.0}, false},
      {%{"op" => "eq", "field" => "transport", "pointer" => "/missing", "value" => nil}, false},
      {%{"op" => "eq", "field" => "provenance", "pointer" => "/kind", "value" => "fixture"},
       true},
      {%{"op" => "eq", "field" => "payload_json", "pointer" => "/version", "value" => 5}, false},
      {%{"op" => "member", "field" => "radio", "pointer" => "/rssi", "value" => -70}, false}
    ]

    for {definition, expected} <- definitions do
      {:ok, predicate} = Predicate.new(definition)
      assert {:ok, ^expected} = Predicate.match?(predicate, Fixtures.observation())
    end

    {:ok, predicate} =
      Predicate.new(%{
        "op" => "member",
        "field" => "transport",
        "pointer" => "/service_uuids",
        "value" => "180a"
      })

    assert Predicate.discriminating?(predicate)

    assert {:ok, true} =
             Predicate.match?(
               predicate,
               Fixtures.observation(%{transport: %{"service_uuids" => ["180a"]}})
             )

    assert {:ok, false} =
             Predicate.match?(
               predicate,
               Fixtures.observation(%{transport: %{"service_uuids" => []}})
             )

    {:ok, predicate} =
      Predicate.new(%{
        "op" => "eq",
        "field" => "payload_json",
        "pointer" => "/version",
        "value" => 5
      })

    assert Predicate.discriminating?(predicate)

    assert {:ok, true} =
             Predicate.match?(
               predicate,
               Fixtures.observation(%{payload: {:json, %{"version" => 5}}})
             )

    {:ok, bytes} = Predicate.new(%{"op" => "length", "value" => 0})
    assert {:ok, false} = Predicate.match?(bytes, Fixtures.observation(%{payload: {:json, %{}}}))

    {:ok, escaped} =
      Predicate.new(%{
        "op" => "eq",
        "field" => "transport",
        "pointer" => "/a~1b~0c",
        "value" => false
      })

    assert {:ok, true} =
             Predicate.match?(escaped, Fixtures.observation(%{transport: %{"a/b~c" => false}}))

    profile =
      Fixtures.profile(%{
        fingerprints: [hd(Fixtures.profile().fingerprints), %{"op" => "length", "value" => 24}]
      })

    {:ok, catalogue} = Catalogue.new([profile])
    assert {:ok, %{status: :unknown}} = Resolution.resolve(Fixtures.observation(), catalogue)
  end

  test "invalid predicates and weak-only strong/exact profiles are rejected" do
    for definition <- [
          nil,
          %{},
          %{"op" => "callback", "module" => "Danger"},
          %{"op" => "byte", "offset" => -1, "value" => 5},
          %{"op" => "byte", "offset" => 0, "value" => 256},
          %{"op" => "length", "value" => 2.0},
          %{"op" => "eq", "field" => "source", "pointer" => "bad", "value" => nil},
          %{"op" => "eq", "field" => "source", "pointer" => "/~2", "value" => nil},
          %{"op" => "eq", "field" => "unknown", "pointer" => "", "value" => nil}
        ] do
      assert {:error, _} = Predicate.new(definition)
    end

    for definition <- [
          %{"op" => "eq", "field" => "radio", "pointer" => "/rssi", "value" => -70},
          %{"op" => "eq", "field" => "addressing", "pointer" => "/name", "value" => "Ruuvi"}
        ] do
      for confidence <- [:exact, :strong] do
        assert {:error, %Error{code: :invalid_profile}} =
                 DeviceProfile.new(
                   Fixtures.profile_input(%{fingerprints: [definition], confidence: confidence})
                 )
      end

      assert {:ok, _} =
               DeviceProfile.new(
                 Fixtures.profile_input(%{fingerprints: [definition], confidence: :candidate})
               )
    end

    assert {:error, _} = Predicate.match?(%Predicate{document: %{}}, Fixtures.observation())
    assert {:error, _} = Predicate.match?(:forged, Fixtures.observation())

    assert {:error, _} =
             Predicate.match?(%Predicate{document: hd(Fixtures.profile().fingerprints)}, :forged)

    for change <- [
          %{confidence: :fake},
          %{fingerprints: []},
          %{fingerprints: [%{}]},
          %{fingerprints: List.duplicate(hd(Fixtures.profile().fingerprints), 33)},
          %{id: ""},
          %{decoder: nil},
          %{model: nil},
          %{mapping_revision: ""},
          %{mapping: :bad},
          %{source_provenance: :bad}
        ] do
      assert {:error, _} = DeviceProfile.new(Fixtures.profile_input(change))
    end

    for input <- [nil, %{}, Fixtures.profile()],
        do: assert({:error, _} = DeviceProfile.new(input))

    assert {:error, _} = DeviceProfile.validate(:forged)
    assert {:error, _} = DeviceProfile.to_map(:forged)
    assert {:error, _} = DeviceProfile.identity(:forged)
  end

  test "snapshots bind full profile revisions and reject duplicates and forgeries" do
    profile = Fixtures.profile()
    {:ok, identity} = DeviceProfile.identity(profile)

    for {key, value} <- %{
          id: "changed",
          version: "2",
          confidence: :strong,
          fingerprints: [%{"op" => "byte", "offset" => 0, "value" => 6}],
          decoder: {"synthetic", "2"},
          model: {"urn:wotex:tm:environment", "2"},
          mapping_revision: "2",
          mapping: %{"temperature" => "/properties/other"},
          source_provenance: %{"kind" => "synthetic", "revision" => "2"}
        } do
      assert {:ok, changed} = DeviceProfile.identity(Map.put(profile, key, value))
      refute changed == identity
    end

    assert {:error, %Error{code: :duplicate_id}} = Catalogue.new([profile, profile])

    assert {:error, %Error{code: :duplicate_id}} =
             Catalogue.new([profile, %{profile | confidence: :strong}])

    assert {:error, _} = Catalogue.new([:forged])
    assert {:error, _} = Catalogue.new(:forged)
    assert {:error, _} = Catalogue.validate(:forged)
    {:ok, catalogue} = Catalogue.new([profile])
    assert {:error, _} = Catalogue.validate(%{catalogue | identity: "wrong"})
    assert {:error, _} = Catalogue.validate(%{catalogue | profiles: [:forged]})
    {:ok, resolution} = Resolution.resolve(Fixtures.observation(), catalogue)

    assert {:error, _} =
             Resolution.validate(%{resolution | selected: nil}, Fixtures.observation(), catalogue)

    assert {:error, _} =
             Resolution.validate(resolution, Fixtures.observation(%{id: "new"}), catalogue)

    assert {:error, _} = Resolution.validate(resolution, :forged, catalogue)
    assert {:error, _} = Resolution.resolve(Fixtures.observation(), :forged)
    assert {:error, _} = Resolution.resolve(Fixtures.observation(), catalogue, invalid: 1)
  end

  test "catalogue and candidate exhaustion cannot truncate an ambiguity" do
    profiles = for n <- 1..256, do: Fixtures.profile(%{id: "profile-#{n}"})

    for size <- [255, 256] do
      assert {:ok, catalogue} = Catalogue.new(Enum.take(profiles, size))

      assert {:ok, %{status: :ambiguous, candidates: candidates}} =
               Resolution.resolve(Fixtures.observation(), catalogue)

      assert length(candidates) == size
    end

    assert {:error, %Error{code: :limit_exceeded}} =
             Catalogue.new([Fixtures.profile(%{id: "extra"}) | profiles])

    {:ok, catalogue} = Catalogue.new(Enum.take(profiles, 2))

    assert {:error, %Error{code: :limit_exceeded}} =
             Resolution.resolve(Fixtures.observation(), catalogue, max_candidates: 1)

    for size <- [31, 32] do
      assert {:ok, _} =
               DeviceProfile.new(
                 Fixtures.profile_input(%{
                   fingerprints: List.duplicate(hd(Fixtures.profile().fingerprints), size)
                 })
               )
    end
  end

  property "catalogue permutation changes neither snapshot nor resolution" do
    check all(
            priorities <-
              list_of(member_of([:exact, :strong, :candidate, :unknown]),
                min_length: 1,
                max_length: 12
              ),
            rotation <- integer(0..12)
          ) do
      profiles =
        priorities
        |> Enum.with_index()
        |> Enum.map(fn {confidence, n} ->
          Fixtures.profile(%{id: "p#{n}", confidence: confidence})
        end)

      {:ok, catalogue} = Catalogue.new(profiles)
      {a, b} = Enum.split(profiles, rotation)
      assert {:ok, ^catalogue} = Catalogue.new(b ++ a)

      assert Resolution.resolve(Fixtures.observation(), catalogue) ===
               Resolution.resolve(
                 Fixtures.observation(),
                 elem(Catalogue.new(Enum.reverse(profiles)), 1)
               )
    end
  end
end
