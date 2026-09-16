defmodule Wotex.Tracker.Service.Events do
  @moduledoc false

  alias Wotex.Tracker.Service.{Credentials, Cursor, Store}

  # Streams retain an access proof, never the supplied bearer token.
  def batch(service, access, cursor, now) do
    key = Credentials.derive_key(service.credentials, :cursor)

    binding = %{
      instance: Credentials.instance_id(service.credentials),
      principal: access.principal,
      scope: access.scope,
      purpose: "events"
    }

    with {:ok, data} <- Cursor.open(key, binding, cursor, now),
         {:ok, page} <-
           Store.authorized_events(service.store, access, query(access.scope, data, now)) do
      items =
        Enum.map(page["items"], fn event ->
          {:ok, next} =
            Cursor.issue(
              key,
              binding,
              %{
                "kind" => "events",
                "generation" => event["generation"],
                "after" => event["id"],
                "snapshot_generation" => nil,
                "limit" => data["limit"]
              },
              now
            )

          Map.put(event, "cursor", next)
        end)

      next = if items == [], do: cursor, else: List.last(items)["cursor"]
      {:ok, %{"items" => items, "cursor" => next}}
    end
  end

  defp query(scope, data, now) do
    query = %{scope: scope, after: data["after"], limit: data["limit"], now: now}

    if data["snapshot_generation"],
      do: Map.put(query, :snapshot_generation, data["snapshot_generation"]),
      else: query
  end
end
