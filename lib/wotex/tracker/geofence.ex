defmodule Wotex.Tracker.Geofence do
  @moduledoc """
  Bounded circle and polygon membership over validated WGS 84 position evidence.

  Circle distances use the WGS 84 authalic radius. Polygon vertices are unwrapped
  across the antimeridian and projected into one bounded local equirectangular
  plane. Boundary and uncertainty treatment are explicit, content-bound policy.
  """
  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits, Position}

  @fields ~w(id revision shape boundary uncertainty)a
  @authalic_radius_m 6_371_007.180918475
  @max_extent_m 1_000_000
  @epsilon_m 1.0e-6
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity, :geometry]
  defstruct @enforce_keys

  @doc "Admits a closed circle or simple polygon fence and precomputes bounded geometry."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.revision], &Admission.id(&1, limits)),
         true <- input.boundary in [:inside, :outside],
         true <- input.uncertainty in [:require_bound, :coordinate_only],
         {:ok, geometry, shape} <- shape(input.shape),
         {:ok, identity} <- Admission.digest(policy_map(input, shape), Limits.json(limits)) do
      {:ok,
       %__MODULE__{
         id: input.id,
         revision: input.revision,
         shape: shape,
         boundary: input.boundary,
         uncertainty: input.uncertainty,
         identity: identity,
         geometry: geometry
       }}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified fence content, identity or precomputed geometry."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = fence, options) do
    with {:ok, admitted} <- new(Map.take(fence, @fields), options) do
      if admitted === fence, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Evaluates one position without selecting a source, reading a clock or changing rule state."
  @spec evaluate(term(), term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(fence, position, bundle, options \\ []) do
    with {:ok, fence} <- validate(fence, options),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         {:ok, position} <- Position.validate(position, bundle, options) do
      {:ok, membership(fence, position)}
    end
  end

  defp shape(%{kind: :circle} = value) do
    with :ok <- Admission.fields(value, ~w(kind latitude longitude radius_m)a),
         true <- coordinate?(value.latitude, value.longitude),
         true <- number?(value.radius_m, 0, @max_extent_m) do
      shape = %{
        kind: :circle,
        latitude: value.latitude,
        longitude: value.longitude,
        radius_m: value.radius_m
      }

      {:ok, shape, shape}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp shape(%{kind: :polygon} = value) do
    with :ok <- Admission.fields(value, ~w(kind vertices)a),
         :ok <- Admission.bounded_list(value.vertices, 64),
         true <- length(value.vertices) >= 3,
         {:ok, vertices} <- vertices(value.vertices),
         {:ok, geometry} <- polygon(vertices) do
      {:ok, geometry, %{kind: :polygon, vertices: value.vertices}}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp shape(_), do: Admission.fail(:invalid_input)

  defp vertices(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      with :ok <- Admission.fields(value, ~w(latitude longitude)a),
           true <- coordinate?(value.latitude, value.longitude) do
        {:cont, {:ok, [{value.latitude * 1.0, normalize_longitude(value.longitude * 1.0)} | acc]}}
      else
        false -> {:halt, Admission.fail(:invalid_input)}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp polygon(vertices) do
    with true <- unique_vertices?(vertices),
         {:ok, unwrapped} <- unwrap(vertices),
         true <- closing_edge?(unwrapped),
         reference = reference(unwrapped),
         true <- abs(reference.latitude) <= 85,
         projected = Enum.map(unwrapped, &project(&1, reference)),
         true <- extent?(projected),
         true <- abs(area_twice(projected)) >= 2.0,
         false <- self_intersecting?(projected) do
      {:ok, %{kind: :polygon, vertices: projected, reference: reference}}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp membership(fence, %{claim: %{"availability" => "unavailable"}} = position),
    do: result(fence, position, "unknown", "unavailable", nil, nil)

  defp membership(fence, position) do
    claim = position.claim
    accuracy = claim["horizontal_accuracy_m"]
    kind = claim["accuracy_kind"]

    cond do
      fence.uncertainty == :require_bound and kind == "unknown" ->
        result(fence, position, "unknown", "missing_accuracy", nil, nil)

      fence.uncertainty == :require_bound and kind != "bound" ->
        result(fence, position, "unknown", "non_bound_accuracy", nil, nil)

      fence.uncertainty == :coordinate_only ->
        coordinate_membership(fence, position, nil)

      true ->
        coordinate_membership(fence, position, accuracy)
    end
  end

  defp coordinate_membership(%{geometry: %{kind: :circle}} = fence, position, accuracy) do
    point = {position.claim["latitude"], position.claim["longitude"]}
    center = {fence.geometry.latitude, fence.geometry.longitude}
    distance = distance(point, center)
    {status, reason} = circle_status(distance, accuracy, fence)

    result(
      fence,
      position,
      status,
      reason,
      distance,
      abs(distance - fence.geometry.radius_m)
    )
  end

  defp coordinate_membership(%{geometry: %{kind: :polygon}} = fence, position, accuracy) do
    point =
      project(
        {position.claim["latitude"] * 1.0,
         unwrap_near(position.claim["longitude"], fence.geometry.reference.longitude)},
        fence.geometry.reference
      )

    coordinate = polygon_coordinate(point, fence.geometry.vertices, fence.boundary)
    edge_distance = edge_distance(point, fence.geometry.vertices)
    {status, reason} = polygon_status(coordinate, edge_distance, accuracy, fence)
    result(fence, position, status, reason, nil, edge_distance)
  end

  defp circle_status(distance, accuracy, %{boundary: :inside, geometry: geometry})
       when is_number(accuracy) do
    lower = max(distance - accuracy, 0)
    upper = distance + accuracy

    cond do
      upper <= geometry.radius_m -> {"inside", "accuracy_bound_inside"}
      lower > geometry.radius_m -> {"outside", "accuracy_bound_outside"}
      true -> {"uncertain", "accuracy_reaches_boundary"}
    end
  end

  defp circle_status(distance, accuracy, %{boundary: :outside, geometry: geometry})
       when is_number(accuracy) do
    lower = max(distance - accuracy, 0)
    upper = distance + accuracy

    cond do
      upper < geometry.radius_m -> {"inside", "accuracy_bound_inside"}
      lower >= geometry.radius_m -> {"outside", "accuracy_bound_outside"}
      true -> {"uncertain", "accuracy_reaches_boundary"}
    end
  end

  defp circle_status(distance, nil, fence),
    do: exact_status(compare(distance, fence.geometry.radius_m), fence)

  defp polygon_status(coordinate, _, nil, _), do: coordinate

  defp polygon_status(coordinate, distance, accuracy, fence) do
    {status, _} = coordinate

    stable =
      case {status, fence.boundary} do
        {"inside", :inside} -> accuracy <= distance
        {"inside", :outside} -> accuracy < distance
        {"outside", :inside} -> accuracy < distance
        {"outside", :outside} -> accuracy <= distance
      end

    if stable,
      do: {status, "accuracy_bound_" <> status},
      else: {"uncertain", "accuracy_reaches_boundary"}
  end

  defp polygon_coordinate(point, vertices, boundary) do
    if Enum.any?(edges(vertices), fn {left, right} -> point_on_segment?(point, left, right) end) do
      exact_status(:boundary, %{boundary: boundary})
    else
      inside = Enum.reduce(edges(vertices), false, &ray_crossing(point, &1, &2))

      if inside, do: {"inside", "coordinate_inside"}, else: {"outside", "coordinate_outside"}
    end
  end

  defp ray_crossing({x, y}, {{x1, y1}, {x2, y2}}, state) do
    crosses = y1 > y != y2 > y and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1
    if crosses, do: not state, else: state
  end

  defp exact_status(:inside, _), do: {"inside", "coordinate_inside"}
  defp exact_status(:outside, _), do: {"outside", "coordinate_outside"}
  defp exact_status(:boundary, %{boundary: :inside}), do: {"inside", "boundary_included"}
  defp exact_status(:boundary, %{boundary: :outside}), do: {"outside", "boundary_excluded"}

  defp compare(value, boundary) when abs(value - boundary) <= @epsilon_m, do: :boundary
  defp compare(value, boundary) when value < boundary, do: :inside
  defp compare(_, _), do: :outside

  defp result(fence, position, status, reason, center_distance, boundary_distance) do
    %{
      "schema" => "wtr.geofence-membership.v1",
      "status" => status,
      "reason" => reason,
      "fence_id" => fence.id,
      "fence_revision" => fence.revision,
      "fence_identity" => fence.identity,
      "position_evidence_id" => position.evidence_id,
      "position_bundle_identity" => position.bundle_identity,
      "boundary" => Atom.to_string(fence.boundary),
      "uncertainty" => Atom.to_string(fence.uncertainty),
      "accuracy_m" => position.claim["horizontal_accuracy_m"],
      "accuracy_kind" => position.claim["accuracy_kind"],
      "distance_to_center_m" => center_distance,
      "distance_to_boundary_m" => boundary_distance,
      "algorithm" => algorithm(fence)
    }
  end

  defp algorithm(%{geometry: %{kind: :circle}}), do: "wgs84-authalic-haversine-v1"
  defp algorithm(%{geometry: %{kind: :polygon}}), do: "wgs84-authalic-local-polygon-v1"

  defp distance({latitude1, longitude1}, {latitude2, longitude2}) do
    latitude1 = radians(latitude1)
    latitude2 = radians(latitude2)
    delta_latitude = latitude2 - latitude1
    delta_longitude = radians(longitude2 - longitude1)

    haversine =
      :math.sin(delta_latitude / 2) ** 2 +
        :math.cos(latitude1) * :math.cos(latitude2) * :math.sin(delta_longitude / 2) ** 2

    haversine = min(max(haversine, 0), 1)
    @authalic_radius_m * 2 * :math.atan2(:math.sqrt(haversine), :math.sqrt(max(1 - haversine, 0)))
  end

  defp unwrap([first | rest]) do
    Enum.reduce_while(rest, {:ok, [first]}, fn {latitude, longitude},
                                               {:ok, [previous | _] = acc} ->
      delta = normalize_delta(longitude - elem(previous, 1))

      if abs(abs(delta) - 180) <= 1.0e-12,
        do: {:halt, Admission.fail(:invalid_input)},
        else: {:cont, {:ok, [{latitude, elem(previous, 1) + delta} | acc]}}
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp closing_edge?([first | _] = vertices) do
    last = List.last(vertices)
    abs(normalize_delta(elem(first, 1) - elem(last, 1))) < 180
  end

  defp unwrap_near(longitude, reference) do
    normalized = normalize_longitude(longitude * 1.0)
    normalized + 360 * round((reference - normalized) / 360)
  end

  defp normalize_longitude(longitude) do
    longitude - 360 * Float.floor((longitude + 180) / 360)
  end

  defp normalize_delta(delta), do: delta - 360 * Float.floor((delta + 180) / 360)

  defp reference(vertices) do
    count = length(vertices)
    {latitudes, longitudes} = Enum.unzip(vertices)
    %{latitude: Enum.sum(latitudes) / count, longitude: Enum.sum(longitudes) / count}
  end

  defp project({latitude, longitude}, reference) do
    x =
      radians(longitude - reference.longitude) * @authalic_radius_m *
        :math.cos(radians(reference.latitude))

    y = radians(latitude - reference.latitude) * @authalic_radius_m
    {x, y}
  end

  defp extent?(vertices) do
    {xs, ys} = Enum.unzip(vertices)
    Enum.max(xs) - Enum.min(xs) <= @max_extent_m and Enum.max(ys) - Enum.min(ys) <= @max_extent_m
  end

  defp unique_vertices?(vertices) do
    normalized =
      Enum.map(vertices, fn {latitude, longitude} ->
        {latitude, normalize_longitude(longitude)}
      end)

    Enum.uniq(normalized) == normalized
  end

  defp area_twice(vertices) do
    Enum.reduce(edges(vertices), 0.0, fn {{x1, y1}, {x2, y2}}, sum -> sum + x1 * y2 - x2 * y1 end)
  end

  defp edges(vertices), do: Enum.zip(vertices, tl(vertices) ++ [hd(vertices)])

  defp self_intersecting?(vertices) do
    indexed = edges(vertices) |> Enum.with_index()
    last = length(indexed) - 1

    Enum.any?(indexed, fn {first, left_index} ->
      Enum.any?(indexed, fn {second, right_index} ->
        nonadjacent?(left_index, right_index, last) and segments_intersect?(first, second)
      end)
    end)
  end

  defp nonadjacent?(left, right, last),
    do: left < right and abs(left - right) > 1 and not (left == 0 and right == last)

  defp segments_intersect?({a, b}, {c, d}) do
    orientations =
      {orientation(a, b, c), orientation(a, b, d), orientation(c, d, a), orientation(c, d, b)}

    case orientations do
      {left, right, bottom, top} when left * right < 0 and bottom * top < 0 -> true
      {0, _, _, _} -> point_on_segment?(c, a, b)
      {_, 0, _, _} -> point_on_segment?(d, a, b)
      {_, _, 0, _} -> point_on_segment?(a, c, d)
      {_, _, _, 0} -> point_on_segment?(b, c, d)
      _ -> false
    end
  end

  defp orientation({x1, y1}, {x2, y2}, {x3, y3}) do
    value = (x2 - x1) * (y3 - y1) - (y2 - y1) * (x3 - x1)
    if abs(value) <= @epsilon_m, do: 0, else: if(value > 0, do: 1, else: -1)
  end

  defp point_on_segment?({x, y} = point, {x1, y1} = left, {x2, y2} = right) do
    orientation(left, right, point) == 0 and x >= min(x1, x2) - @epsilon_m and
      x <= max(x1, x2) + @epsilon_m and y >= min(y1, y2) - @epsilon_m and
      y <= max(y1, y2) + @epsilon_m
  end

  defp edge_distance(point, vertices) do
    vertices
    |> edges()
    |> Enum.map(fn {left, right} -> segment_distance(point, left, right) end)
    |> Enum.min()
  end

  defp segment_distance({x, y}, {x1, y1}, {x2, y2}) do
    length_squared = (x2 - x1) ** 2 + (y2 - y1) ** 2

    ratio =
      if length_squared == 0,
        do: 0,
        else: ((x - x1) * (x2 - x1) + (y - y1) * (y2 - y1)) / length_squared

    ratio = min(max(ratio, 0), 1)
    :math.sqrt((x - (x1 + ratio * (x2 - x1))) ** 2 + (y - (y1 + ratio * (y2 - y1))) ** 2)
  end

  defp coordinate?(latitude, longitude),
    do: number?(latitude, -90, 90) and number?(longitude, -180, 180)

  defp number?(value, lower, upper), do: is_number(value) and value >= lower and value <= upper
  defp radians(degrees), do: degrees * :math.pi() / 180

  defp policy_map(input, %{kind: :circle} = shape),
    do: %{
      "schema" => "wtr.geofence.v1",
      "algorithm" => "wgs84-authalic-haversine-v1",
      "id" => input.id,
      "revision" => input.revision,
      "shape" => %{
        "kind" => "circle",
        "latitude" => shape.latitude,
        "longitude" => shape.longitude,
        "radius_m" => shape.radius_m
      },
      "boundary" => Atom.to_string(input.boundary),
      "uncertainty" => Atom.to_string(input.uncertainty)
    }

  defp policy_map(input, %{kind: :polygon} = shape),
    do: %{
      "schema" => "wtr.geofence.v1",
      "algorithm" => "wgs84-authalic-local-polygon-v1",
      "id" => input.id,
      "revision" => input.revision,
      "shape" => %{
        "kind" => "polygon",
        "vertices" =>
          Enum.map(shape.vertices, &%{"latitude" => &1.latitude, "longitude" => &1.longitude})
      },
      "boundary" => Atom.to_string(input.boundary),
      "uncertainty" => Atom.to_string(input.uncertainty)
    }
end
