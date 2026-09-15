defmodule Wotex.Tracker.EvidenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Wotex.Tracker.{Error, Evidence, EvidenceBundle, Fixtures, Identity}

  test "closed bundle identity is independent of insertion order and equal repeats" do
    o = Fixtures.observation()
    a = Fixtures.evidence()
    b = Fixtures.identity_evidence()
    assert {:ok, one} = EvidenceBundle.new([o], [a, b])
    assert {:ok, two} = EvidenceBundle.new([o, o], [b, a, b])
    assert one === two
    assert {:ok, ^one} = EvidenceBundle.validate(one)
    assert {:ok, wire} = Evidence.to_map(a)
    assert wire["profile"] == ["synthetic", "1"]
    assert wire["kind"] == "measurement"
    assert wire["claim"]["value"] === 0
  end

  test "bundle identity changes with every interpretation-relevant field" do
    original = Fixtures.bundle()
    a = Fixtures.evidence()

    changes = %{
      claim: %{"value" => 0.0, "unit" => "Cel", "quality" => "valid"},
      confidence: :candidate,
      reasons: ["changed"],
      kind: :capability,
      association_id: "enrollment-1",
      evidence_ids: ["identity-1"]
    }

    for {key, value} <- changes do
      assert {:ok, bundle} =
               EvidenceBundle.new([Fixtures.observation()], [
                 Map.put(a, key, value),
                 Fixtures.identity_evidence()
               ])

      refute bundle.identity === original.identity
    end

    for claim <- [
          %{"value" => 0, "unit" => "K", "quality" => "valid"},
          %{"value" => 0, "unit" => "Cel", "quality" => "suspect"},
          %{"value" => 0, "unit" => "Cel", "quality" => "valid", "extension" => false}
        ] do
      {:ok, bundle} =
        EvidenceBundle.new([Fixtures.observation()], [
          Fixtures.evidence(%{claim: claim}),
          Fixtures.identity_evidence()
        ])

      refute bundle.identity == original.identity
    end

    {:ok, bundle} =
      EvidenceBundle.new([Fixtures.observation(%{observed_at: 1})], [
        a,
        Fixtures.identity_evidence()
      ])

    refute bundle.identity == original.identity
  end

  test "conflicts use complete strict content, including values that compare equal loosely" do
    a = Fixtures.observation(%{payload: {:json, 1}})
    b = Fixtures.observation(%{payload: {:json, 1.0}})
    assert {:error, %Error{code: :conflict}} = EvidenceBundle.new([a, b], [])

    assert {:error, %Error{code: :conflict}} =
             EvidenceBundle.new([a], [
               Fixtures.evidence(),
               Fixtures.evidence(%{claim: %{"value" => 0.0}})
             ])

    assert {:error, _} = EvidenceBundle.new([:forged], [])
    assert {:error, _} = EvidenceBundle.new([a], [:forged])
    assert {:error, _} = EvidenceBundle.new([a | :bad], [])
    assert {:error, _} = EvidenceBundle.new([a, a], [], max_claims: 1)
    assert {:error, _} = EvidenceBundle.new([], [], unknown: 1)
    assert {:ok, _} = EvidenceBundle.new([], [])
  end

  test "dangling, cyclic, too-deep and mismatched lineage fail" do
    observation = Fixtures.observation()

    for {claim, code} <- [
          {Fixtures.evidence(%{source_observation_ids: ["missing"]}), :dangling_reference},
          {Fixtures.evidence(%{evidence_ids: ["missing"]}), :dangling_reference},
          {Fixtures.evidence(%{evidence_ids: ["claim-1"]}), :evidence_cycle}
        ] do
      assert {:error, %Error{code: ^code}} = EvidenceBundle.new([observation], [claim])
    end

    a = Fixtures.evidence(%{evidence_ids: ["claim-2"]})
    b = Fixtures.evidence(%{id: "claim-2", evidence_ids: ["claim-1"]})
    assert {:error, %Error{code: :evidence_cycle}} = EvidenceBundle.new([observation], [a, b])
    b = Fixtures.evidence(%{id: "claim-2"})
    assert {:ok, _} = EvidenceBundle.new([observation], [a, b], max_lineage_depth: 2)

    assert {:error, %Error{code: :limit_exceeded}} =
             EvidenceBundle.new([observation], [a, b], max_lineage_depth: 1)

    assert {:error, %Error{code: :revision_mismatch}} =
             EvidenceBundle.new([observation], [
               b,
               Fixtures.evidence(%{decoder: {"different", "2"}})
             ])

    assert {:error, %Error{code: :association_mismatch}} =
             EvidenceBundle.new([observation], [
               Fixtures.identity_evidence(),
               Fixtures.evidence(%{association_id: "other"})
             ])
  end

  test "forged bundles are re-admitted and their content digests are checked" do
    bundle = Fixtures.bundle()

    for changed <- [
          nil,
          %{bundle | observations: []},
          %{bundle | identity: "forged"},
          %{bundle | observations: %{"different" => Fixtures.observation()}},
          %{bundle | evidence: %{"claim-1" => :forged}},
          %{bundle | evidence: %{"claim-1" => %{__struct__: Evidence}}},
          %{
            bundle
            | observations: %{"observation-1" => %{__struct__: Wotex.Tracker.Observation}}
          },
          %{
            bundle
            | observations: %{"observation-1" => %{Fixtures.observation() | observed_at: false}}
          }
        ] do
      assert {:error, _} = EvidenceBundle.validate(changed)
    end

    assert {:error, _} = EvidenceBundle.validate(bundle, max_claims: 1)
  end

  test "claim constructors reject hostile or excessive output before publication" do
    for input <- [nil, %{}, Fixtures.evidence()], do: assert({:error, _} = Evidence.new(input))

    for {key, value} <- [
          id: "",
          kind: :other,
          confidence: 0.99,
          claim: %{value: 1},
          source_observation_ids: [],
          source_observation_ids: ["observation-1", "observation-1"],
          evidence_ids: ["x" | :bad],
          profile: nil,
          decoder: {"x", ""},
          reasons: ["", "x"],
          association_id: false
        ] do
      assert {:error, _} = Evidence.new(Fixtures.evidence_input(%{key => value}))
    end

    assert {:error, _} = Evidence.validate(:forged)
    assert {:error, _} = Evidence.to_map(:forged)
    assert {:error, _} = Evidence.new(Fixtures.evidence_input(), max_sources: 0)

    assert {:error, _} =
             Evidence.new(Fixtures.evidence_input(%{evidence_ids: ["a", "b"]}), max_sources: 1)

    # Aggregate admitted claim JSON has its own bound, not just a per-claim check.
    a = Fixtures.evidence(%{claim: %{"text" => String.duplicate("a", 4000)}})
    b = Fixtures.evidence(%{id: "b", claim: %{"text" => String.duplicate("b", 4000)}})
    assert {:error, _} = EvidenceBundle.new([Fixtures.observation()], [a, b], max_bytes: 6000)
  end

  test "explicit UUID identity binds complete association evidence and immutable snapshot" do
    bundle = Fixtures.bundle()
    input = Fixtures.identity_input()
    assert {:ok, identity} = Identity.new(input, bundle)
    assert {:ok, ^identity} = Identity.validate(identity, bundle)

    for change <- [
          %{input | thing_id: "CB:B8:33:4C:88:4F"},
          %{input | thing_id: "urn:imei:123"},
          %{input | evidence_id: "missing"},
          %{input | evidence_id: "claim-1"},
          %{input | association_id: "other"},
          %{input | revision: "2"},
          %{}
        ] do
      assert {:error, _} = Identity.new(change, bundle)
    end

    assert {:error, _} = Identity.validate(:forged, bundle)
    assert {:error, _} = Identity.validate(%{identity | bundle_identity: "forged"}, bundle)
    assert {:error, _} = Identity.validate(%{identity | revision: "2"}, bundle)
    assert {:error, _} = Identity.new(input, :forged)

    {:ok, mixed} =
      EvidenceBundle.new([Fixtures.observation(), Fixtures.observation(%{id: "other-device"})], [
        Fixtures.identity_evidence()
      ])

    assert {:error, %Error{code: :association_mismatch}} = Identity.new(input, mixed)
  end

  property "DAG insertion order cannot change lineage acceptance or digest" do
    check all(count <- integer(2..12), ordering <- list_of(integer(), length: 12)) do
      claims =
        for n <- 1..count do
          parents = if n == 1, do: [], else: Enum.map(1..(n - 1), &"claim-#{&1}")
          Fixtures.evidence(%{id: "claim-#{n}", evidence_ids: parents})
        end

      shuffled =
        claims |> Enum.zip(ordering) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

      assert {:ok, bundle} = EvidenceBundle.new([Fixtures.observation()], claims)
      assert {:ok, ^bundle} = EvidenceBundle.new([Fixtures.observation()], shuffled)
    end
  end
end
