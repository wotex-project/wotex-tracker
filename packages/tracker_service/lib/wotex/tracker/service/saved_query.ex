defmodule Wotex.Tracker.Service.SavedQuery do
  @moduledoc false

  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service.{Codec, Projection, Store, Update}

  @save_fields ~w(id title query visualization expected_generation)
  @rolling_save_fields ~w(id title window query visualization expected_generation)
  @delete_fields ~w(id expected_generation)
  @public_fields ~w(schema id title owner created_at updated_at window query visualization)
  @rolling_window_fields ~w(kind duration_ms)
  @visualization_fields ~w(type show_legend show_points)
  @visualization_types ~w(line area points table)
  @maximum_window_ms 2_678_400_000

  def admit_save(request) do
    with true <- exact?(request, @save_fields) or exact?(request, @rolling_save_fields),
         true <- Codec.id?(request["id"]) and Codec.id?(request["title"]),
         {:ok, _} <- Codec.generation(request["expected_generation"]),
         :ok <- visualization(request["visualization"]),
         {:ok, spec} <- QuerySpec.from_map(request["query"]),
         :ok <- request_window(request, spec) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admit_delete(request) do
    with true <- exact?(request, @delete_fields),
         true <- Codec.id?(request["id"]),
         {:ok, _} <- Codec.generation(request["expected_generation"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prepare_save(service, access, operation, request, now) do
    case current(service, access, request, now) do
      {:ok, row} ->
        case existing(row, access.principal, request["id"]) do
          {:ok, created_at} ->
            save_update(
              service,
              access,
              operation,
              request,
              created_at,
              now
            )

          error ->
            error
        end

      {:error, :not_found} ->
        save_update(service, access, operation, request, now, now)

      error ->
        error
    end
  end

  def prepare_delete(service, access, operation, request, now) do
    with {:ok, row} <- current(service, access, request, now),
         {:ok, _created_at} <- existing(row, access.principal, request["id"]) do
      update(access, operation, request, now, nil, "deleted")
    end
  end

  def query(record, id, now) do
    with {:ok, spec, window} <- definition(record, id),
         do: resolve(spec, window, now)
  end

  defp definition(%{"owner" => owner, "public" => public} = record, id)
       when map_size(record) == 2 and is_binary(owner) do
    with true <- exact?(public, @public_fields),
         true <-
           public["id"] == id and Codec.id?(id) and Codec.id?(public["title"]) and
             Codec.id?(public["owner"]),
         true <- Codec.time?(public["created_at"]) and Codec.time?(public["updated_at"]),
         true <- public["updated_at"] >= public["created_at"],
         :ok <- visualization(public["visualization"]),
         {:ok, spec} <- QuerySpec.from_map(public["query"]),
         {:ok, window} <- stored_window(public, spec) do
      {:ok, spec, window}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  defp definition(_, _), do: {:error, :storage_unavailable}

  defp save_update(service, access, operation, request, created_at, now) do
    {schema, window} =
      case request do
        %{"window" => rolling} -> {"wtr.saved-query.v2", rolling}
        _ -> {"wtr.saved-query.v1", "absolute"}
      end

    public = %{
      "schema" => schema,
      "id" => request["id"],
      "title" => request["title"],
      "owner" =>
        Projection.pseudonym(
          service.credentials,
          access.scope,
          "saved-query-owner",
          access.principal
        ),
      "created_at" => created_at,
      "updated_at" => now,
      "window" => window,
      "query" => request["query"],
      "visualization" => request["visualization"]
    }

    update(
      access,
      operation,
      request,
      now,
      %{"owner" => access.principal, "public" => public},
      "saved"
    )
  end

  defp update(access, operation, request, now, value, action) do
    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{
        "operation" => if(action == "saved", do: "save_query", else: "delete_query"),
        "body" => request
      },
      observation: nil,
      publication: nil,
      response: %{"query_id" => request["id"], "action" => action},
      records: [%{kind: "saved_queries", id: request["id"], value: value}],
      events: [
        %{
          "type" => "query.changed",
          "data" => %{"id" => request["id"], "action" => action}
        }
      ]
    })
  end

  defp current(service, access, request, now) do
    Store.authorized_fetch(
      service.store,
      access,
      "admin",
      %{
        scope: access.scope,
        kind: "saved_queries",
        id: request["id"],
        generation: request["expected_generation"]
      },
      now
    )
    |> then(fn
      {:error, :invalid_cursor} -> {:error, :conflict}
      result -> result
    end)
  end

  defp existing(
         %{
           "value" => %{
             "owner" => owner,
             "public" => %{"created_at" => created_at}
           }
         } = row,
         principal,
         id
       )
       when is_binary(owner) do
    cond do
      owner != principal -> {:error, :forbidden}
      not Codec.time?(created_at) -> {:error, :storage_unavailable}
      match?({:ok, _, _}, definition(row["value"], id)) -> {:ok, created_at}
      true -> {:error, :storage_unavailable}
    end
  end

  defp existing(_, _, _), do: {:error, :storage_unavailable}

  defp visualization(value) do
    if exact?(value, @visualization_fields) and value["type"] in @visualization_types and
         is_boolean(value["show_legend"]) and is_boolean(value["show_points"]),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp request_window(request, spec) do
    case request do
      %{"window" => window} ->
        case rolling_window(window, spec) do
          {:ok, _duration} -> :ok
          _ -> {:error, :invalid_request}
        end

      _ ->
        :ok
    end
  end

  defp stored_window(%{"schema" => "wtr.saved-query.v1", "window" => "absolute"}, _spec),
    do: {:ok, :absolute}

  defp stored_window(%{"schema" => "wtr.saved-query.v2", "window" => window}, spec),
    do: rolling_window(window, spec)

  defp stored_window(_, _), do: {:error, :storage_unavailable}

  defp rolling_window(window, spec) do
    duration = if is_map(window), do: window["duration_ms"]

    if exact?(window, @rolling_window_fields) and window["kind"] == "rolling" and
         is_integer(duration) and duration in 1..@maximum_window_ms and
         duration == spec.to_at - spec.from_at do
      {:ok, {:rolling, duration}}
    else
      {:error, :invalid_window}
    end
  end

  defp resolve(spec, :absolute, _now), do: {:ok, spec}

  defp resolve(spec, {:rolling, duration}, now) when is_integer(now) do
    input =
      spec
      |> Map.from_struct()
      |> Map.delete(:identity)
      |> Map.merge(%{from_at: now + 1 - duration, to_at: now + 1})

    case QuerySpec.new(input) do
      {:ok, resolved} -> {:ok, resolved}
      _ -> {:error, :invalid_query}
    end
  end

  defp resolve(_spec, {:rolling, _duration}, _now), do: {:error, :invalid_query}

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
