defmodule Wotex.Tracker.TeltonikaATC700Test do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{
    Catalogue,
    Deployment,
    Error,
    Evidence,
    EvidenceBundle,
    Identity,
    Materialisation,
    Model,
    Observation,
    Resolution
  }

  alias Wotex.Tracker.Protocols.Teltonika.{ATC700, ATC700Import, TAT140Import}

  setup do
    {:ok, fixture} = Wotex.JSON.decode(File.read!("test/fixtures/teltonika/atc700.json"))
    [vector] = fixture["vectors"]
    frame = Base.decode16!(vector["hex"])
    {:ok, profile} = ATC700.profile()
    {:ok, catalogue} = Catalogue.new([profile])

    %{
      catalogue: catalogue,
      fixture: fixture,
      frame: frame,
      observation: observation(frame),
      profile: profile,
      vector: vector
    }
  end

  test "configured evidence resolves the documentation-qualified profile", context do
    assert context.profile.decoder == ATC700.revision()
    assert context.profile.confidence == :strong
    assert context.profile.model == {"urn:wotex:tm:tracker:cellular-asset-tracker", "1.1.0"}
    assert context.profile.mapping["batteryLevel"] == "/properties/batteryLevel"
    assert context.profile.source_provenance["qualification"] == "documentation-fixture"
    assert context.fixture["qualification"] == "documentation-fixture"

    assert {:ok, %{status: :resolved, selected: selected}} =
             Resolution.resolve(context.observation, context.catalogue)

    assert selected === context.profile

    unresolved = %{
      context.observation
      | provenance: Map.delete(context.observation.provenance, "configured_profile")
    }

    assert {:ok, %{status: :unknown, selected: nil}} =
             Resolution.resolve(unresolved, context.catalogue)
  end

  test "all records and documented ATC700 IO mappings remain distinct", context do
    assert Base.encode16(:crypto.hash(:sha256, context.frame), case: :lower) ==
             context.vector["sha256"]

    assert {:ok, message} = ATC700.decode(context.observation)
    assert message.record_count == 2
    assert Enum.map(message.records, & &1.index) == [0, 1]

    [moving, stopped] = message.records

    assert Enum.map(moving.io_elements, & &1["id"]) == [240, 113, 67, 999]

    assert Enum.map(moving.measurements, &{&1.kind, &1.value, &1.unit}) == [
             {"motion", true, "1"},
             {"batteryVoltage", 3.6, "V"},
             {"batteryLevel", 72, "%"}
           ]

    assert [%{"latitude" => 59.0, "longitude" => 18.0} = position] = moving.positions
    assert position["conversion_revision"] == "teltonika.atc700.position.v1"
    assert moving.trigger == %{"io_id" => 240, "mapped_kind" => "motion"}

    assert Enum.map(stopped.measurements, &{&1.kind, &1.value}) == [
             {"motion", false},
             {"batteryVoltage", 3.59}
           ]

    assert stopped.positions == []
    assert stopped.gps["reason"] == "no_satellites"
  end

  test "known IO width, range and uniqueness fail closed without dropping raw evidence" do
    out_of_range =
      frame([
        record(
          event_io_id: 113,
          one_byte: [{240, 2}, {113, 101}],
          two_byte: [{67, 3_600}]
        )
      ])

    assert {:ok, %{records: [%{measurements: measurements}]}} =
             out_of_range |> observation() |> ATC700.decode()

    assert Enum.map(measurements, &{&1.kind, &1.availability, &1.reason}) == [
             {"motion", :unavailable, "wire_value_out_of_range"},
             {"batteryVoltage", :available, "wire_value"},
             {"batteryLevel", :unavailable, "wire_value_out_of_range"}
           ]

    wrong_width = frame([record(one_byte: [{67, 7}])])

    assert {:ok, %{records: [%{measurements: [battery]}]}} =
             wrong_width |> observation() |> ATC700.decode()

    assert {battery.kind, battery.availability, battery.reason, battery.raw["raw_hex"]} ==
             {"batteryVoltage", :unavailable, "unexpected_wire_width", "07"}

    duplicate = frame([record(one_byte: [{113, 40}, {113, 41}])])

    assert {:error, %Error{code: :invalid_decoder_result, path: "/records/0/io/113"}} =
             duplicate |> observation() |> ATC700.decode()
  end

  test "record import binds the ATC700 contract and materialises its model revision", context do
    assert {:ok, imported} = ATC700Import.run(context.observation, context.catalogue)
    assert imported.contract == :teltonika_atc700_codec8e

    assert {:ok, ^imported} =
             ATC700Import.validate(imported, context.observation, context.catalogue)

    assert {:error, %Error{code: :invalid_decoder_result}} =
             TAT140Import.validate(imported, context.observation, context.catalogue)

    assert Enum.map(imported.capabilities, &{&1.id, &1.unit}) == [
             {"batteryLevel", "%"},
             {"batteryVoltage", "V"},
             {"motion", "1"},
             {"position", "WGS84"}
           ]

    [moving, stopped] = imported.records
    assert length(moving.measurement_evidence_ids) == 3
    assert length(stopped.measurement_evidence_ids) == 2
    assert map_size(imported.bundle.evidence) == 12
    assert {:ok, _} = EvidenceBundle.validate(imported.bundle)

    transport = imported.bundle.evidence[moving.transport_evidence_id]
    assert transport.claim["schema"] == "wtr.teltonika-avl-record.v1"
    assert Enum.map(transport.claim["io_elements"], & &1["id"]) == [240, 113, 67, 999]

    assert {:ok, materialised} = materialise(imported, context)
    td = Wotex.ThingDescription.to_map(materialised.td)

    assert Map.keys(td["properties"]) |> Enum.sort() ==
             ~w(batteryLevel batteryVoltage motion position)

    assert td["properties"]["batteryLevel"]["maximum"] == 100
    assert materialised.bundle.observations[context.observation.id] === context.observation
  end

  test "profile marker, record count and frame integrity remain mandatory", context do
    for invalid <- [
          %{context.observation | ingress: "imported"},
          %{context.observation | source: %{"adapter" => "other"}},
          %{context.observation | transport: %{"codec" => 8, "record_count" => 2}},
          %{context.observation | transport: %{"codec" => 0x8E, "record_count" => 1}},
          %{
            context.observation
            | provenance: %{
                "protocol" => "teltonika-codec8-extended",
                "configured_profile" => "teltonika.tat140.codec8e"
              }
          },
          %{context.observation | payload: {:json, %{}}}
        ] do
      assert {:error, %Error{}} = ATC700.decode(invalid)
    end

    last = byte_size(context.frame) - 1
    <<prefix::binary-size(^last), byte>> = context.frame
    damaged = prefix <> <<Bitwise.bxor(byte, 1)>>
    assert {:error, %Error{code: :malformed_frame}} = damaged |> observation() |> ATC700.decode()
    assert {:error, %Error{code: :invalid_input}} = ATC700.decode(:forged)
  end

  defp materialise(imported, context) do
    association_id = "atc700-enrollment"
    thing_id = "urn:uuid:7586f4ad-a293-40f8-a013-df392ff41d62"

    {:ok, association} =
      Evidence.new(%{
        id: "atc700-identity",
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
      "priv/thing_models/cellular-asset-tracker-1.1.0.tm.json"
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
        revision: "atc700-deployment-1",
        title: "Compact cellular asset",
        forms: forms,
        security_definitions: %{"bearer" => %{"scheme" => "bearer"}},
        security: ["bearer"]
      })

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
  end

  defp observation(frame) do
    <<_::binary-size(9), record_count, _::binary>> = frame

    {:ok, observation} =
      Observation.new(%{
        id: "atc700-frame",
        observed_at: 1_700_000_000_500,
        ingress: "cellular",
        source: %{"adapter" => "teltonika-tcp", "device" => "configured-tracker"},
        addressing: %{"identity_digest" => String.duplicate("b", 64)},
        payload: {:bytes, frame},
        radio: %{},
        transport: %{"codec" => 0x8E, "record_count" => record_count},
        provenance: %{
          "protocol" => "teltonika-codec8-extended",
          "configured_profile" => ATC700.configured_profile(),
          "identity_assurance" => "configured-routing-identifier"
        }
      })

    observation
  end

  defp record(options) do
    event_io_id = Keyword.get(options, :event_io_id, 0)
    one = Keyword.get(options, :one_byte, [])
    two = Keyword.get(options, :two_byte, [])
    four = Keyword.get(options, :four_byte, [])
    eight = Keyword.get(options, :eight_byte, [])
    total = length(one) + length(two) + length(four) + length(eight)

    <<1_700_000_000_000::unsigned-big-64, 0, 0::signed-big-32, 0::signed-big-32,
      0::unsigned-big-16, 0::unsigned-big-16, 0, 0::unsigned-big-16, event_io_id::unsigned-big-16,
      total::unsigned-big-16, group(one, 1)::binary, group(two, 2)::binary,
      group(four, 4)::binary, group(eight, 8)::binary, 0::unsigned-big-16>>
  end

  defp group(elements, width) do
    entries = Enum.map(elements, fn {id, value} -> <<id::16, value::size(width)-unit(8)>> end)
    IO.iodata_to_binary([<<length(elements)::16>>, entries])
  end

  defp frame(records) do
    count = length(records)
    data = IO.iodata_to_binary([<<0x8E, count>>, records, <<count>>])
    <<0::32, byte_size(data)::32, data::binary, crc16(data)::32>>
  end

  defp crc16(bytes), do: Enum.reduce(:binary.bin_to_list(bytes), 0, &crc_byte/2)
  defp crc_byte(byte, crc), do: Enum.reduce(1..8, Bitwise.bxor(crc, byte), &crc_bit/2)

  defp crc_bit(_, value) do
    if Bitwise.band(value, 1) == 1,
      do: Bitwise.bxor(Bitwise.bsr(value, 1), 0xA001),
      else: Bitwise.bsr(value, 1)
  end
end
