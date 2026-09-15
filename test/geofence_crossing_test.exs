defmodule Wotex.Tracker.GeofenceCrossingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Fixtures,
    Geofence,
    GeofenceCrossing,
    Position,
    PositionOrder,
    PositionSample
  }

  test "circle trace distinguishes interior crossing, tangent, miss and endpoint membership" do
    fence = circle(0, 0, 100)
    from = sample("from", 0, -0.002, 1_000)
    to = sample("to", 0, 0.002, 1_001)

    assert {:ok, crossing} = trace(fence, from, to)
    assert crossing["status"] == "crosses"
    assert crossing["reason"] == "centerline_enters_interior"
    assert crossing["interior_intervals"] == 1
    assert crossing["algorithm"] == "wgs84-authalic-azimuthal-circle-segment-v1"
    assert_in_delta crossing["endpoint_distance_m"], 444.78020790092784, 1.0e-6
    assert_in_delta crossing["closest_center_distance_m"], 0, 1.0e-6

    tangent_from = sample("tangent-from", 0.0009, -0.002, 1_000)
    tangent_to = sample("tangent-to", 0.0009, 0.002, 1_001)
    assert {:ok, miss} = trace(fence, tangent_from, tangent_to)
    assert miss["status"] == "does_not_cross"
    assert miss["reason"] == "centerline_misses_fence"

    boundary_latitude = 100 / 111_195.05197522942
    boundary_from = sample("boundary-from", boundary_latitude, -0.002, 1_000)
    boundary_to = sample("boundary-to", boundary_latitude, 0.002, 1_001)
    assert {:ok, boundary} = trace(fence, boundary_from, boundary_to)
    assert boundary["status"] == "does_not_cross"
    assert boundary["reason"] == "centerline_touches_boundary"

    far_from = sample("far-from", 1, 1, 1_000)
    far_to = sample("far-to", 1, 1.001, 1_001)
    assert {:ok, far} = trace(fence, far_from, far_to)
    assert far["reason"] == "segment_too_far_from_circle"
    assert far["closest_center_distance_m"] == nil

    inside = sample("inside", 0, 0, 1_001)
    assert {:ok, not_inferred} = trace(fence, from, inside)
    assert not_inferred["status"] == "does_not_infer"
    assert not_inferred["reason"] == "endpoint_not_outside"
  end

  test "circle trace unwraps the antimeridian along the short segment" do
    fence = circle(0, 180, 100)
    from = sample("west", 0, 179.998, 1_000)
    to = sample("east", 0, -179.998, 1_001)

    assert {:ok, crossing} = trace(fence, from, to)
    assert crossing["status"] == "crosses"
    assert_in_delta crossing["endpoint_distance_m"], 444.7802079023487, 1.0e-6
  end

  test "polygon trace enters interiors but rejects a boundary-only path" do
    fence =
      polygon([
        vertex(-0.001, -0.001),
        vertex(-0.001, 0.001),
        vertex(0.001, 0.001),
        vertex(0.001, -0.001)
      ])

    from = sample("from", 0, -0.002, 1_000)
    to = sample("to", 0, 0.002, 1_001)
    assert {:ok, crossing} = trace(fence, from, to)
    assert crossing["status"] == "crosses"
    assert crossing["interior_intervals"] == 1
    assert crossing["algorithm"] == "wgs84-authalic-local-polygon-segment-v1"

    edge_from = sample("edge-from", 0.001, -0.002, 1_000)
    edge_to = sample("edge-to", 0.001, 0.002, 1_001)
    assert {:ok, edge} = trace(fence, edge_from, edge_to)
    assert edge["status"] == "does_not_cross"
    assert edge["reason"] == "centerline_does_not_enter_interior"
  end

  test "uncertain or unavailable endpoints remain unknown" do
    fence = circle(0, 0, 100, :require_bound)
    from = sample("from", 0, -0.002, 1_000, accuracy: 150)
    to = sample("to", 0, 0.002, 1_001, accuracy: 5)

    assert {:ok, result} = trace(fence, from, to)
    assert result["status"] == "unknown"
    assert result["reason"] == "endpoint_membership_unknown"

    missing = sample("missing", 0, -0.002, 1_000)
    assert {:ok, result} = trace(fence, missing, to)
    assert result["status"] == "unknown"

    unavailable = sample("unavailable", nil, nil, 1_000, unavailable: true)

    assert {:ok, result} =
             GeofenceCrossing.evaluate(fence, unavailable, to, policy(), :live, 1_001)

    assert result["status"] == "unknown"
    assert result["trace"]["endpoint_distance_m"] == nil

    assert {:error, _} =
             Geofence.trace(:invalid, from.position, from.bundle, to.position, to.bundle)

    assert {:error, _} = Geofence.trace(fence, :invalid, from.bundle, to.position, to.bundle)
  end

  test "bounded crossing event identifies the interval without inventing route or time" do
    fence = circle(0, 0, 100)
    policy = policy()
    from = sample("from", 0, -0.002, 1_000)
    to = sample("to", 0, 0.002, 1_010)

    assert {:ok, live} =
             GeofenceCrossing.evaluate(fence, from, to, policy, :live, 1_010)

    assert live["status"] == "inferred_crossing"
    assert live["time_gap_ms"] == 10
    assert live["event"]["kind"] == "geofence.crossing_inferred"
    assert live["event"]["from_event_at"] == 1_000
    assert live["event"]["to_event_at"] == 1_010
    assert live["event"]["crossing_time"] == nil
    assert live["event"]["route_claim"] == "straight_segment_interpolation_only"
    assert live["physical_action_dispatch"] == "separate_authorization_required"

    assert {:ok, replay} =
             GeofenceCrossing.evaluate(fence, from, to, policy, :replay, 1_010)

    assert replay["event"] === live["event"]
    assert replay["physical_action_dispatch"] == "prohibited"
  end

  test "time and distance equality are accepted while larger gaps are not inferred" do
    fence = circle(0, 0, 100)
    from = sample("from", 0, -0.002, 1_000)
    at_time = sample("at-time", 0, 0.002, 1_010)
    beyond_time = sample("beyond-time", 0, 0.002, 1_011)
    {:ok, trace} = trace(fence, from, at_time)

    exact = policy(%{max_gap_ms: 10, max_distance_m: trace["endpoint_distance_m"]})

    assert {:ok, %{"status" => "inferred_crossing"}} =
             GeofenceCrossing.evaluate(fence, from, at_time, exact, :live, 1_010)

    assert {:ok, time_rejected} =
             GeofenceCrossing.evaluate(fence, from, beyond_time, exact, :live, 1_011)

    assert time_rejected["status"] == "not_inferred"
    assert time_rejected["reason"] == "time_gap_exceeded"

    short = policy(%{max_distance_m: trace["endpoint_distance_m"] - 1.0e-6})

    assert {:ok, distance_rejected} =
             GeofenceCrossing.evaluate(fence, from, at_time, short, :live, 1_010)

    assert distance_rejected["reason"] == "distance_gap_exceeded"
    assert distance_rejected["event"] == nil
  end

  test "endpoint changes and out-of-order samples cannot become inferred crossings" do
    fence = circle(0, 0, 100)
    outside = sample("outside", 0, -0.002, 1_000)
    inside = sample("inside", 0, 0, 1_001)

    assert {:ok, result} =
             GeofenceCrossing.evaluate(fence, outside, inside, policy(), :live, 1_001)

    assert result["status"] == "not_applicable"
    assert result["reason"] == "endpoint_not_outside"

    earlier = sample("earlier", 0, 0.002, 999, received_at: 1_100)

    assert {:ok, result} =
             GeofenceCrossing.evaluate(fence, outside, earlier, policy(), :live, 1_100)

    assert result["status"] == "historical"
    assert result["event"] == nil
  end

  test "policy identity binds ordering and both interpolation gaps" do
    original = policy()

    for change <- [
          %{id: "other"},
          %{revision: "other"},
          %{order_policy: order_policy(%{late_window_ms: 1})},
          %{max_gap_ms: 11},
          %{max_distance_m: 500.0}
        ] do
      changed = policy(change)
      refute changed.identity == original.identity
      assert {:error, %{code: :conflict}} = GeofenceCrossing.validate(struct(original, change))
    end

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{order_policy: :invalid},
          %{max_gap_ms: -1},
          %{max_gap_ms: 604_800_001},
          %{max_distance_m: -1},
          %{max_distance_m: 1_000_001},
          %{max_distance_m: "500"},
          %{extra: true}
        ] do
      assert {:error, _} = GeofenceCrossing.new(Map.merge(policy_input(), change)),
             inspect(change)
    end

    assert {:error, _} = GeofenceCrossing.new(nil)
    assert {:error, _} = GeofenceCrossing.validate(:invalid)

    from = sample("from", 0, -0.002, 1_000)
    to = sample("to", 0, 0.002, 1_001)

    assert {:error, _} =
             GeofenceCrossing.evaluate(circle(0, 0, 100), from, to, original, :bad, 1_001)
  end

  property "reversing a circle segment preserves its distance and crossing classification" do
    check all(offset <- float(min: 0.001, max: 0.01)) do
      fence = circle(0, 0, 100)
      left = sample("left-#{offset}", 0, -offset, 1_000)
      right = sample("right-#{offset}", 0, offset, 1_001)
      {:ok, forward} = trace(fence, left, right)
      {:ok, reverse} = trace(fence, right, left)

      assert forward["status"] == "crosses"
      assert reverse["status"] == "crosses"
      assert_in_delta forward["endpoint_distance_m"], reverse["endpoint_distance_m"], 1.0e-9

      assert_in_delta forward["closest_center_distance_m"],
                      reverse["closest_center_distance_m"],
                      1.0e-9
    end
  end

  defp trace(fence, from, to),
    do: Geofence.trace(fence, from.position, from.bundle, to.position, to.bundle)

  defp circle(latitude, longitude, radius, uncertainty \\ :coordinate_only) do
    {:ok, fence} =
      Geofence.new(%{
        id: "circle",
        revision: "circle-v1",
        shape: %{kind: :circle, latitude: latitude, longitude: longitude, radius_m: radius},
        boundary: :outside,
        uncertainty: uncertainty
      })

    fence
  end

  defp polygon(vertices) do
    {:ok, fence} =
      Geofence.new(%{
        id: "polygon",
        revision: "polygon-v1",
        shape: %{kind: :polygon, vertices: vertices},
        boundary: :outside,
        uncertainty: :coordinate_only
      })

    fence
  end

  defp vertex(latitude, longitude), do: %{latitude: latitude, longitude: longitude}

  defp policy(changes \\ %{}) do
    {:ok, value} = GeofenceCrossing.new(Map.merge(policy_input(), changes))
    value
  end

  defp policy_input,
    do: %{
      id: "crossing-rule",
      revision: "crossing-v1",
      order_policy: order_policy(),
      max_gap_ms: 10,
      max_distance_m: 500
    }

  defp order_policy(changes \\ %{}) do
    {:ok, value} =
      PositionOrder.new(
        Map.merge(
          %{
            revision: "crossing-order-v1",
            event_time: :trusted_fix,
            future_skew_ms: 0,
            late_window_ms: 10,
            sequence: :none
          },
          changes
        )
      )

    value
  end

  defp sample(id, latitude, longitude, event_at, options \\ []) do
    received_at = Keyword.get(options, :received_at, event_at)
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: received_at})
    accuracy = Keyword.get(options, :accuracy)
    unavailable = Keyword.get(options, :unavailable, false)

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
          "received_at" => received_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => if(unavailable, do: "unavailable", else: "available"),
          "quality" => if(unavailable, do: "unavailable", else: "valid"),
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
