defmodule Wotex.Tracker.TripDistanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    MotionTransition,
    Position,
    PositionMovement,
    PositionOrder,
    PositionSample,
    TripDistance
  }

  test "ordered moving segments sum deterministic centre and uncertainty distances" do
    {trip, samples, motion_policy} = started_trip()
    fourth = sample("fourth", 0, 0.0003, 3_000)
    policy = policy(motion_policy)

    assert {:ok, result} = TripDistance.evaluate(trip, samples ++ [fourth], policy, 3_000)
    assert result["status"] == "complete"
    assert result["trip_id"] == trip.id
    assert result["sample_count"] == 3
    assert result["included_segment_count"] == 2
    assert result["excluded_segment_count"] == 0
    assert_in_delta result["center_distance_m"], 22.239010395, 1.0e-6
    assert result["center_distance_m"] == result["lower_distance_m"]
    assert result["center_distance_m"] == result["upper_distance_m"]
    assert Enum.all?(result["segments"], & &1["included"])
    assert String.starts_with?(result["identity"], "wtr-json-v1:sha256:")
  end

  test "stationary and over-gap segments stay explicit and are never bridged" do
    movement_policy = movement_policy(%{max_gap_ms: 1_000})
    {trip, samples, motion_policy} = started_trip(movement_policy)
    stationary = sample("stationary", 0, 0.0002, 3_000)
    after_gap = sample("after-gap", 0, 0.0003, 5_001)
    recovered = sample("recovered", 0, 0.0004, 6_001)

    assert {:ok, result} =
             TripDistance.evaluate(
               trip,
               samples ++ [stationary, after_gap, recovered],
               policy(motion_policy),
               6_001
             )

    assert result["status"] == "partial"
    assert result["included_segment_count"] == 2
    assert result["excluded_segment_count"] == 2

    assert Enum.map(result["segments"], &{&1["status"], &1["reason"], &1["included"]}) == [
             {"moving", "movement_thresholds_met", true},
             {"stationary", "stationary_thresholds_met", false},
             {"unknown", "time_gap_exceeded", false},
             {"moving", "movement_thresholds_met", true}
           ]

    assert_in_delta result["center_distance_m"], 22.239010395, 1.0e-6
    assert Enum.at(result["segments"], 2)["center_distance_m"] == nil
  end

  test "guaranteed endpoint bounds aggregate lower and upper trip distance separately" do
    movement_policy =
      movement_policy(%{
        uncertainty: :require_bound,
        moving_speed_m_s: 1,
        moving_distance_m: 1
      })

    {trip, samples, motion_policy} = started_trip(movement_policy, accuracy: 1)
    fourth = sample("bounded-fourth", 0, 0.0003, 3_000, accuracy: 1)

    assert {:ok, result} =
             TripDistance.evaluate(
               trip,
               samples ++ [fourth],
               policy(motion_policy),
               3_000
             )

    assert_in_delta result["center_distance_m"], 22.239010395, 1.0e-6
    assert_in_delta result["lower_distance_m"], result["center_distance_m"] - 4, 1.0e-6
    assert_in_delta result["upper_distance_m"], result["center_distance_m"] + 4, 1.0e-6
  end

  test "duplicate, unordered, unscoped and excessive sample lists fail closed" do
    {trip, [start, confirmation], motion_policy} = started_trip()
    policy = policy(motion_policy)

    assert {:error, %{code: :duplicate_id}} =
             TripDistance.evaluate(trip, [start, start], policy, 2_000)

    assert {:error, %{code: :conflict}} =
             TripDistance.evaluate(trip, [confirmation, start], policy, 2_000)

    assert {:error, %{code: :conflict}} =
             TripDistance.evaluate(
               trip,
               [start, sample("other", 0, 0.0003, 3_000)],
               policy,
               3_000
             )

    limited = policy(motion_policy, %{max_samples: 2})

    assert {:error, %{code: :limit_exceeded}} =
             TripDistance.evaluate(
               trip,
               [start, confirmation, sample("extra", 0, 0.0003, 3_000)],
               limited,
               3_000
             )

    assert {:error, _} = TripDistance.evaluate(trip, [start], policy, 2_000)
    assert {:error, _} = TripDistance.evaluate(trip, :invalid, policy, 2_000)
    assert {:error, _} = TripDistance.evaluate(trip, [start, confirmation], policy, 2_000.0)
  end

  test "policy and trip validation bind all reconstruction inputs" do
    {trip, _samples, motion_policy} = started_trip()
    original = policy(motion_policy)

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{motion_policy: motion_transition_policy(%{revision: "other"})},
          %{max_samples: 3}
        ] do
      changed = policy(motion_policy, change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = TripDistance.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{motion_policy: :invalid},
          %{max_samples: 1},
          %{max_samples: 257},
          %{extra: true}
        ] do
      assert {:error, _} = TripDistance.new(Map.merge(policy_input(motion_policy), change))
    end

    assert {:error, _} = TripDistance.new(nil)
    assert {:error, _} = TripDistance.validate(:invalid)
    assert {:error, _} = MotionTransition.validate_trip(:invalid, motion_policy)

    assert {:error, %{code: :conflict}} =
             MotionTransition.validate_trip(%{trip | id: "forged"}, motion_policy)
  end

  property "equal eastward segments accumulate monotonically in canonical order" do
    check all(count <- integer(3..12)) do
      {trip, initial, motion_policy} = started_trip()

      tail =
        for index <- 3..count do
          sample("property-#{count}-#{index}", 0, index * 0.0001, index * 1_000)
        end

      samples = initial ++ tail

      {:ok, result} =
        TripDistance.evaluate(trip, samples, policy(motion_policy), count * 1_000)

      assert result["status"] == "complete"
      assert result["included_segment_count"] == count - 1
      assert result["center_distance_m"] > 0

      assert Enum.map(result["segments"], & &1["event_at"]) ==
               Enum.sort(Enum.map(result["segments"], & &1["event_at"]))
    end
  end

  defp started_trip(movement_policy \\ movement_policy(), options \\ []) do
    motion_policy = motion_transition_policy(%{movement_policy: movement_policy})
    first = sample("first-#{movement_policy.identity}", 0, 0, 0, options)
    second = sample("second-#{movement_policy.identity}", 0, 0.0001, 1_000, options)
    third = sample("third-#{movement_policy.identity}", 0, 0.0002, 2_000, options)
    {:ok, baseline} = MotionTransition.evaluate(nil, first, motion_policy, :replay, 0)

    {:ok, candidate} =
      MotionTransition.evaluate(baseline["state"], second, motion_policy, :replay, 1_000)

    {:ok, started} =
      MotionTransition.evaluate(candidate["state"], third, motion_policy, :replay, 2_000)

    {started["active_trip"], [second, third], motion_policy}
  end

  defp policy(motion_policy, changes \\ %{}) do
    {:ok, value} = TripDistance.new(Map.merge(policy_input(motion_policy), changes))
    value
  end

  defp policy_input(motion_policy),
    do: %{
      id: "trip-distance",
      revision: "trip-distance-v1",
      motion_policy: motion_policy,
      max_samples: 64
    }

  defp motion_transition_policy(changes) do
    {:ok, value} =
      MotionTransition.new(
        Map.merge(
          %{
            id: "motion-rule",
            revision: "motion-rule-v1",
            movement_policy: movement_policy(),
            minimum_movement_ms: 1_000,
            minimum_stop_ms: 1_000
          },
          changes
        )
      )

    value
  end

  defp movement_policy(changes \\ %{}) do
    {:ok, value} =
      PositionMovement.new(
        Map.merge(
          %{
            id: "movement-rule",
            revision: "movement-v1",
            order_policy: order_policy(),
            moving_speed_m_s: 1.0,
            stationary_speed_m_s: 0.1,
            moving_distance_m: 1.0,
            stationary_distance_m: 0.5,
            max_plausible_speed_m_s: 1_000.0,
            max_gap_ms: 10_000,
            uncertainty: :coordinate_only
          },
          changes
        )
      )

    value
  end

  defp order_policy do
    {:ok, value} =
      PositionOrder.new(%{
        revision: "distance-order-v1",
        event_time: :trusted_fix,
        future_skew_ms: 0,
        late_window_ms: 10_000,
        sequence: :none
      })

    value
  end

  defp sample(id, latitude, longitude, event_at, options \\ []) do
    accuracy = Keyword.get(options, :accuracy)
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: event_at})

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
          "accuracy_kind" => if(is_nil(accuracy), do: "unknown", else: "bound"),
          "source" => "gnss",
          "fix_at" => event_at,
          "device_at" => nil,
          "received_at" => event_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => %{
            "latitude" => "degree",
            "longitude" => "degree",
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
