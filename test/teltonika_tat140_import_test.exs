defmodule Wotex.Tracker.TeltonikaTAT140ImportTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{
    Capability,
    Catalogue,
    Deployment,
    Error,
    Evidence,
    EvidenceBundle,
    Identity,
    Materialisation,
    Model,
    Observation
  }

  alias Wotex.Tracker.Protocols.Teltonika.{TAT140, TAT140Import}

  setup do
    {:ok, fixture} = Wotex.JSON.decode(File.read!("test/fixtures/teltonika/tat140.json"))
    [vector] = fixture["vectors"]
    frame = Base.decode16!(vector["hex"])
    {:ok, profile} = TAT140.profile()
    {:ok, catalogue} = Catalogue.new([profile])

    %{catalogue: catalogue, observation: observation(frame), profile: profile}
  end

  test "every AVL record receives ordered, closed evidence lineage", context do
    assert {:ok, imported} = TAT140Import.run(context.observation, context.catalogue)

    assert {:ok, ^imported} =
             TAT140Import.validate(imported, context.observation, context.catalogue)

    assert imported.resolution.status == :resolved
    assert Enum.map(imported.records, & &1.index) == [0, 1]

    assert Enum.map(imported.records, & &1.timestamp_ms) == [
             1_700_000_000_000,
             1_700_000_060_000
           ]

    [moving, stopped] = imported.records

    assert Enum.map(moving.measurements, &{&1.kind, &1.value}) == [
             {"motion", true},
             {"batteryVoltage", 3.6}
           ]

    assert Enum.map(stopped.measurements, &{&1.kind, &1.value}) == [
             {"motion", false},
             {"batteryVoltage", 3.59}
           ]

    assert length(moving.positions) == 1
    assert stopped.positions == []
    assert length(moving.measurement_evidence_ids) == 2
    assert length(stopped.measurement_evidence_ids) == 2

    assert {:ok, _} = EvidenceBundle.validate(imported.bundle)
    assert map_size(imported.bundle.evidence) == 10

    transport = imported.bundle.evidence[moving.transport_evidence_id]
    assert transport.kind == :transport
    assert transport.claim["schema"] == "wtr.teltonika-avl-record.v1"
    assert transport.claim["index"] == 0
    assert Enum.map(transport.claim["io_elements"], & &1["id"]) == [240, 113, 67, 999]

    for id <- moving.measurement_evidence_ids ++ moving.position_evidence_ids do
      assert imported.bundle.evidence[id].evidence_ids == [transport.id]
    end
  end

  test "capabilities come from the exact profile and survive a no-fix record", context do
    assert {:ok, imported} = TAT140Import.run(context.observation, context.catalogue)

    assert Enum.map(imported.capabilities, &{&1.id, &1.unit}) == [
             {"batteryVoltage", "V"},
             {"motion", "1"},
             {"position", "WGS84"}
           ]

    for capability <- imported.capabilities do
      assert {:ok, projected} = Capability.to_map(capability, imported.bundle)
      [evidence_id] = projected["evidence_ids"]
      evidence = imported.bundle.evidence[evidence_id]
      assert evidence.kind == :capability
      assert evidence.reasons == ["configured_profile_mapping"]
      assert evidence.evidence_ids == []
    end

    assert List.last(imported.records).positions == []
    assert Enum.any?(imported.capabilities, &(&1.id == "position"))
  end

  test "changed imports, catalogues and unresolved observations fail revalidation", context do
    assert {:ok, imported} = TAT140Import.run(context.observation, context.catalogue)
    [first | rest] = imported.records
    forged = %{imported | records: [%{first | timestamp_ms: first.timestamp_ms + 1} | rest]}

    assert {:error, %Error{code: :conflict}} =
             TAT140Import.validate(forged, context.observation, context.catalogue)

    assert {:error, %Error{code: :invalid_decoder_result}} =
             TAT140Import.validate(:forged, context.observation, context.catalogue)

    changed_profile = %{context.profile | mapping_revision: "changed"}
    {:ok, changed_catalogue} = Catalogue.new([changed_profile])

    assert {:error, %Error{code: :revision_mismatch}} =
             TAT140Import.run(context.observation, changed_catalogue)

    unresolved = %{
      context.observation
      | provenance: Map.delete(context.observation.provenance, "configured_profile")
    }

    assert {:error, %Error{code: :unknown_resolution}} =
             TAT140Import.run(unresolved, context.catalogue)
  end

  test "record evidence materialises the complete cellular tracker model", context do
    assert {:ok, imported} = TAT140Import.run(context.observation, context.catalogue)

    association_id = "tat140-enrollment"
    thing_id = "urn:uuid:aca49b80-1e09-40cf-929e-b193047f6ca9"

    {:ok, association} =
      Evidence.new(%{
        id: "tat140-identity",
        kind: :identity,
        claim: %{
          "thing_id" => thing_id,
          "strategy" => "operator-pseudonym-v1",
          "revision" => "1"
        },
        source_observation_ids: [context.observation.id],
        evidence_ids: [],
        profile: {context.profile.id, context.profile.version},
        decoder: context.profile.decoder,
        confidence: :exact,
        reasons: ["operator_confirmed_association"],
        association_id: association_id
      })

    {:ok, bundle} =
      EvidenceBundle.new(
        [context.observation],
        [association | Map.values(imported.bundle.evidence)]
      )

    {:ok, identity} =
      Identity.new(
        %{
          thing_id: thing_id,
          association_id: association_id,
          revision: "1",
          evidence_id: association.id
        },
        bundle
      )

    {:ok, document} =
      "priv/thing_models/cellular-asset-tracker-1.0.0.tm.json"
      |> File.read!()
      |> Wotex.JSON.decode()

    {:ok, model} = Model.new(document, context.profile.model)

    forms =
      Map.new(context.profile.mapping, fn {name, pointer} ->
        {pointer,
         [
           %{
             "href" => "https://tracker.example.invalid/things/asset/properties/" <> name,
             "op" => "readproperty",
             "contentType" => "application/json"
           }
         ]}
      end)

    {:ok, deployment} =
      Deployment.new(%{
        revision: "tat140-deployment-1",
        title: "Cellular asset",
        forms: forms,
        security_definitions: %{"bearer" => %{"scheme" => "bearer"}},
        security: ["bearer"]
      })

    assert {:ok, materialised} =
             Materialisation.new(%{
               observation: context.observation,
               catalogue: context.catalogue,
               resolution: imported.resolution,
               decoded: imported,
               bundle: bundle,
               capabilities: imported.capabilities,
               identity: identity,
               model: model,
               mapping_revision: context.profile.mapping_revision,
               deployment: deployment
             })

    td = Wotex.ThingDescription.to_map(materialised.td)
    assert Map.keys(td["properties"]) |> Enum.sort() == ~w(batteryVoltage motion position)
    assert td["properties"]["position"]["unit"] == "WGS84"
    assert td["properties"]["motion"]["type"] == "boolean"
    assert td["properties"]["batteryVoltage"]["unit"] == "V"
    assert materialised.bundle === bundle
  end

  defp observation(frame) do
    <<_::binary-size(9), record_count, _::binary>> = frame

    {:ok, observation} =
      Observation.new(%{
        id: "tat140-import-frame",
        observed_at: 1_700_000_000_500,
        ingress: "cellular",
        source: %{"adapter" => "teltonika-tcp", "device" => "configured-tracker"},
        addressing: %{"identity_digest" => String.duplicate("a", 64)},
        payload: {:bytes, frame},
        radio: %{},
        transport: %{"codec" => 0x8E, "record_count" => record_count},
        provenance: %{
          "protocol" => "teltonika-codec8-extended",
          "configured_profile" => TAT140.configured_profile(),
          "identity_assurance" => "configured-routing-identifier"
        }
      })

    observation
  end
end
