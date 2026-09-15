defmodule Wotex.Tracker.PositionMovementTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample
  }

  @degree_m 111_195.05197522942

  test "pinned authalic distance and threshold equality classify movement" do
    from = sample("from", 0, 0, 0)
    to = sample("to", 0, 1, 1_000)

    exact =
      policy(%{
        moving_speed_m_s: @degree_m,
        stationary_speed_m_s: 0,
        moving_distance_m: @degree_m,
        stationary_distance_m: 0,
        max_plausible_speed_m_s: @degree_m + 1
      })

    assert {:ok, result} = PositionMovement.evaluate(from, to, exact, 1_000)
    assert result["status"] == "moving"
    assert result["reason"] == "movement_thresholds_met"
    assert_in_delta result["center_distance_m"], @degree_m, 1.0e-6
    assert_in_delta result["lower_speed_m_s"], @degree_m, 1.0e-6
    assert result["lower_distance_m"] == result["upper_distance_m"]
    assert result["algorithm"] == "wgs84-authalic-bounded-segment-v1"
  end

  test "stationary equality and hysteresis stay distinct from movement" do
    from = sample("from", 10, 10, 1_000)
    same = sample("same", 10, 10, 2_000)

    assert {:ok, stationary} = PositionMovement.evaluate(from, same, policy(), 2_000)
    assert stationary["status"] == "stationary"
    assert stationary["lower_speed_m_s"] == 0.0
    assert stationary["upper_distance_m"] == 0.0

    small = sample("small", 10, 10.00005, 2_000)
    hysteresis = policy(%{moving_distance_m: 10, stationary_distance_m: 1})
    assert {:ok, result} = PositionMovement.evaluate(from, small, hysteresis, 2_000)
    assert result["status"] == "indeterminate"
    assert result["reason"] == "hysteresis_or_uncertainty"
  end

  test "guaranteed accuracy expands distance bounds without treating estimates as bounds" do
    from = sample("from", 0, 0, 1_000, accuracy: 5)
    to = sample("to", 0, 0, 2_000, accuracy: 5)

    bounded =
      policy(%{
        uncertainty: :require_bound,
        moving_speed_m_s: 20,
        stationary_speed_m_s: 10,
        moving_distance_m: 20,
        stationary_distance_m: 10
      })

    assert {:ok, stationary} = PositionMovement.evaluate(from, to, bounded, 2_000)
    assert stationary["status"] == "stationary"
    assert stationary["lower_distance_m"] == 0
    assert stationary["upper_distance_m"] == 10.0
    assert stationary["upper_speed_m_s"] == 10.0

    missing = sample("missing", 0, 0, 2_000)
    assert {:ok, unknown} = PositionMovement.evaluate(from, missing, bounded, 2_000)
    assert unknown["status"] == "unknown"
    assert unknown["reason"] == "accuracy_bound_required"

    estimate = sample("estimate", 0, 0, 2_000, accuracy: 5, accuracy_kind: "estimate")
    assert {:ok, unknown} = PositionMovement.evaluate(from, estimate, bounded, 2_000)
    assert unknown["reason"] == "accuracy_bound_required"

    assert {:ok, coordinate} =
             PositionMovement.evaluate(
               from,
               estimate,
               policy(%{uncertainty: :coordinate_only}),
               2_000
             )

    assert coordinate["status"] == "stationary"
    assert coordinate["upper_distance_m"] == 0.0
  end

  test "minimum guaranteed speed above the physical policy limit is implausible" do
    from = sample("from", 0, 0, 1_000)
    to = sample("to", 0, 0.001, 2_000)
    policy = policy(%{moving_speed_m_s: 10, max_plausible_speed_m_s: 100})

    assert {:ok, result} = PositionMovement.evaluate(from, to, policy, 2_000)
    assert result["status"] == "implausible"
    assert result["reason"] == "speed_limit_exceeded"
    assert result["lower_speed_m_s"] > 100
  end

  test "event gaps, repeated timestamps and late ordering never become motion" do
    from = sample("from", 0, 0, 1_000)
    at_limit = sample("at-limit", 0, 0.001, 2_000)
    beyond = sample("beyond", 0, 0.001, 2_001)
    policy = policy(%{max_gap_ms: 1_000, max_plausible_speed_m_s: 1_000})

    assert {:ok, accepted} = PositionMovement.evaluate(from, at_limit, policy, 2_000)
    assert accepted["status"] == "moving"

    assert {:ok, rejected} = PositionMovement.evaluate(from, beyond, policy, 2_001)
    assert rejected["status"] == "unknown"
    assert rejected["reason"] == "time_gap_exceeded"

    repeated = sample("repeated", 0, 0.001, 1_000, received_at: 1_001)
    assert {:ok, result} = PositionMovement.evaluate(from, repeated, policy, 1_001)
    assert result["reason"] == "repeated_event_time"

    late = sample("late", 0, 0.001, 999, received_at: 2_000)
    assert {:ok, result} = PositionMovement.evaluate(from, late, policy, 2_000)
    assert result["status"] == "historical"
    assert result["center_distance_m"] == nil
  end

  test "unavailable and suspect endpoints return reasoned unknown decisions" do
    valid = sample("valid", 0, 0, 1_000)
    unavailable = sample("unavailable", nil, nil, 2_000, unavailable: true)
    suspect = sample("suspect", 0, 0, 2_000, quality: "suspect")

    assert {:ok, result} = PositionMovement.evaluate(valid, unavailable, policy(), 2_000)
    assert result["reason"] == "unavailable_endpoint"
    assert result["time_gap_ms"] == 1_000

    assert {:ok, result} = PositionMovement.evaluate(valid, suspect, policy(), 2_000)
    assert result["reason"] == "suspect_endpoint"
  end

  test "distance remains periodic across the antimeridian" do
    wrapped_from = sample("wrapped-from", 0, 179.999, 1_000)
    wrapped_to = sample("wrapped-to", 0, -179.999, 2_000)
    plain_from = sample("plain-from", 0, 0, 1_000)
    plain_to = sample("plain-to", 0, 0.002, 2_000)
    policy = policy(%{max_plausible_speed_m_s: 1_000})

    {:ok, wrapped} = PositionMovement.evaluate(wrapped_from, wrapped_to, policy, 2_000)
    {:ok, plain} = PositionMovement.evaluate(plain_from, plain_to, policy, 2_000)
    assert_in_delta wrapped["center_distance_m"], plain["center_distance_m"], 1.0e-6
  end

  test "policy identity binds every threshold and rejects inverted hysteresis" do
    original = policy()

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{order_policy: order_policy(%{late_window_ms: 2})},
          %{moving_speed_m_s: 2.0},
          %{stationary_speed_m_s: 0.5},
          %{moving_distance_m: 2.0},
          %{stationary_distance_m: 0.5},
          %{max_plausible_speed_m_s: 200.0},
          %{max_gap_ms: 2_000},
          %{uncertainty: :require_bound}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = PositionMovement.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{order_policy: :invalid},
          %{moving_speed_m_s: -1},
          %{stationary_speed_m_s: 2},
          %{moving_distance_m: 1, stationary_distance_m: 2},
          %{max_plausible_speed_m_s: 0.5},
          %{max_gap_ms: -1},
          %{max_gap_ms: 604_800_001},
          %{uncertainty: :guess},
          %{extra: true}
        ] do
      assert {:error, _} = PositionMovement.new(Map.merge(policy_input(), change)),
             inspect(change)
    end

    assert {:error, _} = PositionMovement.new(nil)
    assert {:error, _} = PositionMovement.validate(:invalid)
    from = sample("from", 0, 0, 1_000)
    to = sample("to", 0, 0, 2_000)
    assert {:error, _} = PositionMovement.evaluate(:invalid, to, original, 2_000)
    assert {:error, _} = PositionMovement.evaluate(from, to, :invalid, 2_000)
    assert {:error, _} = PositionMovement.evaluate(from, to, original, 2_000.0)
  end

  property "increasing an eastward offset cannot reduce centreline distance" do
    check all(offsets <- uniq_list_of(float(min: 0.0, max: 1.0), min_length: 2, max_length: 20)) do
      policy = policy(%{max_plausible_speed_m_s: 1_000_000, max_gap_ms: 10_000})

      distances =
        offsets
        |> Enum.sort()
        |> Enum.map(fn offset ->
          from = sample("from-#{offset}", 0, 0, 0)
          to = sample("to-#{offset}", 0, offset, 10_000)
          {:ok, result} = PositionMovement.evaluate(from, to, policy, 10_000)
          result["center_distance_m"]
        end)

      assert distances == Enum.sort(distances)
    end
  end

  defp policy(changes \\ %{}) do
    {:ok, value} = PositionMovement.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "movement-rule",
      revision: "movement-v1",
      order_policy: order_policy(),
      moving_speed_m_s: 1.0,
      stationary_speed_m_s: 0.0,
      moving_distance_m: 1.0,
      stationary_distance_m: 0.0,
      max_plausible_speed_m_s: 100.0,
      max_gap_ms: 10_000,
      uncertainty: :coordinate_only
    }

  defp order_policy(changes \\ %{}) do
    {:ok, value} =
      PositionOrder.new(
        Map.merge(
          %{
            revision: "movement-order-v1",
            event_time: :trusted_fix,
            future_skew_ms: 0,
            late_window_ms: 10_000,
            sequence: :none
          },
          changes
        )
      )

    value
  end

  defp sample(id, latitude, longitude, event_at, options \\ []) do
    received_at = Keyword.get(options, :received_at, event_at)
    unavailable = Keyword.get(options, :unavailable, false)
    quality = Keyword.get(options, :quality, if(unavailable, do: "unavailable", else: "valid"))
    accuracy = Keyword.get(options, :accuracy)

    accuracy_kind =
      Keyword.get(options, :accuracy_kind, if(is_nil(accuracy), do: "unknown", else: "bound"))

    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received_at})

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: :position,
        claim: %{
          "schema" => "wtr.position.v1",
          "latitude" => latitude,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => accuracy,
          "accuracy_kind" => accuracy_kind,
          "source" => "gnss",
          "fix_at" => event_at,
          "device_at" => nil,
          "received_at" => received_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => if(unavailable, do: "unavailable", else: "available"),
          "quality" => quality,
          "source_units" => %{
            "latitude" => if(unavailable, do: nil, else: "degree"),
            "longitude" => if(unavailable, do: nil, else: "degree"),
            "altitude" => nil,
            "speed" => nil,
            "accuracy" => if(is_nil(accuracy), do: nil, else: "m"),
            "fix_time" => "unix-ms",
            "device_time" => nil,
            "receiver_time" => "unix-ms"
          },
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{}
        },
        source_observation_ids: [observation.id],
        evidence_ids: [],
        profile: {"position", "1"},
        decoder: {"position", "1"},
        confidence: :exact,
        reasons: ["fixture"],
        association_id: nil
      })

    {:ok, bundle} = EvidenceBundle.new([observation], [evidence])
    {:ok, position} = Position.new(id, bundle)
    {:ok, sample} = PositionSample.new(position, bundle)
    sample
  end
end
