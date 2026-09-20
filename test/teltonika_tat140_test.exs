defmodule Wotex.Tracker.TeltonikaTAT140Test do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.{Catalogue, Error, Observation, Resolution}
  alias Wotex.Tracker.Protocols.Teltonika.TAT140

  setup do
    {:ok, fixture} = Wotex.JSON.decode(File.read!("test/fixtures/teltonika/tat140.json"))
    [vector] = fixture["vectors"]

    %{frame: Base.decode16!(vector["hex"]), vector: vector}
  end

  test "configured evidence resolves the documentation-qualified profile", context do
    {:ok, profile} = TAT140.profile()
    {:ok, catalogue} = Catalogue.new([profile])
    observation = observation(context.frame)

    assert profile.decoder == TAT140.revision()
    assert profile.confidence == :strong
    assert profile.model == {"urn:wotex:tm:tracker:cellular-asset-tracker", "1.0.0"}
    assert profile.mapping["motion"] == "/properties/motion"
    assert profile.source_provenance["qualification"] == "documentation-fixture"

    assert {:ok, %{status: :resolved, selected: ^profile}} =
             Resolution.resolve(observation, catalogue)

    unknown = %{
      observation
      | provenance: Map.delete(observation.provenance, "configured_profile")
    }

    assert {:ok, %{status: :unknown, selected: nil}} = Resolution.resolve(unknown, catalogue)
  end

  test "every AVL record remains ordered with mapped fields and complete IO", context do
    assert Base.encode16(:crypto.hash(:sha256, context.frame), case: :lower) ==
             context.vector["sha256"]

    assert {:ok, message} = context.frame |> observation() |> TAT140.decode()
    assert message.kind == :avl_data
    assert message.protocol == "teltonika-codec8-extended"
    assert message.codec == 0x8E
    assert message.record_count == context.vector["record_count"]
    assert Enum.map(message.records, & &1.index) == [0, 1]

    [moving, stopped] = message.records
    [expected_moving, expected_stopped] = context.vector["records"]

    assert moving.timestamp_ms == expected_moving["timestamp_ms"]
    assert moving.trigger == %{"io_id" => 240, "mapped_kind" => "motion"}
    assert moving.gps["satellites"] == 8
    assert moving.gps["quality"] == "valid"
    assert Enum.map(moving.io_elements, & &1["id"]) == [240, 113, 67, 999]

    assert [motion, battery] = moving.measurements
    assert {motion.kind, motion.value, motion.unit} == {"motion", expected_moving["motion"], "1"}

    assert {battery.kind, battery.value, battery.unit} ==
             {"batteryVoltage", expected_moving["battery_voltage_v"], "V"}

    assert [position] = moving.positions
    assert position["longitude"] == expected_moving["longitude_deg"]
    assert position["latitude"] == expected_moving["latitude_deg"]
    assert position["speed_m_s"] == 10.0
    assert position["source_units"]["speed"] == "km/h"
    assert position["receiver_observation_id"] == "tat140-frame"

    assert stopped.timestamp_ms == expected_stopped["timestamp_ms"]
    assert stopped.positions == []
    assert stopped.gps["quality"] == "unavailable"
    assert stopped.gps["reason"] == "no_satellites"
    assert Enum.map(stopped.io_elements, & &1["id"]) == [240, 67, 999]

    assert Enum.map(stopped.measurements, &{&1.kind, &1.value}) == [
             {"motion", expected_stopped["motion"]},
             {"batteryVoltage", expected_stopped["battery_voltage_v"]}
           ]

    refute Enum.any?(moving.measurements, &(&1.kind == "batteryLevel"))
  end

  test "out-of-range and wrong-width known IO become unavailable without losing raw bytes" do
    frame =
      frame([
        record(
          event_io_id: 240,
          one_byte: [{240, 2}],
          two_byte: [{67, 3_600}],
          four_byte: [{67, 1}]
        )
      ])

    assert {:error, %Error{code: :invalid_decoder_result, path: "/records/0/io/67"}} =
             frame |> observation() |> TAT140.decode()

    frame = frame([record(event_io_id: 240, one_byte: [{240, 2}, {67, 7}])])

    assert {:ok, %{records: [%{measurements: [motion, battery]}]}} =
             frame |> observation() |> TAT140.decode()

    assert {motion.value, motion.availability, motion.reason} ==
             {nil, :unavailable, "wire_value_out_of_range"}

    assert motion.raw["raw_hex"] == "02"

    assert {battery.value, battery.availability, battery.reason} ==
             {nil, :unavailable, "unexpected_wire_width"}

    assert battery.raw["raw_hex"] == "07"
  end

  test "duplicate mapped IO is rejected instead of selecting by order" do
    frame = frame([record(one_byte: [{240, 0}, {240, 1}])])

    assert {:error, %Error{code: :invalid_decoder_result, path: "/records/0/io/240"}} =
             frame |> observation() |> TAT140.decode()
  end

  test "profile marker, observation shape, and frame integrity remain mandatory", context do
    observation = observation(context.frame)

    for invalid <- [
          %{observation | ingress: "imported"},
          %{observation | source: %{"adapter" => "other"}},
          %{observation | transport: %{"codec" => 8}},
          %{observation | transport: %{"codec" => 0x8E, "record_count" => 1}},
          %{observation | provenance: %{"configured_profile" => TAT140.configured_profile()}},
          %{observation | provenance: %{"configured_profile" => "teltonika.other"}},
          %{observation | payload: {:json, %{}}}
        ] do
      assert {:error, %Error{}} = TAT140.decode(invalid)
    end

    last = byte_size(context.frame) - 1
    <<prefix::binary-size(^last), byte>> = context.frame
    damaged = prefix <> <<Bitwise.bxor(byte, 1)>>
    assert {:error, %Error{code: :malformed_frame}} = damaged |> observation() |> TAT140.decode()
    assert {:error, %Error{code: :invalid_input}} = TAT140.decode(:forged)
  end

  defp observation(frame) do
    <<_::binary-size(9), record_count, _::binary>> = frame

    {:ok, observation} =
      Observation.new(%{
        id: "tat140-frame",
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

  defp crc_byte(byte, crc),
    do: Enum.reduce(1..8, Bitwise.bxor(crc, byte), &crc_bit/2)

  defp crc_bit(_, value) do
    if Bitwise.band(value, 1) == 1,
      do: Bitwise.bxor(Bitwise.bsr(value, 1), 0xA001),
      else: Bitwise.bsr(value, 1)
  end
end
