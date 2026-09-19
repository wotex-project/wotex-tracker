defmodule Wotex.Tracker.Service.OwnerPresence do
  @moduledoc false

  # Owner presence is admitted evidence, not a conclusion from radio silence.
  # The private PolicyFact remains available to suspicious-movement evaluation;
  # public reads disclose only its reviewed three-valued state and times.

  alias Wotex.Tracker.PolicyFact
  alias Wotex.Tracker.Service.{Codec, Projection, Store, SuspiciousOrchestration, Update}

  @admit_fields ~w(thing_id fact expected_generation)
  @public_fields ~w(schema thing_id status revision observed_at admitted_at admitted_by)
  @stored_fields ~w(actor fact public)
  @statuses ~w(present absent unknown)

  def admit(request) do
    with true <- exact?(request, @admit_fields),
         "urn:uuid:" <> _ <- request["thing_id"],
         true <- Codec.id?(request["thing_id"]),
         {:ok, _generation} <- Codec.generation(request["expected_generation"]),
         {:ok, fact} <- PolicyFact.from_map(request["fact"]),
         :ok <- fact?(fact, request["thing_id"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prepare(service, access, operation, request, now) do
    with {:ok, _thing} <- thing(service, access, request, now),
         {:ok, fact} <- PolicyFact.from_map(request["fact"]),
         :ok <- newer(service, access, request, fact, now) do
      {:ok, generation} = Codec.generation(request["expected_generation"])

      public = %{
        "schema" => "wtr.owner-presence.v1",
        "thing_id" => request["thing_id"],
        "status" => public_status(fact.status),
        "revision" => "owner-presence-" <> Integer.to_string(generation + 1),
        "observed_at" => fact.observed_at,
        "admitted_at" => now,
        "admitted_by" =>
          Projection.pseudonym(
            service.credentials,
            access.scope,
            "owner-presence-actor",
            access.principal
          )
      }

      value = %{"actor" => access.principal, "fact" => request["fact"], "public" => public}

      with {:ok, update} <-
             Update.new(%{
               principal: access.principal,
               scope: access.scope,
               authority: access,
               operation_id: operation,
               expected_generation: request["expected_generation"],
               now: now,
               request: %{"operation" => "admit_owner_presence", "body" => request},
               observation: nil,
               publication: nil,
               response: %{
                 "thing_id" => request["thing_id"],
                 "status" => public["status"],
                 "observed_at" => fact.observed_at
               },
               records: [%{kind: "owner_presence", id: request["thing_id"], value: value}],
               events: [
                 %{
                   "type" => "owner_presence.changed",
                   "data" => %{
                     "thing_id" => request["thing_id"],
                     "status" => public["status"],
                     "observed_at" => fact.observed_at
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
         true <- public["schema"] == "wtr.owner-presence.v1",
         true <- public["thing_id"] == id and Codec.id?(id),
         true <- public["status"] in @statuses,
         true <- Codec.id?(public["revision"]),
         true <- Codec.time?(public["observed_at"]),
         true <- Codec.time?(public["admitted_at"]),
         "wtr1_" <> _ <- public["admitted_by"],
         {:ok, fact} <- PolicyFact.from_map(value["fact"]),
         :ok <- fact?(fact, id),
         true <- public["status"] == public_status(fact.status),
         true <- public["observed_at"] == fact.observed_at do
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
    |> conflict()
  end

  defp newer(service, access, request, fact, now) do
    query = %{
      scope: access.scope,
      kind: "owner_presence",
      id: request["thing_id"],
      generation: request["expected_generation"]
    }

    case Store.authorized_fetch(service.store, access, "admin", query, now) do
      {:ok, %{"value" => value}} ->
        with {:ok, previous} <- restore_fact(request["thing_id"], value),
             true <- fact.observed_at > previous.observed_at do
          :ok
        else
          false -> {:error, :conflict}
          _ -> {:error, :storage_unavailable}
        end

      {:error, :not_found} ->
        :ok

      error ->
        conflict(error)
    end
  end

  defp fact?(fact, thing) do
    if fact.predicate == "owner.present" and fact.evidence.kind == :identity and
         fact.evidence.association_id == thing and Codec.time?(fact.observed_at),
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp public_status("true"), do: "present"
  defp public_status("false"), do: "absent"
  defp public_status("unknown"), do: "unknown"

  defp conflict({:error, :invalid_cursor}), do: {:error, :conflict}
  defp conflict(result), do: result

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
