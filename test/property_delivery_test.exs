defmodule Wotex.Tracker.PropertyDeliveryTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{
    Deployment,
    Evidence,
    EvidenceBundle,
    Fixtures,
    Identity,
    Materialisation,
    Model
  }

  test "host delivery declaration yields observable Property without changing decoder capabilities" do
    {input, claim} = observed()
    assert {:ok, result} = Materialisation.new(input)
    property = Wotex.ThingDescription.to_map(result.td)["properties"]["temperature"]
    assert property["observable"]
    assert Enum.all?(input.decoded.capabilities, &(&1.operations == [:read]))
    assert result.bundle.evidence[claim.id] == claim
    assert length(property["forms"]) == 2
    refute Wotex.ThingDescription.to_map(result.td)["properties"]["humidity"]["observable"]
    assert {:ok, identical} = Materialisation.new(input)
    assert result === identical
  end

  test "missing, altered and unrelated transport witnesses fail materialisation" do
    {input, claim} = observed()

    for changed <- [
          %{claim | kind: :measurement},
          %{claim | confidence: :candidate},
          %{claim | reasons: []},
          %{claim | evidence_ids: []},
          %{claim | claim: Map.put(claim.claim, "forms", [])},
          %{claim | claim: Map.put(claim.claim, "property", "/properties/humidity")},
          %{claim | claim: Map.put(claim.claim, "deployment_revision", "changed")},
          %{claim | claim: Map.put(claim.claim, "schema", "other")},
          %{claim | claim: Map.put(claim.claim, "semantics", "physical-device-event")},
          %{claim | claim: Map.put(claim.claim, "provider", "")},
          %{claim | claim: Map.put(claim.claim, "revision", false)},
          %{claim | claim: Map.put(claim.claim, "unexpected", nil)}
        ] do
      {:ok, bundle} =
        EvidenceBundle.new(
          Map.values(input.bundle.observations),
          input.bundle.evidence |> Map.put(claim.id, changed) |> Map.values()
        )

      assert {:error, _} = Materialisation.new(with_bundle(input, bundle))
    end

    {:ok, bundle} =
      EvidenceBundle.new(
        Map.values(input.bundle.observations),
        input.bundle.evidence |> Map.delete(claim.id) |> Map.values()
      )

    assert {:error, _} = Materialisation.new(with_bundle(input, bundle))

    {:ok, model} =
      Model.new(
        put_in(input.model.document, ["properties", "temperature", "observable"], false),
        input.model.revision
      )

    assert {:error, _} = Materialisation.new(%{input | model: model})
  end

  test "delivery Forms require complete read/observe/close operations and a bounded declaration" do
    {input, _} = observed()
    data = input.deployment |> Map.from_struct() |> Map.delete(:identity)
    pointer = "/properties/temperature"
    [read, stream] = data.forms[pointer]

    for change <- [
          %{observation_evidence: nil},
          %{observation_evidence: []},
          %{observation_evidence: %{pointer => ""}},
          %{observation_evidence: %{"/missing" => "witness"}},
          %{observation_evidence: %{}},
          %{forms: Map.put(data.forms, pointer, [read])},
          %{forms: Map.put(data.forms, pointer, [stream])},
          %{forms: Map.put(data.forms, pointer, [read, %{stream | "op" => "observeproperty"}])},
          %{forms: Map.put(data.forms, pointer, [read, %{stream | "subprotocol" => "other"}])},
          %{
            forms: Map.put(data.forms, pointer, [read, %{stream | "contentType" => "text/plain"}])
          },
          %{
            forms: Map.put(data.forms, pointer, [read, %{stream | "href" => "mqtt://host/value"}])
          },
          %{forms: Map.put(data.forms, pointer, [read, %{stream | "op" => "writeproperty"}])}
        ] do
      assert {:error, _} = Deployment.new(Map.merge(data, change))
    end

    assert {:error, _} = Deployment.new(data, max_affordances: 0)
    assert {:ok, _} = Deployment.validate(input.deployment)

    assert {:ok, _} =
             Deployment.new(%{
               data
               | forms:
                   Map.put(data.forms, pointer, [
                     read,
                     %{stream | "op" => "observeproperty"},
                     %{stream | "op" => "unobserveproperty"}
                   ])
             })
  end

  defp observed do
    input = Fixtures.materialisation_input()
    pointer = "/properties/temperature"
    read = hd(input.deployment.forms[pointer])

    stream = %{
      "href" => "https://fixture.example.invalid/temperature/observe",
      "op" => ["observeproperty", "unobserveproperty"],
      "contentType" => "application/json",
      "subprotocol" => "sse"
    }

    forms = [read, stream]
    capability = Enum.find(input.capabilities, &(&1.id == "temperature"))

    {:ok, claim} =
      Evidence.new(%{
        id: "delivery-temperature",
        kind: :transport,
        claim: %{
          "schema" => "wtr.delivery.v1",
          "provider" => "fixture-host",
          "revision" => "property-sse-v1",
          "semantics" => "committed-values",
          "property" => pointer,
          "forms" => forms,
          "deployment_revision" => input.deployment.revision
        },
        source_observation_ids: [input.observation.id],
        evidence_ids: capability.evidence_ids,
        profile: {input.resolution.selected.id, input.resolution.selected.version},
        decoder: input.resolution.selected.decoder,
        confidence: :exact,
        reasons: ["host_delivery_declaration"],
        association_id: input.identity.association_id
      })

    {:ok, bundle} =
      EvidenceBundle.new([input.observation], [claim | Map.values(input.bundle.evidence)])

    {:ok, deployment} =
      input.deployment
      |> Map.from_struct()
      |> Map.delete(:identity)
      |> Map.put(:forms, Map.put(input.deployment.forms, pointer, forms))
      |> Map.put(:observation_evidence, %{pointer => claim.id})
      |> Deployment.new()

    {with_bundle(%{input | deployment: deployment}, bundle), claim}
  end

  defp with_bundle(input, bundle) do
    {:ok, identity} = Identity.new(Fixtures.identity_input(), bundle)
    %{input | bundle: bundle, identity: identity}
  end
end
