defmodule Wotex.Tracker.TeltonikaCodec8ExtendedTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.Error
  alias Wotex.Tracker.Protocols.Teltonika.Codec8Extended
  alias Wotex.Tracker.Protocols.Teltonika.Codec8Extended.Stream

  setup do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("test/fixtures/teltonika/codec8_extended.json"))

    [vector] = fixture["vectors"]
    %{frame: Base.decode16!(vector["hex"]), vector: vector}
  end

  test "official Codec 8 Extended bytes retain record, GPS and IO provenance", context do
    assert {:ok, packet} = Codec8Extended.decode_frame(context.frame)
    assert packet.codec == 0x8E
    assert packet.data_length == 0x4A
    assert packet.record_count == 1
    assert packet.crc16 == context.vector["crc16"]

    assert [record] = packet.records
    assert record.timestamp_ms == context.vector["timestamp_ms"]
    assert record.priority == :high
    assert record.event_io_id == context.vector["event_io_id"]

    assert record.gps == %{
             longitude_raw: 0,
             latitude_raw: 0,
             longitude_deg: nil,
             latitude_deg: nil,
             altitude_m: 0,
             angle_deg: 0,
             satellites: 0,
             speed_km_h: 0,
             availability: :unavailable,
             quality: :unavailable,
             reason: "no_satellites"
           }

    expected = Enum.map(context.vector["io"], &Map.take(&1, ~w(id width unsigned)))

    actual =
      Enum.map(record.io_elements, fn element ->
        %{
          "id" => element.id,
          "width" => element.width,
          "unsigned" => element.unsigned
        }
      end)

    assert actual == expected
    assert Enum.all?(record.io_elements, &(byte_size(&1.raw) == &1.width))
  end

  test "every TCP split boundary and byte-at-a-time input reconstructs the same packet",
       context do
    assert {:ok, expected} = Codec8Extended.decode_frame(context.frame)

    for split <- 0..(byte_size(context.frame) - 1) do
      <<first::binary-size(split), second::binary>> = context.frame
      assert {:ok, state, []} = Codec8Extended.feed(Codec8Extended.new_stream(), first)
      assert {:ok, state, [^expected]} = Codec8Extended.feed(state, second)
      assert :ok = Codec8Extended.finish(state)
    end

    {state, packets} =
      context.frame
      |> :binary.bin_to_list()
      |> Enum.reduce({Codec8Extended.new_stream(), []}, fn byte, {state, packets} ->
        assert {:ok, state, decoded} = Codec8Extended.feed(state, <<byte>>)
        {state, packets ++ decoded}
      end)

    assert packets == [expected]
    assert :ok = Codec8Extended.finish(state)
  end

  test "a bounded feed decodes concatenated frames without conflating records", context do
    assert {:ok, packet} = Codec8Extended.decode_frame(context.frame)

    assert {:ok, state, packets} =
             Codec8Extended.feed(
               Codec8Extended.new_stream(),
               context.frame <> context.frame <> context.frame
             )

    assert packets == [packet, packet, packet]
    assert :ok = Codec8Extended.finish(state)

    sixteen = :binary.copy(context.frame, 16)
    assert {:ok, _, packets} = Codec8Extended.feed(Codec8Extended.new_stream(), sixteen)
    assert length(packets) == 16

    assert {:error, %Error{code: :limit_exceeded}} =
             Codec8Extended.feed(Codec8Extended.new_stream(), sixteen <> context.frame)
  end

  test "incomplete EOF remains distinct from malformed and oversized frames", context do
    for size <- 1..(byte_size(context.frame) - 1) do
      bytes = binary_part(context.frame, 0, size)
      assert {:ok, state, []} = Codec8Extended.feed(Codec8Extended.new_stream(), bytes)
      assert {:error, %Error{code: :malformed_frame}} = Codec8Extended.finish(state)
      assert {:error, %Error{code: :malformed_frame}} = Codec8Extended.decode_frame(bytes)
    end

    assert {:error, %Error{code: :malformed_frame}} =
             Codec8Extended.feed(Codec8Extended.new_stream(), <<1, 2, 3, 4, 0, 0, 0, 3>>)

    assert {:error, %Error{code: :limit_exceeded}} =
             Codec8Extended.feed(Codec8Extended.new_stream(), <<0::32, 1281::32>>)

    assert {:error, %Error{code: :limit_exceeded}} =
             Codec8Extended.decode_frame(:binary.copy(<<0>>, 1293))

    assert {:error, %Error{code: :limit_exceeded}} =
             Codec8Extended.feed(Codec8Extended.new_stream(), :binary.copy(<<0>>, 20_673))

    assert {:error, %Error{code: :limit_exceeded}} =
             Codec8Extended.feed(%Stream{buffer: :binary.copy(<<0>>, 1292)}, <<>>)

    assert {:error, %Error{code: :invalid_input}} = Codec8Extended.finish(:forged)

    assert {:error, %Error{code: :invalid_input}} =
             Codec8Extended.finish(%Stream{buffer: :forged})

    assert {:error, %Error{code: :invalid_input}} = Codec8Extended.feed(:forged, <<>>)
    assert {:error, %Error{code: :invalid_input}} = Codec8Extended.decode_frame(:forged)

    assert {:error, %Error{code: :malformed_frame}} =
             Codec8Extended.decode_frame(context.frame <> <<0>>)

    assert {:error, %Error{code: :malformed_frame}} =
             Codec8Extended.decode_frame(<<1, 2, 3, 4, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0>>)

    assert {:error, %Error{code: :malformed_frame}} =
             Codec8Extended.decode_frame(<<0::32, 2::32, 0, 0, 0::32>>)
  end

  test "checksum, codec, priority and count failures are typed", context do
    last = byte_size(context.frame) - 1
    <<prefix::binary-size(last), byte>> = context.frame
    damaged_crc = prefix <> <<Bitwise.bxor(byte, 1)>>

    assert {:error, %Error{code: :malformed_frame, path: "/crc16"}} =
             Codec8Extended.decode_frame(damaged_crc)

    for {offset, value, expected_code, expected_path} <- [
          {8, 0, :unsupported_version, "/codec"},
          {9, 0, :limit_exceeded, "/record_count"},
          {18, 3, :malformed_frame, "/records/priority"},
          {byte_size(context.frame) - 5, 0, :malformed_frame, "/record_count"}
        ] do
      assert {:error, %Error{code: ^expected_code, path: ^expected_path}} =
               context.frame
               |> replace(offset, value)
               |> repair_crc()
               |> Codec8Extended.decode_frame()
    end

    <<preamble::binary-size(4), length::binary-size(4), data::binary-size(0x4A), _crc::binary>> =
      context.frame

    assert {:error, %Error{code: :malformed_frame, path: "/records/io/count"}} =
             (preamble <> length <> replace(data, 29, 4))
             |> append_crc()
             |> Codec8Extended.decode_frame()

    <<0::32, _::32, data::binary-size(0x4A), _::32>> = context.frame

    assert {:error, %Error{code: :malformed_frame}} =
             data
             |> then(&frame_data(&1 <> <<0>>))
             |> Codec8Extended.decode_frame()
  end

  test "unknown fixed and variable IO remain bounded raw values" do
    record =
      <<1_700_000_000_000::unsigned-big-64, 2, 180_000_000::signed-big-32,
        -590_000_000::signed-big-32, 5::unsigned-big-16, 359::unsigned-big-16, 8,
        27::unsigned-big-16, 500::unsigned-big-16, 2::unsigned-big-16, 1::unsigned-big-16,
        65_000::unsigned-big-16, 7, 0::unsigned-big-16, 0::unsigned-big-16, 0::unsigned-big-16,
        1::unsigned-big-16, 65_001::unsigned-big-16, 3::unsigned-big-16, 1, 2, 3>>

    frame = append_crc(<<0::32, byte_size(record) + 3::32, 0x8E, 1, record::binary, 1>>)
    assert {:ok, %{records: [decoded]}} = Codec8Extended.decode_frame(frame)
    assert decoded.priority == :panic

    assert decoded.gps.longitude_deg == 18.0
    assert decoded.gps.latitude_deg == -59.0
    assert decoded.gps.altitude_m == 5
    assert decoded.gps.quality == :valid

    assert [fixed, variable] = decoded.io_elements
    assert fixed == %{id: 65_000, width: 1, raw: <<7>>, unsigned: 7}
    assert variable == %{id: 65_001, width: :variable, raw: <<1, 2, 3>>, unsigned: nil}

    assert {:ok, <<0, 0, 0, 1>>} = Codec8Extended.acknowledgement(1)
    assert {:ok, <<0, 0, 0, 0>>} = Codec8Extended.acknowledgement(0)
    assert {:error, %Error{code: :invalid_input}} = Codec8Extended.acknowledgement(256)
  end

  test "low priority and suspect GPS remain explicit without normalized coordinates" do
    record =
      bare_record(priority: 0, longitude: 2_000_000_000, latitude: 0, satellites: 1) <>
        empty_io()

    assert {:ok, %{records: [decoded]}} =
             record |> record_frame() |> Codec8Extended.decode_frame()

    assert decoded.priority == :low
    assert decoded.gps.availability == :available
    assert decoded.gps.quality == :suspect
    assert decoded.gps.reason == "gps_field_out_of_range"
    assert decoded.gps.longitude_raw == 2_000_000_000
    assert decoded.gps.longitude_deg == nil
    assert decoded.gps.latitude_deg == nil
  end

  test "malformed IO group shapes fail without partial records" do
    too_many_across_groups =
      <<0::16, 256::16, 129::16, fixed_entries(1, 129)::binary, 128::16,
        fixed_entries(2, 128)::binary, 0::16, 0::16, 0::16>>

    malformed_records = [
      <<0>>,
      bare_record() <> <<0>>,
      bare_record() <> <<0::16, 257::16>>,
      bare_record() <> <<0::16, 0::16, 257::16>>,
      bare_record() <> <<0::16, 1::16>>,
      bare_record() <> <<0::16, 1::16, 1::16, 42::16>>,
      bare_record() <> <<0::16, 0::16, 0::16, 0::16, 0::16, 0::16>>,
      bare_record() <> <<0::16, 0::16, 0::16, 0::16, 0::16, 257::16>>,
      bare_record() <> <<0::16, 1::16, 0::16, 0::16, 0::16, 0::16, 1::16, 42::16, 3::16, 1, 2>>,
      bare_record() <> too_many_across_groups
    ]

    for record <- malformed_records do
      assert {:error, %Error{code: code}} =
               record |> record_frame() |> Codec8Extended.decode_frame()

      assert code in [:malformed_frame, :limit_exceeded]
    end
  end

  defp repair_crc(frame) do
    size = byte_size(frame) - 4
    <<without_crc::binary-size(size), _::binary-size(4)>> = frame
    append_crc(without_crc)
  end

  defp append_crc(<<0::32, length::32, data::binary-size(length)>> = without_crc) do
    without_crc <> <<crc16(data)::unsigned-big-32>>
  end

  defp frame_data(data), do: append_crc(<<0::32, byte_size(data)::32, data::binary>>)
  defp record_frame(record), do: frame_data(<<0x8E, 1, record::binary, 1>>)

  defp bare_record(options \\ []) do
    priority = Keyword.get(options, :priority, 1)
    longitude = Keyword.get(options, :longitude, 0)
    latitude = Keyword.get(options, :latitude, 0)
    satellites = Keyword.get(options, :satellites, 0)

    <<1_700_000_000_000::unsigned-big-64, priority, longitude::signed-big-32,
      latitude::signed-big-32, 0::unsigned-big-16, 0::unsigned-big-16, satellites,
      0::unsigned-big-16>>
  end

  defp empty_io, do: <<0::16, 0::16, 0::16, 0::16, 0::16, 0::16, 0::16>>

  defp fixed_entries(width, count) do
    entry = <<1::16, 0::size(width)-unit(8)>>
    :binary.copy(entry, count)
  end

  defp replace(bytes, offset, value) do
    <<prefix::binary-size(offset), _old, suffix::binary>> = bytes
    prefix <> <<value>> <> suffix
  end

  defp crc16(bytes) do
    Enum.reduce(:binary.bin_to_list(bytes), 0, &crc_byte/2)
  end

  defp crc_byte(byte, crc),
    do: Enum.reduce(1..8, Bitwise.bxor(crc, byte), &crc_bit/2)

  defp crc_bit(_, value) do
    if Bitwise.band(value, 1) == 1,
      do: Bitwise.bxor(Bitwise.bsr(value, 1), 0xA001),
      else: Bitwise.bsr(value, 1)
  end
end
