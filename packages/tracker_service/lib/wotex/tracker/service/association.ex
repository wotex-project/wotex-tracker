defmodule Wotex.Tracker.Service.Association do
  @moduledoc false
  alias Wotex.Tracker.Service.{Codec, Identifier, Snapshot, Update}

  def admit(
        %{
          "thing_id" => "urn:uuid:" <> id,
          "observation_id" => observation,
          "owner_confirmed" => true,
          "expected_generation" => generation
        } = request
      )
      when map_size(request) == 4 do
    if Identifier.operation?(id) and Codec.id?(observation) and
         match?({:ok, _}, Codec.generation(generation)),
       do: :ok,
       else: {:error, :invalid_request}
  end

  def admit(_), do: {:error, :invalid_request}

  def prepare(service, access, operation, request, now) do
    with {:ok, enrollment} <-
           Snapshot.fetch(
             service,
             access,
             "enrollments",
             request["thing_id"],
             request["expected_generation"],
             "enroll",
             now
           ),
         {:ok, index} <-
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
      update(access, operation, request, enrollment["value"], index["value"], now)
    end
  end

  defp update(access, operation, request, enrollment, index, now) do
    id = request["thing_id"]

    record = %{
      "public" => Map.put(enrollment["public"], "observation_id", request["observation_id"]),
      "association_id" => Identifier.uuid(),
      "identity_revision" => operation,
      "actor" => access.principal,
      "created_at" => now,
      "catalogue_identity" => index["catalogue_identity"],
      "observation_id" => index["observation_id"]
    }

    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{"operation" => "associate", "body" => request},
      observation: nil,
      publication: nil,
      response: %{"thing_id" => id},
      records: [%{kind: "enrollments", id: id, value: record}],
      events: [%{"type" => "enrollment.changed", "data" => %{"id" => id}}]
    })
  end
end
