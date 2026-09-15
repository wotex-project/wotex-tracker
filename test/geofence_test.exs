defmodule Wotex.Tracker.GeofenceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Wotex.Tracker.{Evidence, EvidenceBundle, Fixtures, Geofence, Position}

  @degree_m 111_195.05197522942

  test "circle distance is pinned, antimeridian-safe and obeys exact boundary policy" do
    inside = circle(@degree_m, :inside, :coordinate_only)
    outside = circle(@degree_m, :outside, :coordinate_only)
    {position, bundle} = position("one-degree", 0, 1)

    assert {:ok, included} = Geofence.evaluate(inside, position, bundle)
    assert included["status"] == "inside"
    assert included["reason"] == "boundary_included"
    assert included["algorithm"] == "wgs84-authalic-haversine-v1"
    assert_in_delta included["distance_to_center_m"], @degree_m, 1.0e-6
    assert_in_delta included["distance_to_boundary_m"], 0, 1.0e-6

    assert {:ok, excluded} = Geofence.evaluate(outside, position, bundle)
    assert excluded["status"] == "outside"
    assert excluded["reason"] == "boundary_excluded"

    fence = circle(23_000, :inside, :coordinate_only, 0, 179.9)
    {position, bundle} = position("antimeridian", 0, -179.9)
    assert {:ok, result} = Geofence.evaluate(fence, position, bundle)
    assert result["status"] == "inside"
    assert_in_delta result["distance_to_center_m"], 22_239.010395045887, 1.0e-6
  end

  test "circle accuracy bounds prove membership or retain boundary uncertainty" do
    fence = circle(100, :inside, :require_bound)

    for {longitude, accuracy, status, reason} <- [
          {0.0005, 10, "inside", "accuracy_bound_inside"},
          {0.001, 5, "outside", "accuracy_bound_outside"},
          {0.001, 20, "uncertain", "accuracy_reaches_boundary"}
        ] do
      {position, bundle} = position("bound-#{accuracy}", 0, longitude, accuracy, "bound")
      assert {:ok, result} = Geofence.evaluate(fence, position, bundle)
      assert result["status"] == status
      assert result["reason"] == reason
      assert result["accuracy_m"] === accuracy
    end

    {missing, missing_bundle} = position("missing", 0, 0)

    assert {:ok, %{"status" => "unknown", "reason" => "missing_accuracy"}} =
             Geofence.evaluate(fence, missing, missing_bundle)

    {estimate, estimate_bundle} = position("estimate", 0, 0, 5, "estimate")

    assert {:ok, %{"status" => "unknown", "reason" => "non_bound_accuracy"}} =
             Geofence.evaluate(fence, estimate, estimate_bundle)

    coordinate_only = circle(100, :inside, :coordinate_only)

    assert {:ok, %{"status" => "inside", "accuracy_m" => 5, "accuracy_kind" => "estimate"}} =
             Geofence.evaluate(coordinate_only, estimate, estimate_bundle)
  end

  test "antimeridian polygon classifies interior, exterior and exact edge consistently" do
    vertices = [vertex(-1, 179), vertex(-1, -179), vertex(1, -179), vertex(1, 179)]
    inside_fence = polygon(vertices, :inside, :coordinate_only)
    outside_fence = polygon(vertices, :outside, :coordinate_only)

    for {id, latitude, longitude, status} <- [
          {"middle-a", 0, 180, "inside"},
          {"middle-b", 0, -180, "inside"},
          {"west", 0, 178, "outside"},
          {"east", 0, -178, "outside"}
        ] do
      {position, bundle} = position(id, latitude, longitude)
      assert {:ok, result} = Geofence.evaluate(inside_fence, position, bundle)
      assert result["status"] == status
      assert result["algorithm"] == "wgs84-authalic-local-polygon-v1"
    end

    {edge, bundle} = position("edge", 0, 179)

    assert {:ok, %{"status" => "inside", "reason" => "boundary_included"}} =
             Geofence.evaluate(inside_fence, edge, bundle)

    assert {:ok, %{"status" => "outside", "reason" => "boundary_excluded"}} =
             Geofence.evaluate(outside_fence, edge, bundle)
  end

  test "polygon bound equality follows boundary inclusion and never invents certainty" do
    vertices = [vertex(0, 0), vertex(0, 1), vertex(1, 1), vertex(1, 0)]
    inside_fence = polygon(vertices, :inside, :require_bound)
    outside_fence = polygon(vertices, :outside, :require_bound)
    {exact, bundle} = position("inside", 0.5, 0.5, 10, "bound")

    assert {:ok, %{"status" => "inside", "reason" => "accuracy_bound_inside"}} =
             Geofence.evaluate(inside_fence, exact, bundle)

    {near, near_bundle} = position("near", 0.5, 0.9999, 20, "bound")
    assert {:ok, %{"status" => "uncertain"}} = Geofence.evaluate(inside_fence, near, near_bundle)

    {edge, edge_bundle} = position("edge-bound", 0.5, 1, 0, "bound")
    assert {:ok, %{"status" => "inside"}} = Geofence.evaluate(inside_fence, edge, edge_bundle)
    assert {:ok, %{"status" => "outside"}} = Geofence.evaluate(outside_fence, edge, edge_bundle)
  end

  test "unavailable positions and forged content remain unknown or invalid" do
    fence = circle(100, :inside, :require_bound)

    {position, bundle} =
      position("unavailable", nil, nil, nil, "unknown", %{
        "availability" => "unavailable",
        "quality" => "unavailable",
        "fix_at" => nil,
        "fix_clock" => "unknown"
      })

    assert {:ok, result} = Geofence.evaluate(fence, position, bundle)
    assert result["status"] == "unknown"
    assert result["reason"] == "unavailable"
    assert result["fence_identity"] == fence.identity
    assert result["position_bundle_identity"] == bundle.identity

    assert {:error, %{code: :conflict}} =
             Geofence.evaluate(%{fence | revision: "forged"}, position, bundle)

    assert {:error, %{code: :conflict}} =
             Geofence.evaluate(fence, %{position | bundle_identity: "forged"}, bundle)

    assert {:error, _} = Geofence.evaluate(:invalid, position, bundle)
    assert {:error, _} = Geofence.evaluate(fence, :invalid, bundle)
    assert {:error, _} = Geofence.evaluate(fence, position, :invalid)
  end

  test "fence admission rejects malformed, degenerate, self-intersecting and unbounded shapes" do
    valid = fence_input(%{kind: :circle, latitude: 0, longitude: 0, radius_m: 100})

    for change <- [
          %{id: ""},
          %{revision: ""},
          %{boundary: :maybe},
          %{uncertainty: :guess},
          %{extra: true}
        ] do
      assert {:error, _} = Geofence.new(Map.merge(valid, change)), inspect(change)
    end

    for shape <- [
          %{kind: :circle, latitude: 91, longitude: 0, radius_m: 1},
          %{kind: :circle, latitude: 0, longitude: 181, radius_m: 1},
          %{kind: :circle, latitude: 0, longitude: 0, radius_m: -1},
          %{kind: :circle, latitude: 0, longitude: 0, radius_m: 1_000_001},
          %{kind: :circle, latitude: 0, longitude: 0, radius_m: "1"},
          %{kind: :circle, latitude: 0, longitude: 0},
          %{kind: :polygon, vertices: [vertex(0, 0), vertex(0, 1)]},
          %{kind: :polygon, vertices: [vertex(0, 0), vertex(0, 1), vertex(0, 2)]},
          %{kind: :polygon, vertices: [vertex(0, 0), vertex(1, 1), vertex(0, 1), vertex(1, 0)]},
          %{kind: :polygon, vertices: [vertex(0, 0), vertex(0, 1), vertex(1, 1), vertex(0, 0)]},
          %{kind: :polygon, vertices: [vertex(0, 180), vertex(0, -180), vertex(1, 179)]},
          %{
            kind: :polygon,
            vertices: [vertex(0, 0), vertex(0, 10), vertex(10, 10), vertex(10, 0)]
          },
          %{kind: :polygon, vertices: [vertex(86, 0), vertex(86, 1), vertex(87, 0)]},
          %{kind: :polygon, vertices: [vertex(0, -90), vertex(1, 90), vertex(-1, 90)]},
          %{
            kind: :polygon,
            vertices: [vertex(0, 0), %{latitude: 1, longitude: 1, extra: true}, vertex(1, 0)]
          },
          %{kind: :unknown}
        ] do
      assert {:error, _} = Geofence.new(%{valid | shape: shape}), inspect(shape)
    end

    too_many = for index <- 0..64, do: vertex(0.1 * :math.sin(index), index * 0.01)

    assert {:error, %{code: :limit_exceeded}} =
             Geofence.new(%{valid | shape: %{kind: :polygon, vertices: too_many}})

    assert {:error, _} = Geofence.new(nil)
    assert {:error, _} = Geofence.validate(:invalid)
    assert {:error, _} = Geofence.new(valid, max_id_bytes: 0)
  end

  test "identity binds native shape, boundary and uncertainty decisions" do
    original = circle(100, :inside, :require_bound)

    for changed <- [
          %{revision: "other"},
          %{boundary: :outside},
          %{uncertainty: :coordinate_only},
          %{shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 100.0}},
          %{shape: %{kind: :circle, latitude: 0, longitude: 0, radius_m: 101}}
        ] do
      {:ok, admitted} =
        Geofence.new(
          Map.merge(Map.take(original, ~w(id revision shape boundary uncertainty)a), changed)
        )

      refute admitted.identity == original.identity
      assert {:error, %{code: :conflict}} = Geofence.validate(struct(original, changed))
    end
  end

  property "longitude wrap cannot change an equivalent circle distance" do
    check all(latitude <- float(min: -80, max: 80), offset <- float(min: 0, max: 0.9)) do
      fence = circle(300_000, :inside, :coordinate_only, latitude, 180 - offset)
      {west, west_bundle} = position("west", latitude, -180 + offset)
      plain_fence = circle(300_000, :inside, :coordinate_only, latitude, -180 + offset)
      {plain, plain_bundle} = position("plain", latitude, -180 + 3 * offset)
      {:ok, wrapped} = Geofence.evaluate(fence, west, west_bundle)
      {:ok, ordinary} = Geofence.evaluate(plain_fence, plain, plain_bundle)

      assert_in_delta wrapped["distance_to_center_m"],
                      ordinary["distance_to_center_m"],
                      1.0e-6
    end
  end

  defp circle(radius, boundary, uncertainty, latitude \\ 0, longitude \\ 0) do
    {:ok, fence} =
      Geofence.new(
        fence_input(
          %{kind: :circle, latitude: latitude, longitude: longitude, radius_m: radius},
          %{boundary: boundary, uncertainty: uncertainty}
        )
      )

    fence
  end

  defp polygon(vertices, boundary, uncertainty) do
    {:ok, fence} =
      Geofence.new(
        fence_input(
          %{kind: :polygon, vertices: vertices},
          %{boundary: boundary, uncertainty: uncertainty}
        )
      )

    fence
  end

  defp fence_input(shape, changes \\ %{}),
    do:
      Map.merge(
        %{
          id: "yard",
          revision: "fixture-v1",
          shape: shape,
          boundary: :inside,
          uncertainty: :require_bound
        },
        changes
      )

  defp vertex(latitude, longitude), do: %{latitude: latitude, longitude: longitude}

  defp position(
         id,
         latitude,
         longitude,
         accuracy \\ nil,
         accuracy_kind \\ "unknown",
         changes \\ %{}
       ) do
    observed_at = 1_000
    observation = Fixtures.observation(%{id: "capture-" <> id, observed_at: observed_at})

    units = %{
      "latitude" => if(is_nil(latitude), do: nil, else: "degree"),
      "longitude" => if(is_nil(longitude), do: nil, else: "degree"),
      "altitude" => nil,
      "speed" => nil,
      "accuracy" => if(is_nil(accuracy), do: nil, else: "m"),
      "fix_time" => "unix-ms",
      "device_time" => nil,
      "receiver_time" => "unix-ms"
    }

    claim =
      Map.merge(
        %{
          "schema" => "wtr.position.v1",
          "latitude" => latitude,
          "longitude" => longitude,
          "altitude_m" => nil,
          "speed_m_s" => nil,
          "horizontal_accuracy_m" => accuracy,
          "accuracy_kind" => accuracy_kind,
          "source" => "gnss",
          "fix_at" => observed_at,
          "device_at" => nil,
          "received_at" => observed_at,
          "fix_clock" => "trusted",
          "device_clock" => "unknown",
          "availability" => "available",
          "quality" => "valid",
          "source_units" => units,
          "conversion_revision" => "fixture-v1",
          "receiver_observation_id" => observation.id,
          "raw" => %{}
        },
        changes
      )

    {:ok, evidence} =
      Evidence.new(%{
        id: id,
        kind: :position,
        claim: claim,
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
    {position, bundle}
  end
end
