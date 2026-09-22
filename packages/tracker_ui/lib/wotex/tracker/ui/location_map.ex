defmodule Wotex.Tracker.UI.LocationMap do
  @moduledoc """
  Projects current public position claims onto the shared evidence map.

  Every available claim receives its own marker. The projection does not choose
  a canonical source, join assets, infer a route or manufacture a position from
  unavailable data. `RouteChart` supplies the same bounded geographic frame and
  antimeridian handling used by retained route replay.
  """

  alias Wotex.Tracker.UI.RouteChart

  @type entry :: %{
          id: String.t(),
          title: String.t(),
          href: String.t() | nil,
          observed_at: map(),
          positions: [map()]
        }

  @doc "Projects the available claims in a bounded list of asset entries."
  @spec project(term()) :: map() | nil
  def project(entries) when is_list(entries) and length(entries) <= 100 do
    claims =
      entries
      |> Enum.flat_map(&claims/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {claim, index} -> Map.put(claim, :index, index) end)

    route = %{
      "segments" =>
        Enum.map(claims, fn claim ->
          %{
            "points" => [
              %{
                "id" => claim.marker_id,
                "latitude" => claim.position["latitude"],
                "longitude" => claim.position["longitude"],
                "event_at" => event_at(claim.position, claim.observed_at),
                "source" => claim.position["source"],
                "quality" => claim.position["quality"]
              }
            ]
          }
        end)
    }

    with [_ | _] <- claims,
         %{} = chart <- RouteChart.project(route) do
      metadata = Map.new(claims, &{&1.marker_id, &1})

      markers =
        chart.segments
        |> Enum.flat_map(& &1.points)
        |> Enum.map(fn point ->
          Map.merge(Map.fetch!(metadata, point.id), Map.take(point, [:x, :y]))
        end)

      %{
        chart: chart,
        markers: markers,
        claim_count: length(markers),
        asset_count: markers |> Enum.map(& &1.asset_id) |> Enum.uniq() |> length()
      }
    else
      _ -> nil
    end
  end

  def project(_), do: nil

  defp claims(%{
         id: id,
         title: title,
         href: href,
         observed_at: observed_at,
         positions: positions
       })
       when is_binary(id) and is_binary(title) and (is_binary(href) or is_nil(href)) and
              is_map(observed_at) and is_list(positions) and length(positions) <= 32 do
    positions
    |> Enum.with_index()
    |> Enum.flat_map(fn {position, position_index} ->
      if position?(position) do
        [
          %{
            marker_id: id <> ":" <> Integer.to_string(position_index),
            asset_id: id,
            title: title,
            href: href,
            observed_at: observed_at,
            position: position
          }
        ]
      else
        []
      end
    end)
  end

  defp claims(_), do: []

  defp position?(%{
         "availability" => "available",
         "latitude" => %{"value" => latitude},
         "longitude" => %{"value" => longitude},
         "source" => source,
         "quality" => quality
       })
       when is_number(latitude) and latitude >= -90 and latitude <= 90 and
              is_number(longitude) and longitude >= -180 and longitude <= 180 and
              is_binary(source) and is_binary(quality),
       do: true

  defp position?(_), do: false

  defp event_at(%{"fix_at" => %{} = fix_at}, _observed_at), do: fix_at
  defp event_at(%{"received_at" => %{} = received_at}, _observed_at), do: received_at
  defp event_at(_position, observed_at), do: observed_at
end
