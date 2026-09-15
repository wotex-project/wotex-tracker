defmodule Wotex.Tracker.PositionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Wotex.Tracker.{EvidenceBundle, Fixtures, Position, PositionFreshness}

  test "zero coordinates, distinct clocks, source units and provenance round-trip without coercion" do
    {position, bundle} =
      sample(%{
        "latitude" => 0,
        "longitude" => 0.0,
        "altitude_m" => 0,
        "speed_m_s" => 0.0,
        "fix_at" => -10,
        "device_at" => 0,
        "received_at" => 9_007_199_254_740_993
      })

    assert {:ok, map} = Position.to_map(position, bundle)
    assert map["profile"] == ["synthetic", "1"]
    assert map["decoder"] == ["synthetic", "1"]
    assert map["source_observation_ids"] == ["observation-1"]
    assert map["parent_evidence_ids"] == []
    assert map["confidence"] == "exact"
    assert map["reasons"] == ["synthetic"]
    assert map["association_id"] == "operator-association"
    assert map["position"]["latitude"] === 0
    assert map["position"]["longitude"] === 0.0
    assert map["position"]["speed_m_s"] === 0.0
    assert map["position"]["horizontal_accuracy_m"] == nil
    assert map["position"]["accuracy_kind"] == "unknown"
    assert map["position"]["raw"] == %{"longitude_raw" => 0, "speed_raw" => 0.0, "missing" => nil}
    assert map["position"]["source_units"]["speed"] == "km/h"
    assert {:ok, encoded} = Wotex.JSON.encode(map)
    assert {:ok, decoded} = Wotex.JSON.decode(encoded)
    assert decoded === map
    assert {:ok, ^position} = Position.validate(position, bundle)
  end

  test "admission rejects partial coordinates, invalid units, unknown fields and invalid clocks" do
    invalid = [
      %{"latitude" => 90.0001},
      %{"latitude" => -90.0001},
      %{"longitude" => 180.0001},
      %{"longitude" => -180.0001},
      %{"latitude" => nil},
      %{"longitude" => "0"},
      %{"availability" => "unavailable"},
      %{"quality" => "unavailable"},
      %{"source" => "ai_guess"},
      %{"altitude_m" => 100_000_001},
      %{"speed_m_s" => -1},
      %{"speed_m_s" => 100_001},
      %{"horizontal_accuracy_m" => 0},
      %{"accuracy_kind" => "bound"},
      %{"horizontal_accuracy_m" => -1, "accuracy_kind" => "estimate"},
      %{"horizontal_accuracy_m" => 40_100_001, "accuracy_kind" => "bound"},
      %{"fix_at" => 1.0},
      %{"fix_at" => nil},
      %{"fix_clock" => "monotonic"},
      %{"device_at" => false},
      %{"device_at" => nil},
      %{"received_at" => "1000"},
      %{"conversion_revision" => ""},
      %{"receiver_observation_id" => ""},
      %{"schema" => "wtr.position.v2"},
      %{"extra" => 1},
      %{"source_units" => %{}},
      %{"raw" => []}
    ]

    for change <- invalid do
      bundle = bundle(change)
      assert {:error, _} = Position.new("position-1", bundle), inspect(change)
    end

    claim = claim()

    for units <- [
          nil,
          Map.delete(claim["source_units"], "speed"),
          Map.put(claim["source_units"], "speed", nil),
          Map.put(claim["source_units"], "speed", ""),
          Map.put(claim["source_units"], "extra", "m")
        ] do
      assert {:error, _} = Position.new("position-1", bundle(%{"source_units" => units}))
    end

    evidence =
      Fixtures.evidence(%{
        id: "position-1",
        kind: :position,
        claim: Map.delete(claim, "latitude")
      })

    {:ok, bundle} = EvidenceBundle.new([Fixtures.observation()], [evidence])
    assert {:error, _} = Position.new("position-1", bundle)
    assert {:error, _} = Position.new("missing", bundle())
    assert {:error, _} = Position.new("position-1", :forged)
    assert {:error, _} = Position.new("position-1", bundle(), unknown: true)
    assert {:error, _} = Position.validate(%{}, bundle())
    assert {:error, _} = Position.to_map(:invalid, bundle())
  end

  test "valid boundaries and unavailable coordinates preserve independent speed and source uncertainty" do
    for {latitude, longitude} <- [{-90, -180}, {90.0, 180.0}] do
      {position, _} =
        sample(%{
          "latitude" => latitude,
          "longitude" => longitude,
          "altitude_m" => -100_000_000,
          "speed_m_s" => 100_000,
          "horizontal_accuracy_m" => 40_100_000,
          "source_units" => Map.put(claim()["source_units"], "accuracy", "m"),
          "accuracy_kind" => "estimate"
        })

      assert position.claim["latitude"] === latitude
    end

    for accuracy <- [0, 0.0, 10] do
      {position, _} =
        sample(%{
          "horizontal_accuracy_m" => accuracy,
          "accuracy_kind" => "bound",
          "source_units" => Map.put(claim()["source_units"], "accuracy", "m")
        })

      assert position.claim["horizontal_accuracy_m"] === accuracy
    end

    {position, _} =
      sample(%{
        "availability" => "unavailable",
        "quality" => "unavailable",
        "latitude" => nil,
        "longitude" => nil,
        "altitude_m" => nil,
        "fix_at" => nil,
        "fix_clock" => "unknown",
        "device_at" => nil,
        "device_clock" => "unknown"
      })

    assert position.claim["speed_m_s"] == 0.0
    assert position.claim["latitude"] == nil
  end

  test "claim content, capture identity and receiver clock cannot be substituted" do
    {position, bundle} = sample()

    assert {:error, %{code: :conflict}} =
             Position.validate(
               %{position | claim: Map.put(position.claim, "latitude", 1)},
               bundle
             )

    {_, other} = sample(%{"raw" => %{"changed" => true}})
    assert {:error, %{code: :conflict}} = Position.validate(position, other)
    assert {:error, _} = Position.validate(%{position | bundle_identity: "forged"}, bundle)
    assert {:error, _} = Position.new("position-1", %{bundle | identity: "forged"})
    claim = bundle.evidence["position-1"]

    for changed <- [
          %{claim | kind: :measurement},
          %{claim | claim: Map.put(claim.claim, "received_at", 1001)},
          %{claim | claim: Map.put(claim.claim, "receiver_observation_id", "other")}
        ] do
      {:ok, other} = EvidenceBundle.new(Map.values(bundle.observations), [changed])
      assert {:error, _} = Position.new("position-1", other)
    end
  end

  test "freshness boundaries use the qualified fix clock and retain the exact decision inputs" do
    policy = policy()

    for {now, status, age} <- [
          {1000, "fresh", 0},
          {1010, "fresh", 10},
          {1011, "stale", 11},
          {999, "fresh", -1},
          {998, "unknown", nil}
        ] do
      {position, bundle} = sample()
      assert {:ok, result} = PositionFreshness.evaluate(position, bundle, policy, now)
      assert result["status"] == status
      assert result["age_ms"] == age
      assert result["evidence_id"] == position.evidence_id
      assert result["bundle_identity"] == bundle.identity
      assert result["policy_revision"] == "fixture-v1"
      assert result["policy_identity"] == policy.identity
      assert result["evaluated_at"] === now
    end

    {position, bundle} = sample(%{"fix_at" => -10, "device_at" => 999, "received_at" => 1000})

    {:ok, result} =
      PositionFreshness.evaluate(position, bundle, policy(%{missing_fix: :receiver_time}), 1000)

    assert result["status"] == "stale"
    assert result["time_basis"] == "fix"
    assert result["age_ms"] == 1010
  end

  test "missing, untrusted, inconsistent and unavailable evidence is never silently fresh" do
    cases = [
      {%{"fix_at" => nil, "fix_clock" => "unknown"}, %{}, "unknown", "missing_fix_time"},
      {%{"fix_at" => nil, "fix_clock" => "unknown"}, %{missing_fix: :receiver_time}, "fresh",
       "within_window"},
      {%{"fix_clock" => "untrusted"}, %{missing_fix: :receiver_time}, "unknown",
       "untrusted_fix_clock"},
      {%{"fix_clock" => "unknown"}, %{missing_fix: :receiver_time}, "unknown",
       "untrusted_fix_clock"},
      {%{"fix_at" => 1002}, %{}, "unknown", "fix_after_reception"},
      {%{"fix_at" => 1002, "received_at" => 1001}, %{}, "future", "future_skew_exceeded"},
      {%{"received_at" => 1002}, %{}, "unknown", "receiver_in_future"},
      {%{"quality" => "suspect"}, %{}, "unknown", "suspect"},
      {%{"quality" => "suspect"}, %{accept_suspect: true}, "fresh", "within_window"},
      {%{
         "availability" => "unavailable",
         "quality" => "unavailable",
         "latitude" => nil,
         "longitude" => nil
       }, %{}, "unknown", "unavailable"}
    ]

    for {change, options, status, reason} <- cases do
      {position, bundle} = sample(change)
      assert {:ok, result} = PositionFreshness.evaluate(position, bundle, policy(options), 1000)
      assert result["status"] == status
      assert result["reason"] == reason
    end
  end

  test "policy identity binds every threshold and caller time has no implicit conversion" do
    original = policy()

    for change <- [
          %{revision: "changed"},
          %{max_age_ms: 9},
          %{future_skew_ms: 2},
          %{missing_fix: :receiver_time},
          %{accept_suspect: true}
        ] do
      refute policy(change).identity == original.identity
      assert {:error, _} = PositionFreshness.validate(struct(original, change))
    end

    for change <- [
          %{max_age_ms: -1},
          %{max_age_ms: 604_800_001},
          %{future_skew_ms: -1},
          %{future_skew_ms: 604_800_001},
          %{max_age_ms: 1.0},
          %{missing_fix: :device_time},
          %{accept_suspect: nil},
          %{revision: ""},
          %{extra: true}
        ] do
      assert {:error, _} = PositionFreshness.new(Map.merge(policy_input(), change))
    end

    assert {:ok, _} =
             PositionFreshness.new(policy_input(%{max_age_ms: 0, future_skew_ms: 604_800_000}))

    assert {:error, _} = PositionFreshness.new(nil)
    assert {:error, _} = PositionFreshness.new(policy_input(), max_bytes: 1)
    assert {:error, _} = PositionFreshness.validate(:invalid)
    {position, bundle} = sample()
    assert {:error, _} = PositionFreshness.evaluate(position, bundle, original, 1000.0)
    assert {:error, _} = PositionFreshness.evaluate(:invalid, bundle, original, 1000)
    assert {:error, _} = PositionFreshness.evaluate(position, bundle, :invalid, 1000)
  end

  property "a later reception cannot refresh the same old fix, while each capture keeps its identity" do
    check all(fix <- integer(-1_000_000..1_000_000), delay <- integer(11..1000)) do
      {first, a} = sample(%{"fix_at" => fix, "received_at" => fix})
      {later, b} = sample(%{"fix_at" => fix, "received_at" => fix + delay})
      policy = policy(%{missing_fix: :receiver_time})
      {:ok, one} = PositionFreshness.evaluate(first, a, policy, fix + delay)
      {:ok, two} = PositionFreshness.evaluate(later, b, policy, fix + delay)
      assert one["status"] == "stale" and two["status"] == "stale"
      assert one["age_ms"] == delay and two["age_ms"] == delay
      refute first.bundle_identity == later.bundle_identity
    end
  end

  defp sample(change \\ %{}) do
    bundle = bundle(change)
    {:ok, position} = Position.new("position-1", bundle)
    {position, bundle}
  end

  defp bundle(change \\ %{}) do
    claim = Map.merge(claim(), change)
    # The capture time is an integer even in negative admission cases.
    received = if is_integer(claim["received_at"]), do: claim["received_at"], else: 1000
    observation = Fixtures.observation(%{observed_at: received})

    evidence =
      Fixtures.evidence(%{
        id: "position-1",
        kind: :position,
        claim: claim,
        association_id: "operator-association"
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    bundle
  end

  defp claim,
    do: %{
      "schema" => "wtr.position.v1",
      "latitude" => 0.0,
      "longitude" => 0.0,
      "altitude_m" => 0,
      "speed_m_s" => 0.0,
      "horizontal_accuracy_m" => nil,
      "accuracy_kind" => "unknown",
      "source" => "gnss",
      "fix_at" => 1000,
      "device_at" => 1001,
      "received_at" => 1000,
      "fix_clock" => "trusted",
      "device_clock" => "untrusted",
      "availability" => "available",
      "quality" => "valid",
      "source_units" => %{
        "latitude" => "degree",
        "longitude" => "degree",
        "altitude" => "m",
        "speed" => "km/h",
        "accuracy" => nil,
        "fix_time" => "unix-ms",
        "device_time" => "unix-ms",
        "receiver_time" => "unix-ms"
      },
      "conversion_revision" => "synthetic-units-v1",
      "receiver_observation_id" => "observation-1",
      "raw" => %{"longitude_raw" => 0, "speed_raw" => 0.0, "missing" => nil}
    }

  defp policy_input(change \\ %{}),
    do:
      Map.merge(
        %{
          revision: "fixture-v1",
          max_age_ms: 10,
          future_skew_ms: 1,
          missing_fix: :unknown,
          accept_suspect: false
        },
        change
      )

  defp policy(change \\ %{}) do
    {:ok, policy} = PositionFreshness.new(policy_input(change))
    policy
  end
end
