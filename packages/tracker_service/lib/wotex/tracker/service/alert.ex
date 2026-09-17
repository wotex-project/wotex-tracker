defmodule Wotex.Tracker.Service.Alert do
  @moduledoc false

  # Every recorded rule event becomes an alert record at the same generation.
  # IDs invert the generation so ordinary ascending ID pages list newest first.
  # Only live alerts can be acknowledged, once; the acting principal stays private.

  alias Wotex.Tracker.Service.{Codec, Projection, RuleEventProjection, Store, Update}

  @maximum_generation 9_223_372_036_854_775_807
  @acknowledge_fields ~w(alert_id expected_generation)

  def id(generation, event_id),
    do:
      "alert-" <>
        String.pad_leading(Integer.to_string(@maximum_generation - generation), 19, "0") <>
        "-" <> event_id

  def record(event, fields, generation) do
    id = id(generation, event["id"])

    %{
      "public" => %{
        "schema" => "wtr.alert.v1",
        "id" => id,
        "event_id" => event["id"],
        "event" => RuleEventProjection.public(event),
        "rule" => %{"kind" => fields.kind, "id" => fields.rule_id},
        "mode" => fields.mode,
        "physical_action_dispatch" => fields.action,
        "created_at" => fields.evaluated_at,
        "generation" => Integer.to_string(generation),
        "acknowledgement" => nil
      }
    }
  end

  def admit_acknowledge(request) do
    if exact?(request, @acknowledge_fields) and Codec.id?(request["alert_id"]) and
         match?({:ok, _}, Codec.generation(request["expected_generation"])),
       do: :ok,
       else: {:error, :invalid_request}
  end

  def prepare_acknowledge(service, access, operation, request, now) do
    query = %{
      scope: access.scope,
      kind: "alerts",
      id: request["alert_id"],
      generation: request["expected_generation"]
    }

    case Store.authorized_fetch(service.store, access, "admin", query, now) do
      {:ok, %{"value" => %{"public" => %{"mode" => "live", "acknowledgement" => nil} = public}}} ->
        acknowledged =
          Map.put(public, "acknowledgement", %{
            "at" => now,
            "by" =>
              Projection.pseudonym(
                service.credentials,
                access.scope,
                "alert-actor",
                access.principal
              )
          })

        update(access, operation, request, now, %{
          "public" => acknowledged,
          "acknowledged_by" => access.principal
        })

      {:ok, %{"value" => %{"public" => %{}}}} ->
        {:error, :conflict}

      {:ok, _} ->
        {:error, :storage_unavailable}

      {:error, :invalid_cursor} ->
        {:error, :conflict}

      error ->
        error
    end
  end

  defp update(access, operation, request, now, value) do
    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{"operation" => "acknowledge_alert", "body" => request},
      observation: nil,
      publication: nil,
      response: %{"alert_id" => request["alert_id"], "action" => "acknowledged"},
      records: [%{kind: "alerts", id: request["alert_id"], value: value}],
      events: [%{"type" => "alert.acknowledged", "data" => %{"id" => request["alert_id"]}}]
    })
  end

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
