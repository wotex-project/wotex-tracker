defmodule Wotex.Tracker.Service.History do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, Credentials, Cursor, Projection, Store}

  def page(service, access, resource, id, params, now) do
    with true <- Codec.id?(id) and valid_params?(params),
         {:ok, data} <- query(service, access, resource, id, params, now),
         {:ok, page} <-
           Store.authorized_history(
             service.store,
             access,
             %{
               scope: access.scope,
               kind: if(resource == "observations", do: "resolutions", else: resource),
               id: id,
               generation: data["generation"],
               after: data["after"],
               limit: data["limit"]
             },
             now
           ) do
      result(service, access, resource, data, page, now)
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  defp valid_params?(params) when is_map(params),
    do: Enum.all?(Map.keys(params), &(&1 in ["limit", "cursor"]))

  defp valid_params?(_), do: false

  defp query(service, access, resource, id, %{"cursor" => token} = params, now) do
    with {:ok, data} <-
           Cursor.open(key(service), binding(service, access, "history"), token, now),
         true <-
           data["resource"] == resource and data["id"] == id and
             Map.get(params, "limit", data["limit"]) == data["limit"] do
      {:ok, data}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp query(_, _, resource, id, params, _) do
    limit = Map.get(params, "limit", 25)

    if is_integer(limit) and limit in 1..100,
      do:
        {:ok,
         %{
           "kind" => "history",
           "resource" => resource,
           "id" => id,
           "generation" => nil,
           "after" => "0",
           "limit" => limit
         }},
      else: {:error, :invalid_request}
  end

  defp result(service, access, resource, data, page, now) do
    next =
      if page["next"] do
        {:ok, token} =
          Cursor.issue(
            key(service),
            binding(service, access, "history"),
            %{data | "generation" => page["generation"], "after" => page["next"]},
            now
          )

        token
      end

    {:ok, stream} =
      Cursor.issue(
        key(service),
        binding(service, access, "events"),
        %{
          "kind" => "events",
          "generation" => page["generation"],
          "after" => page["event_cursor"],
          "snapshot_generation" => page["generation"],
          "limit" => 100
        },
        now
      )

    with {:ok, items} <- Projection.public_items(resource, page["items"]) do
      {:ok,
       %{
         "items" => items,
         "generation" => page["generation"],
         "cursor" => next,
         "stream_cursor" => stream
       }}
    end
  end

  defp key(service), do: Credentials.derive_key(service.credentials, :cursor)

  defp binding(service, access, purpose),
    do: %{
      instance: Credentials.instance_id(service.credentials),
      principal: access.principal,
      scope: access.scope,
      purpose: purpose
    }
end
