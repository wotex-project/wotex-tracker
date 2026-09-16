defmodule Wotex.Tracker.Service.SavedQuery do
  @moduledoc false

  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service.{Codec, Projection, Store, Update}

  @save_fields ~w(id title query visualization expected_generation)
  @delete_fields ~w(id expected_generation)
  @visualization_fields ~w(type show_legend show_points)
  @visualization_types ~w(line area points table)

  def admit_save(request) do
    with true <- exact?(request, @save_fields),
         true <- Codec.id?(request["id"]) and Codec.id?(request["title"]),
         {:ok, _} <- Codec.generation(request["expected_generation"]),
         :ok <- visualization(request["visualization"]),
         {:ok, _} <- QuerySpec.from_map(request["query"]) do
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

  def query(%{"owner" => owner, "public" => public} = record, id)
      when map_size(record) == 2 and is_binary(owner) do
    with true <-
           exact?(
             public,
             ~w(schema id title owner created_at updated_at window query visualization)
           ),
         true <- public["schema"] == "wtr.saved-query.v1" and public["window"] == "absolute",
         true <-
           public["id"] == id and Codec.id?(id) and Codec.id?(public["title"]) and
             Codec.id?(public["owner"]),
         true <- Codec.time?(public["created_at"]) and Codec.time?(public["updated_at"]),
         true <- public["updated_at"] >= public["created_at"],
         :ok <- visualization(public["visualization"]),
         {:ok, spec} <- QuerySpec.from_map(public["query"]) do
      {:ok, spec}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  def query(_, _), do: {:error, :storage_unavailable}

  defp save_update(service, access, operation, request, created_at, now) do
    public = %{
      "schema" => "wtr.saved-query.v1",
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
      "window" => "absolute",
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
      response: %{"query_id" => request["id"]},
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
      match?({:ok, _}, query(row["value"], id)) -> {:ok, created_at}
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

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
