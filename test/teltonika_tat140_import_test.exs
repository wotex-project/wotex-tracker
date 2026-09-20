defmodule Wotex.Tracker.TeltonikaTAT140ImportTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{Capability, Catalogue, Error, EvidenceBundle, Observation}
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
