defmodule Wotex.Tracker.Service.Delivery do
  @moduledoc false

  alias Wotex.Tracker.{Deployment, Evidence}

  def prepare(service, access, enrollment, imported, operation) do
    profile = imported.resolution.selected

    root =
      service.base_url <>
        "/api/v1/scopes/" <>
        segment(access.scope) <>
        "/things/" <> segment(enrollment["public"]["id"]) <> "/properties/"

    forms =
      Map.new(profile.mapping, fn {name, pointer} ->
        href = root <> segment(name)

        {pointer,
         [
           %{"href" => href, "op" => "readproperty", "contentType" => "application/json"},
           %{
             "href" => href <> "/observe",
             "op" => ["observeproperty", "unobserveproperty"],
             "subprotocol" => "sse",
             "contentType" => "application/json"
           }
         ]}
      end)

    claims =
      Enum.map(imported.decoded.capabilities, fn capability ->
        pointer = profile.mapping[capability.id]

        {:ok, claim} =
          Evidence.new(%{
            id: "delivery:" <> operation <> ":" <> capability.id,
            kind: :transport,
            claim: %{
              "schema" => "wtr.delivery.v1",
              "provider" => "wotex-tracker-service",
              "revision" => "property-sse-v1",
              "semantics" => "committed-values",
              "property" => pointer,
              "forms" => forms[pointer],
              "deployment_revision" => operation
            },
            source_observation_ids: [imported.observation.id],
            evidence_ids: capability.evidence_ids,
            profile: {profile.id, profile.version},
            decoder: profile.decoder,
            confidence: :exact,
            reasons: ["host_delivery_declaration"],
            association_id: enrollment["association_id"]
          })

        claim
      end)

    with {:ok, deployment} <-
           Deployment.new(%{
             revision: operation,
             title: enrollment["public"]["title"],
             forms: forms,
             observation_evidence: Map.new(claims, &{&1.claim["property"], &1.id}),
             security_definitions: %{"bearer" => %{"scheme" => "bearer", "in" => "header"}},
             security: ["bearer"]
           }) do
      {:ok, deployment, claims}
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
