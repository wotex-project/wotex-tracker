defmodule Wotex.Tracker.Service.Enrollment do
  @moduledoc false
  alias Wotex.Tracker.Service.{Codec, Identifier, Snapshot, Update}

  def admit(
        %{
          "observation_id" => id,
          "title" => title,
          "owner_confirmed" => true,
          "expected_generation" => generation
        } = request
      )
      when map_size(request) == 4 do
    if Codec.id?(id) and Codec.id?(title) and match?({:ok, _}, Codec.generation(generation)),
      do: :ok,
      else: {:error, :invalid_request}
  end

  def admit(_), do: {:error, :invalid_request}

  def prepare(service, access, operation, request, now) do
    with {:ok, index} <-
           Snapshot.fetch(
             service,
             access,
             "resolutions",
             request["observation_id"],
             request["expected_generation"],
             "enroll",
             now
           ),
         :ok <- Snapshot.resolved(index["value"], service.catalogue) do
      update(access, operation, request, index, now)
    end
  end

  defp update(access, operation, request, index, now) do
    id = "urn:uuid:" <> Identifier.uuid()

    public = %{
      "id" => id,
      "title" => request["title"],
      "observation_id" => request["observation_id"],
      "owner_confirmed" => true,
      "identity_strategy" => "operator-pseudonym-v1"
    }

    record = %{
      "public" => public,
      "association_id" => Identifier.uuid(),
      "identity_revision" => "1",
      "actor" => access.principal,
      "created_at" => now,
      "catalogue_identity" => index["value"]["catalogue_identity"],
      "observation_id" => index["value"]["observation_id"]
    }

    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{"operation" => "enroll", "body" => request},
      observation: nil,
      publication: nil,
      response: %{"thing_id" => id},
      records: [%{kind: "enrollments", id: id, value: record}],
      events: [%{"type" => "enrollment.changed", "data" => %{"id" => id}}]
    })
  end
end
