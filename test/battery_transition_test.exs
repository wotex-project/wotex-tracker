defmodule Wotex.Tracker.BatteryTransitionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    BatteryTransition,
    Evidence,
    EvidenceBundle,
    Fixtures,
    Measurement,
    MeasurementSample
  }

  test "low and clear equality transition with explicit hysteresis" do
    policy = policy()
    normal = sample("normal", 3.0, 1_000)
    low = sample("low", 2.5, 1_001)
    band = sample("band", 2.7, 1_002)
    clear = sample("clear", 2.8, 1_003)

    {:ok, baseline} = BatteryTransition.evaluate(nil, normal, policy, :live, 1_000)
    assert baseline["battery_status"] == "normal"
    assert baseline["event"] == nil

    {:ok, low_result} =
      BatteryTransition.evaluate(baseline["state"], low, policy, :live, 1_001)

    assert low_result["status"] == "transition"
    assert low_result["battery_status"] == "low"
    assert low_result["event"]["kind"] == "battery.low"
    assert low_result["event"]["event_at"] == 1_001
    assert low_result["physical_action_dispatch"] == "separate_authorization_required"

    {:ok, retained} =
      BatteryTransition.evaluate(low_result["state"], band, policy, :live, 1_002)

    assert retained["status"] == "stable"
    assert retained["reason"] == "hysteresis_retained"
    assert retained["battery_status"] == "low"
    assert retained["event"] == nil
    assert {:ok, _} = BatteryTransition.validate_state(retained["state"])

    {:ok, recovered} =
      BatteryTransition.evaluate(retained["state"], clear, policy, :live, 1_003)

    assert recovered["battery_status"] == "normal"
    assert recovered["event"]["kind"] == "battery.recovered"
    assert recovered["event"]["from_evidence_id"] == "battery-band"
    assert recovered["event"]["to_evidence_id"] == "battery-clear"
  end

  test "initial low and initial hysteresis values establish baselines without events" do
    policy = policy()

    {:ok, low} =
      BatteryTransition.evaluate(nil, sample("low", 2.0, 1_000), policy, :live, 1_000)

    assert low["status"] == "baseline"
    assert low["battery_status"] == "low"
    assert low["event"] == nil

    {:ok, band} =
      BatteryTransition.evaluate(nil, sample("band", 2.7, 1_000), policy, :live, 1_000)

    assert band["battery_status"] == "unknown"
    assert band["reason"] == "hysteresis_without_baseline"
  end

  test "unavailable, rejected suspect, stale and future values remain unknown" do
    policy = policy(%{maximum_age_ms: 10, future_skew_ms: 5})

    for {sample, now, reason} <- [
          {sample("unavailable", nil, 1_000, availability: :unavailable), 1_000,
           "measurement_unavailable"},
          {sample("suspect", 2.0, 1_000, quality: :suspect), 1_000,
           "suspect_measurement_rejected"},
          {sample("stale", 2.0, 1_000), 1_011, "measurement_stale"},
          {sample("future", 2.0, 1_006), 1_000, "measurement_in_future"}
        ] do
      assert {:ok, result} = BatteryTransition.evaluate(nil, sample, policy, :live, now)
      assert result["battery_status"] == "unknown"
      assert result["reason"] == reason
      assert result["event"] == nil
    end

    accepted = policy(%{accept_suspect: true})

    assert {:ok, %{"battery_status" => "low"}} =
             BatteryTransition.evaluate(
               nil,
               sample("accepted-suspect", 2.0, 1_000, quality: :suspect),
               accepted,
               :live,
               1_000
             )
  end

  test "an age tick clears stale canonical status without inventing recovery" do
    policy = policy(%{maximum_age_ms: 10})

    {:ok, baseline} =
      BatteryTransition.evaluate(nil, sample("low", 2.0, 1_000), policy, :live, 1_000)

    {:ok, stale} =
      BatteryTransition.evaluate(baseline["state"], nil, policy, :live, 1_011)

    assert stale["status"] == "unknown"
    assert stale["battery_status"] == "unknown"
    assert stale["reason"] == "measurement_stale"
    assert stale["event"] == nil

    {:ok, regressed} =
      BatteryTransition.evaluate(stale["state"], nil, policy, :live, 1_010)

    assert regressed["reason"] == "clock_regressed"
    assert regressed["state"] === stale["state"]
  end

  test "historical and duplicate samples do not replace the canonical measurement" do
    policy = policy()
    current = sample("current", 3.0, 1_000)
    historical = sample("historical", 2.0, 999)
    {:ok, baseline} = BatteryTransition.evaluate(nil, current, policy, :live, 1_000)

    {:ok, older} =
      BatteryTransition.evaluate(baseline["state"], historical, policy, :live, 1_001)

    assert older["sample_outcome"] == "historical"
    assert older["state"].sample.identity == current.identity
    assert older["battery_status"] == "normal"

    {:ok, duplicate} =
      BatteryTransition.evaluate(baseline["state"], current, policy, :live, 1_001)

    assert duplicate["sample_outcome"] == "duplicate"

    conflict = sample("conflict", 2.0, 1_001, evidence_id: "battery-current")

    assert {:error, %{code: :conflict}} =
             BatteryTransition.evaluate(baseline["state"], conflict, policy, :live, 1_001)
  end

  test "rule revision recomputes explicitly and live/replay events are stable" do
    original = policy()
    normal = sample("normal", 3.0, 1_000)
    low = sample("low", 2.0, 1_001)
    {:ok, baseline} = BatteryTransition.evaluate(nil, normal, original, :live, 1_000)

    {:ok, live} =
      BatteryTransition.evaluate(baseline["state"], low, original, :live, 1_001)

    {:ok, replay} =
      BatteryTransition.evaluate(baseline["state"], low, original, :replay, 1_001)

    assert replay["state"] === live["state"]
    assert replay["event"] === live["event"]
    assert replay["physical_action_dispatch"] == "prohibited"

    revised = policy(%{revision: "battery-v2", low_threshold: 3.1, clear_threshold: 3.2})

    {:ok, recomputed} =
      BatteryTransition.evaluate(baseline["state"], nil, revised, :live, 1_000)

    assert recomputed["status"] == "recomputed"
    assert recomputed["battery_status"] == "low"
    assert recomputed["event"]["kind"] == "battery.recomputed"

    assert {:error, %{code: :conflict}} =
             BatteryTransition.evaluate(
               baseline["state"],
               nil,
               policy(%{id: "other"}),
               :live,
               1_000
             )
  end

  test "measurement samples round-trip claims and choose the latest receiver source" do
    first = observation("first", 1_000)
    later = observation("later", 1_001)
    measurement = measurement(3.0)
    {:ok, claim} = Measurement.to_map(measurement)
    assert {:ok, ^measurement} = Measurement.from_map(claim)

    {:ok, evidence} =
      Evidence.new(%{
        id: "multi-source",
        kind: :measurement,
        claim: claim,
        source_observation_ids: [first.id, later.id],
        evidence_ids: [],
        profile: {"battery", "1"},
        decoder: {"battery", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([later, first], [evidence])
    {:ok, sample} = MeasurementSample.new(evidence.id, bundle)
    assert sample.observed_at == 1_001
    assert sample.observation_id == "later"
    assert {:ok, ^sample} = MeasurementSample.validate(sample)

    for invalid <- [Map.put(claim, "quality", "guess"), Map.put(claim, "extra", true)] do
      assert {:error, _} = Measurement.from_map(invalid)
    end

    assert {:error, _} = Measurement.from_map(nil)
    assert {:error, _} = MeasurementSample.new("missing", bundle)
    assert {:error, _} = MeasurementSample.validate(:invalid)
  end

  test "policy, measurement scope and state identities fail closed on mutation" do
    original = policy()

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{measurement_kind: "batteryPercentage"},
          %{unit: "%"},
          %{low_threshold: 2.4},
          %{clear_threshold: 2.9},
          %{maximum_age_ms: 2_000},
          %{future_skew_ms: 1},
          %{accept_suspect: true}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = BatteryTransition.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{low_threshold: 2.8, clear_threshold: 2.8},
          %{maximum_age_ms: -1},
          %{future_skew_ms: 604_800_001},
          %{accept_suspect: :yes},
          %{extra: true}
        ] do
      assert {:error, _} = BatteryTransition.new(Map.merge(policy_input(), change))
    end

    wrong_kind = sample("temperature", 2.0, 1_000, kind: "temperature", unit: "Cel")

    assert {:error, %{code: :conflict}} =
             BatteryTransition.evaluate(nil, wrong_kind, original, :live, 1_000)

    {:ok, baseline} =
      BatteryTransition.evaluate(nil, sample("normal", 3.0, 1_000), original, :live, 1_000)

    assert {:error, %{code: :conflict}} =
             BatteryTransition.validate_state(%{baseline["state"] | identity: "forged"})

    assert {:error, _} = BatteryTransition.validate_state(:invalid)
    assert {:error, _} = BatteryTransition.new(nil)
    assert {:error, _} = BatteryTransition.validate(:invalid)
    assert {:error, _} = BatteryTransition.evaluate(nil, nil, original, :invalid, 1_000)
  end

  property "numeric values classify on the declared side of both thresholds" do
    check all(value <- float(min: 1.0, max: 4.0)) do
      policy = policy()

      {:ok, result} =
        BatteryTransition.evaluate(
          nil,
          sample("property-#{value}", value, 1_000),
          policy,
          :replay,
          1_000
        )

      expected =
        cond do
          value <= 2.5 -> "low"
          value >= 2.8 -> "normal"
          true -> "unknown"
        end

      assert result["battery_status"] == expected
    end
  end

  defp policy(changes \\ %{}) do
    {:ok, value} = BatteryTransition.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "battery-rule",
      revision: "battery-v1",
      measurement_kind: "batteryVoltage",
      unit: "V",
      low_threshold: 2.5,
      clear_threshold: 2.8,
      maximum_age_ms: 1_000,
      future_skew_ms: 0,
      accept_suspect: false
    }

  defp sample(id, value, observed_at, options \\ []) do
    observation = observation("capture-#{id}", observed_at)
    availability = Keyword.get(options, :availability, :available)

    measurement =
      measurement(value,
        availability: availability,
        quality:
          Keyword.get(
            options,
            :quality,
            if(availability == :available, do: :valid, else: :unavailable)
          ),
        kind: Keyword.get(options, :kind, "batteryVoltage"),
        unit: Keyword.get(options, :unit, "V")
      )

    {:ok, claim} = Measurement.to_map(measurement)

    {:ok, evidence} =
      Evidence.new(%{
        id: Keyword.get(options, :evidence_id, "battery-#{id}"),
        kind: :measurement,
        claim: claim,
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"battery", "1"},
        decoder: {"battery", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, sample} = MeasurementSample.new(evidence.id, bundle)
    sample
  end

  defp measurement(value, options \\ []) do
    availability = Keyword.get(options, :availability, :available)

    quality =
      Keyword.get(
        options,
        :quality,
        if(availability == :available, do: :valid, else: :unavailable)
      )

    {:ok, measurement} =
      Measurement.new(%{
        kind: Keyword.get(options, :kind, "batteryVoltage"),
        value: if(availability == :available, do: value, else: nil),
        unit: Keyword.get(options, :unit, "V"),
        availability: availability,
        quality: quality,
        raw: value,
        reason: "fixture"
      })

    measurement
  end

  defp observation(id, observed_at),
    do: Fixtures.observation(%{id: id, observed_at: observed_at})
end
