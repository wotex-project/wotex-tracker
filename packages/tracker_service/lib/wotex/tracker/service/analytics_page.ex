defmodule Wotex.Tracker.Service.AnalyticsPage do
  @moduledoc false

  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service.{Access, Codec, Credentials, Cursor, Store}

  @schema "wtr.query-page-request.v1"
  @algorithm "snapshot-pinned-bucket-pages-v1"

  def run(service, %Access{} = access, request, now) do
    with {:ok, spec, page_size, cursor} <- request(request),
         {:ok, generation, page_index} <- position(service, access, spec, page_size, cursor, now),
         {:ok, page_spec, window, more?} <- page_spec(spec, page_size, page_index),
         {:ok, result} <-
           Store.authorized_analytics_at(
             service.store,
             access,
             page_spec,
             now,
             generation
           ),
         {:ok, query} <- QuerySpec.to_map(spec),
         {:ok, next} <-
           next_cursor(service, access, spec, page_size, page_index, generation, more?, now) do
      material = %{
        "schema" => "wtr.query-page.v1",
        "algorithm" => @algorithm,
        "query" => query,
        "result" => result,
        "page" => window,
        "generation" => Integer.to_string(generation)
      }

      {:ok,
       material
       |> Map.put("cursor", next)
       |> Map.put("identity", "wtr-analytics-page-v1:sha256:" <> Codec.digest(material))}
    else
      {:error, %Wotex.Tracker.Error{}} -> {:error, :invalid_request}
      error -> error
    end
  end

  def run(_, _, _, _), do: {:error, :invalid_request}

  defp request(
         %{
           "schema" => @schema,
           "query" => query,
           "page_size" => page_size,
           "cursor" => cursor
         } = request
       )
       when map_size(request) == 4 and is_integer(page_size) and page_size in 1..1_000 and
              (is_nil(cursor) or is_binary(cursor)) do
    with {:ok, spec} <- QuerySpec.from_map(query), do: {:ok, spec, page_size, cursor}
  end

  defp request(_), do: {:error, :invalid_request}

  defp position(service, access, _spec, _page_size, nil, now) do
    with {:ok, page} <-
           Store.authorized_snapshot(
             service.store,
             access,
             "read",
             %{scope: access.scope, kind: "state", generation: nil, after: "", limit: 1},
             now
           ),
         {:ok, generation} <- Codec.generation(page["generation"]) do
      {:ok, generation, 0}
    else
      :error -> {:error, :storage_unavailable}
      error -> error
    end
  end

  defp position(service, access, spec, page_size, cursor, now) do
    with {:ok, data} <-
           Cursor.open(
             key(service),
             binding(service, access),
             cursor,
             now
           ),
         true <- data["query_identity"] == spec.identity and data["page_size"] == page_size,
         {:ok, generation} <- Codec.generation(data["generation"]) do
      {:ok, generation, data["page_index"]}
    else
      false -> {:error, :invalid_cursor}
      :error -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp page_spec(spec, page_size, page_index) do
    total = bucket_count(spec.to_at - spec.from_at, spec.bucket_ms)
    pages = bucket_count(total, page_size)

    if page_index < pages do
      {first, last} = bucket_window(spec.order, total, page_size, page_index)
      from_at = spec.from_at + first * spec.bucket_ms
      to_at = min(spec.to_at, spec.from_at + last * spec.bucket_ms)
      points = last - first

      with {:ok, page_spec} <-
             QuerySpec.new(%{
               id: spec.id,
               revision: spec.revision,
               dataset: spec.dataset,
               measurement: spec.measurement,
               unit: spec.unit,
               series: spec.series,
               qualities: spec.qualities,
               from_at: from_at,
               to_at: to_at,
               timezone: spec.timezone,
               bucket_ms: spec.bucket_ms,
               aggregation: spec.aggregation,
               order: spec.order,
               max_points: points
             }) do
        {:ok, page_spec,
         %{
           "index" => page_index,
           "from_at" => from_at,
           "to_at" => to_at
         }, page_index + 1 < pages}
      end
    else
      {:error, :invalid_cursor}
    end
  end

  defp bucket_window(:ascending, total, page_size, page_index) do
    first = page_index * page_size
    {first, min(total, first + page_size)}
  end

  defp bucket_window(:descending, total, page_size, page_index) do
    last = total - page_index * page_size
    {max(0, last - page_size), last}
  end

  defp next_cursor(_, _, _, _, _, _, false, _), do: {:ok, nil}

  defp next_cursor(service, access, spec, page_size, page_index, generation, true, now) do
    Cursor.issue(
      key(service),
      binding(service, access),
      %{
        "kind" => "analytics",
        "generation" => Integer.to_string(generation),
        "query_identity" => spec.identity,
        "page_size" => page_size,
        "page_index" => page_index + 1
      },
      now
    )
  end

  defp bucket_count(value, divisor), do: div(value + divisor - 1, divisor)
  defp key(service), do: Credentials.derive_key(service.credentials, :cursor)

  defp binding(service, access),
    do: %{
      instance: Credentials.instance_id(service.credentials),
      principal: access.principal,
      scope: access.scope,
      purpose: "analytics"
    }
end
