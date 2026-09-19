defmodule Wotex.Tracker.Service.Arming do
  @moduledoc false

  # Arming is an explicit administrative fact about one enrolled Thing. The
  # retained private PolicyFact preserves the exact operation evidence used by
  # suspicious-movement evaluation; public reads expose only reviewed state.

  alias Wotex.Tracker.{Evidence, EvidenceBundle, Observation, PolicyFact}
  alias Wotex.Tracker.Service.{Codec, Projection, Store, SuspiciousOrchestration, Update}

  @set_fields ~w(thing_id status expected_generation)
  @public_fields ~w(schema thing_id status revision changed_at changed_by)
  @stored_fields ~w(actor fact public)
  @statuses ~w(armed disarmed)

  def admit_set(request) do
    with true <- exact?(request, @set_fields),
         "urn:uuid:" <> _ <- request["thing_id"],
         true <- Codec.id?(request["thing_id"]),
         true <- request["status"] in @statuses,
         {:ok, _generation} <- Codec.generation(request["expected_generation"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prepare_set(service, access, operation, request, now) do
    with {:ok, _thing} <- thing(service, access, request, now),
         {:ok, fact} <- fact(operation, request, now),
         {:ok, fact_document} <- PolicyFact.to_map(fact) do
      {:ok, generation} = Codec.generation(request["expected_generation"])
      revision = "arming-" <> Integer.to_string(generation + 1)

      public = %{
        "schema" => "wtr.arming.v1",
        "thing_id" => request["thing_id"],
        "status" => request["status"],
        "revision" => revision,
        "changed_at" => now,
        "changed_by" =>
          Projection.pseudonym(
            service.credentials,
            access.scope,
            "arming-actor",
            access.principal
          )
      }

      value = %{"actor" => access.principal, "fact" => fact_document, "public" => public}

      with {:ok, update} <-
             Update.new(%{
               principal: access.principal,
               scope: access.scope,
               authority: access,
               operation_id: operation,
               expected_generation: request["expected_generation"],
               now: now,
               request: %{"operation" => "set_arming", "body" => request},
               observation: nil,
               publication: nil,
               response: %{"thing_id" => request["thing_id"], "status" => request["status"]},
               records: [%{kind: "arming", id: request["thing_id"], value: value}],
               events: [
                 %{
                   "type" => "arming.changed",
                   "data" => %{
                     "thing_id" => request["thing_id"],
                     "status" => request["status"]
                   }
                 }
               ]
             }),
           do:
             SuspiciousOrchestration.attach(
               service,
               access,
               "admin",
               request["thing_id"],
               update
             )
    end
  end

  def project(id, value) do
    with true <- exact?(value, @stored_fields),
         true <- Codec.id?(value["actor"]),
         true <- exact?(value["public"], @public_fields),
         public = value["public"],
         true <- public["schema"] == "wtr.arming.v1",
         true <- public["thing_id"] == id and Codec.id?(id),
         true <- public["status"] in @statuses,
         true <- Codec.id?(public["revision"]),
         true <- Codec.time?(public["changed_at"]),
         "wtr1_" <> _ <- public["changed_by"],
         {:ok, fact} <- PolicyFact.from_map(value["fact"]),
         true <- fact.predicate == "asset.armed",
         true <- fact.status == fact_status(public["status"]),
         true <- fact.policy_revision == public["revision"],
         true <- fact.reason == "administrator_committed",
         true <- fact.observed_at == public["changed_at"],
         true <- fact.evidence.association_id == id do
      {:ok, public}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  @doc false
  def restore_fact(id, value) do
    with {:ok, _public} <- project(id, value), do: PolicyFact.from_map(value["fact"])
  end

  defp thing(service, access, request, now) do
    service.store
    |> Store.authorized_fetch(
      access,
      "admin",
      %{
        scope: access.scope,
        kind: "things",
        id: request["thing_id"],
        generation: request["expected_generation"]
      },
      now
    )
    |> then(fn
      {:error, :invalid_cursor} -> {:error, :conflict}
      result -> result
    end)
  end

  defp fact(operation, request, now) do
    status = fact_status(request["status"])
    {:ok, generation} = Codec.generation(request["expected_generation"])
    revision = "arming-" <> Integer.to_string(generation + 1)
    observation_id = "arming-observation-" <> operation
    evidence_id = "arming-fact-" <> operation

    with {:ok, observation} <-
           Observation.new(%{
             id: observation_id,
             observed_at: now,
             ingress: "imported",
             source: %{"kind" => "service-administrator"},
             addressing: %{"thing_id" => request["thing_id"]},
             payload: {:json, %{"predicate" => "asset.armed", "status" => status}},
             radio: %{},
             transport: %{},
             provenance: %{"kind" => "administrative-operation", "operation_id" => operation}
           }),
         {:ok, evidence} <-
           Evidence.new(%{
             id: evidence_id,
             kind: :identity,
             claim: %{
               "schema" => "wtr.policy-fact.v1",
               "predicate" => "asset.armed",
               "status" => status,
               "policy_revision" => revision,
               "reason" => "administrator_committed"
             },
             source_observation_ids: [observation_id],
             evidence_ids: [],
             profile: {"service-arming", "1"},
             decoder: {"service-arming", "1"},
             confidence: :exact,
             reasons: ["administrator_committed"],
             association_id: request["thing_id"]
           }),
         {:ok, bundle} <- EvidenceBundle.new([observation], [evidence]),
         {:ok, fact} <- PolicyFact.new(evidence_id, bundle) do
      {:ok, fact}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp fact_status("armed"), do: "true"
  defp fact_status("disarmed"), do: "false"

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
