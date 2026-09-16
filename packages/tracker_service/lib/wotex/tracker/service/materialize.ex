defmodule Wotex.Tracker.Service.Materialize do
  @moduledoc false

  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.{Evidence, EvidenceBundle, Identity, Observation}
  alias Wotex.Tracker.Service.{Codec, Delivery, Identifier, Projection, Snapshot, Update}

  def admit(%{"thing_id" => "urn:uuid:" <> id, "expected_generation" => generation} = request)
      when map_size(request) == 2 do
    if Identifier.operation?(id) and match?({:ok, _}, Codec.generation(generation)),
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
         {:ok, imported} <- import(service, access, enrollment["value"], request, now),
         {:ok, materialised} <- build(service, access, enrollment["value"], imported, operation) do
      update(access, operation, request, enrollment["value"], imported, materialised, now)
    end
  end

  defp import(service, access, enrollment, request, now) do
    with true <- enrollment["catalogue_identity"] == service.catalogue.identity,
         {:ok, row} <-
           Snapshot.fetch(
             service,
             access,
             "observations",
             enrollment["observation_id"],
             request["expected_generation"],
             "enroll",
             now
           ),
         {:ok, observation} <- Observation.from_map(row["value"]),
         {:ok, %{decoded: decoded} = imported} when not is_nil(decoded) <-
           Tracker.import_observation(
             observation,
             service.catalogue,
             {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
           ) do
      {:ok, imported}
    else
      false -> {:error, :revision_mismatch}
      {:ok, _} -> {:error, :unresolved}
      {:error, %Tracker.Error{}} -> {:error, :invalid_materialisation}
      error -> error
    end
  end

  defp build(service, access, enrollment, imported, operation) do
    profile = imported.resolution.selected

    identity_input = %{
      thing_id: enrollment["public"]["id"],
      association_id: enrollment["association_id"],
      revision: enrollment["identity_revision"],
      evidence_id: "operator:" <> enrollment["association_id"]
    }

    with {:ok, claim} <- identity_claim(identity_input, enrollment, imported),
         {:ok, deployment, delivery} <-
           Delivery.prepare(service, access, enrollment, imported, operation),
         {:ok, bundle} <-
           EvidenceBundle.new(
             [imported.observation],
             [claim | delivery ++ Map.values(imported.decoded.bundle.evidence)]
           ),
         {:ok, identity} <- Identity.new(identity_input, bundle),
         {:ok, result} <-
           Tracker.materialize(%{
             observation: imported.observation,
             catalogue: service.catalogue,
             resolution: imported.resolution,
             decoded: imported.decoded,
             bundle: bundle,
             identity: identity,
             capabilities: imported.decoded.capabilities,
             model: service.model,
             mapping_revision: profile.mapping_revision,
             deployment: deployment
           }) do
      {:ok, result}
    else
      {:error, _} -> {:error, :invalid_materialisation}
    end
  end

  defp identity_claim(identity, enrollment, imported) do
    profile = imported.resolution.selected

    Evidence.new(%{
      id: identity.evidence_id,
      kind: :identity,
      claim: %{
        "thing_id" => identity.thing_id,
        "strategy" => "operator-pseudonym-v1",
        "revision" => identity.revision,
        "actor" => enrollment["actor"],
        "confirmed_at" => enrollment["created_at"]
      },
      source_observation_ids: [imported.observation.id],
      evidence_ids: [],
      profile: {profile.id, profile.version},
      decoder: profile.decoder,
      confidence: :exact,
      reasons: ["operator_confirmed_association"],
      association_id: identity.association_id
    })
  end

  defp update(access, operation, request, enrollment, imported, materialised, now) do
    id = request["thing_id"]
    td = Wotex.ThingDescription.to_map(materialised.td)

    claims =
      materialised.bundle.evidence
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(fn evidence ->
        {:ok, map} = Evidence.to_map(evidence)
        map
      end)

    state = %{
      "id" => id,
      "observation_id" => enrollment["public"]["observation_id"],
      "observed_at" => Projection.scalar(imported.observation.observed_at),
      "measurements" => Enum.map(imported.decoded.measurements, &Projection.measurement/1)
    }

    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{"operation" => "materialize", "body" => request},
      observation: nil,
      publication: nil,
      response: %{"thing_id" => id, "materialisation_id" => materialised.identity},
      records: [
        %{
          kind: "things",
          id: id,
          value: %{
            "public" => td,
            "materialisation_id" => materialised.identity,
            "provenance" => materialised.provenance
          }
        },
        %{kind: "state", id: id, value: %{"public" => state}},
        %{
          kind: "evidence",
          id: id,
          value: %{
            "claims" => claims,
            "public" => %{"id" => id, "claim_count" => length(claims)}
          }
        }
      ],
      events: [%{"type" => "thing.changed", "data" => %{"id" => id}}]
    })
  end
end
