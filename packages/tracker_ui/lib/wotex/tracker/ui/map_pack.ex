defmodule Wotex.Tracker.UI.MapPack do
  @moduledoc """
  Admits one bounded, operator-supplied offline route-map pack.

  The versioned document contains only attributed geographic line work and an
  explicit coverage rectangle. It carries no URL, tile request, executable
  content, credential or Tracker evidence. Hosts admit the complete document
  before startup so a route page never fetches or interprets map content.
  """

  @classes ~w(boundary road water)
  @maximum_features 128
  @maximum_points 4_096
  @maximum_points_per_feature 256

  @derive {Inspect, only: [:id, :revision, :coverage]}
  @enforce_keys [:id, :revision, :attribution, :coverage, :features]
  defstruct @enforce_keys

  @type coordinate :: {float(), float()}
  @type feature :: %{class: String.t(), points: [coordinate()]}
  @type coverage :: %{west: float(), south: float(), east: float(), north: float()}
  @type t :: %__MODULE__{
          id: String.t(),
          revision: String.t(),
          attribution: String.t(),
          coverage: coverage(),
          features: [feature()]
        }

  @doc "Admits an exact, bounded public map-pack document."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_map_pack}
  def new(
        %{
          "schema" => "wtr.map-pack.v1",
          "id" => id,
          "revision" => revision,
          "attribution" => attribution,
          "coverage" => coverage,
          "features" => features
        } = document
      )
      when map_size(document) == 6 do
    with true <- token?(id),
         true <- token?(revision),
         true <- attribution?(attribution),
         {:ok, coverage} <- coverage(coverage),
         {:ok, features, point_count} <- features(features, coverage),
         true <- point_count <= @maximum_points do
      {:ok,
       %__MODULE__{
         id: id,
         revision: revision,
         attribution: attribution,
         coverage: coverage,
         features: features
       }}
    else
      _ -> {:error, :invalid_map_pack}
    end
  end

  def new(_), do: {:error, :invalid_map_pack}

  @doc "Reports whether an ordinary latitude/longitude coordinate is inside the pack coverage."
  @spec covers?(t(), number(), number()) :: boolean()
  def covers?(%__MODULE__{coverage: coverage}, latitude, longitude) do
    coordinate?(latitude, longitude) and latitude >= coverage.south and
      latitude <= coverage.north and covered_longitude?(longitude * 1.0, coverage)
  end

  defp coverage(%{"west" => west, "south" => south, "east" => east, "north" => north} = coverage)
       when map_size(coverage) == 4 do
    if longitude?(west) and longitude?(east) and latitude?(south) and latitude?(north) and
         west != east and south < north do
      {:ok, %{west: west * 1.0, south: south * 1.0, east: east * 1.0, north: north * 1.0}}
    else
      {:error, :invalid_map_pack}
    end
  end

  defp coverage(_), do: {:error, :invalid_map_pack}

  defp features(features, coverage)
       when is_list(features) and length(features) in 1..@maximum_features do
    Enum.reduce_while(features, {:ok, [], 0}, fn value, {:ok, admitted, total} ->
      case feature(value, coverage) do
        {:ok, feature, count} when total + count <= @maximum_points ->
          {:cont, {:ok, [feature | admitted], total + count}}

        _ ->
          {:halt, {:error, :invalid_map_pack}}
      end
    end)
    |> case do
      {:ok, admitted, total} -> {:ok, Enum.reverse(admitted), total}
      error -> error
    end
  end

  defp features(_, _), do: {:error, :invalid_map_pack}

  defp feature(%{"class" => class, "points" => points} = feature, coverage)
       when map_size(feature) == 2 and class in @classes and is_list(points) and
              length(points) in 2..@maximum_points_per_feature do
    Enum.reduce_while(points, {:ok, []}, fn value, {:ok, admitted} ->
      case coordinate(value, coverage) do
        {:ok, point} -> {:cont, {:ok, [point | admitted]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, admitted} -> {:ok, %{class: class, points: Enum.reverse(admitted)}, length(points)}
      error -> error
    end
  end

  defp feature(_, _), do: {:error, :invalid_map_pack}

  defp coordinate([latitude, longitude], coverage) do
    if coordinate?(latitude, longitude) and latitude >= coverage.south and
         latitude <= coverage.north and covered_longitude?(longitude * 1.0, coverage) do
      {:ok, {latitude * 1.0, longitude * 1.0}}
    else
      {:error, :invalid_map_pack}
    end
  end

  defp coordinate(_, _), do: {:error, :invalid_map_pack}

  defp covered_longitude?(longitude, %{west: west, east: east}) when west < east,
    do: longitude >= west and longitude <= east

  defp covered_longitude?(longitude, %{west: west, east: east}),
    do: longitude >= west or longitude <= east

  defp coordinate?(latitude, longitude), do: latitude?(latitude) and longitude?(longitude)

  defp latitude?(value), do: is_number(value) and value >= -90 and value <= 90
  defp longitude?(value), do: is_number(value) and value >= -180 and value <= 180

  defp token?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: String.valid?(value) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, value)

  defp token?(_), do: false

  defp attribution?(value) when is_binary(value) and byte_size(value) in 1..256 do
    String.valid?(value) and
      value
      |> String.to_charlist()
      |> Enum.all?(fn character -> character >= 0x20 and character != 0x7F end)
  end

  defp attribution?(_), do: false
end
