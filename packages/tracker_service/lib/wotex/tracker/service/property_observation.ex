defmodule Wotex.Tracker.Service.PropertyObservation do
  @moduledoc false

  alias Wotex.Runtime.Context
  alias Wotex.Tracker.Service.{Codec, Credentials, Cursor, Identifier, Interaction, Store}

  def open(service, access, thing, name, cursor, now) do
    if Codec.id?(thing) and Codec.id?(name) do
      if is_nil(cursor),
        do: initial(service, access, thing, name, now),
        else: resume(service, access, thing, name, cursor, now)
    else
      {:error, :invalid_request}
    end
  end

  def batch(service, access, cursor, now) do
    with {:ok, data} <- decode(service, access, cursor, now) do
      replay(service, access, data, cursor, now)
    end
  end

  defp initial(service, access, thing, name, now) do
    with {:ok, sample} <- sample(service, access, thing, name, nil, now, context()) do
      data = %{
        "kind" => "property",
        "thing_id" => thing,
        "property" => name,
        "generation" => sample["generation"],
        "after" => sample["event_cursor"],
        "snapshot_generation" => sample["generation"]
      }

      {:ok, cursor} = encode(service, access, data, now)

      {:ok,
       %{
         "items" => [
           %{
             "value" => sample["value"],
             "generation" => sample["generation"],
             "event_id" => "snapshot:" <> sample["generation"],
             "cursor" => cursor
           }
         ],
         "cursor" => cursor,
         "closed" => false
       }}
    end
  end

  defp resume(service, access, thing, name, cursor, now) do
    with {:ok, data} <- decode(service, access, cursor, now),
         true <- data["thing_id"] == thing and data["property"] == name,
         {:ok, page} <- replay(service, access, data, cursor, now) do
      if page["closed"] and page["items"] == [], do: {:error, :unavailable}, else: {:ok, page}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp replay(service, access, data, cursor, now) do
    query = %{scope: access.scope, after: data["after"], limit: 25, now: now}

    query =
      if data["snapshot_generation"],
        do: Map.put(query, :snapshot_generation, data["snapshot_generation"]),
        else: query

    with {:ok, page} <- Store.authorized_events(service.store, access, query) do
      deadline = context()

      result =
        Enum.reduce_while(
          page["items"],
          %{"items" => [], "cursor" => cursor, "closed" => false},
          fn event, acc -> advance(event, acc, service, access, {data, now, deadline}) end
        )

      {:ok, Map.update!(result, "items", &Enum.reverse/1)}
    end
  end

  defp advance(event, acc, service, access, {data, now, deadline}) do
    next_data = %{
      data
      | "generation" => event["generation"],
        "after" => event["id"],
        "snapshot_generation" => nil
    }

    {:ok, cursor} = encode(service, access, next_data, now)
    thing_id = data["thing_id"]

    case event["event"] do
      %{"type" => "thing.changed", "data" => %{"id" => ^thing_id}} ->
        case sample(
               service,
               access,
               thing_id,
               data["property"],
               event["generation"],
               now,
               deadline
             ) do
          {:ok, value} ->
            item = %{
              "value" => value["value"],
              "generation" => event["generation"],
              "event_id" => "event:" <> event["id"],
              "cursor" => cursor
            }

            {:cont, %{acc | "items" => [item | acc["items"]], "cursor" => cursor}}

          {:error, _} ->
            {:halt, %{acc | "closed" => true}}
        end

      _ ->
        {:cont, %{acc | "cursor" => cursor}}
    end
  end

  defp sample(service, access, thing, name, generation, now, context),
    do: Interaction.observe(service, access, thing, name, generation, context, now)

  defp context,
    do:
      Context.new!(
        request_id: Identifier.uuid(),
        deadline: System.monotonic_time(:millisecond) + 5000
      )

  defp decode(service, access, cursor, now),
    do:
      Cursor.open(
        Credentials.derive_key(service.credentials, :cursor),
        binding(service, access),
        cursor,
        now
      )

  defp encode(service, access, data, now),
    do:
      Cursor.issue(
        Credentials.derive_key(service.credentials, :cursor),
        binding(service, access),
        data,
        now
      )

  defp binding(service, access),
    do: %{
      instance: Credentials.instance_id(service.credentials),
      principal: access.principal,
      scope: access.scope,
      purpose: "property"
    }
end
