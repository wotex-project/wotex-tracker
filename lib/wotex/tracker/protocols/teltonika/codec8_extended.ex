defmodule Wotex.Tracker.Protocols.Teltonika.Codec8Extended do
  @moduledoc """
  Pure, bounded framing and decoding for Teltonika Codec 8 Extended TCP data.

  The decoder accepts only the documented `0x8E` AVL data packet. It validates
  the zero preamble, big-endian data length, matching record counts and the
  CRC-16/IBM value before returning records. Unknown IO identifiers remain
  bounded raw values; this module does not assign device-specific semantics.

  `feed/2` retains at most one incomplete frame and handles arbitrary TCP split
  boundaries or a bounded batch of concatenated frames. IMEI negotiation,
  authorization, durable admission and acknowledgement timing belong to the
  host-owned session layer.
  """

  import Bitwise, only: [band: 2, bxor: 2, bsr: 2]

  alias Wotex.Tracker.Error

  @codec 0x8E
  @max_data_bytes 1280
  @max_frame_bytes @max_data_bytes + 12
  @max_batch_frames 16
  @max_chunk_bytes @max_frame_bytes * @max_batch_frames
  @max_records 33
  @max_io_elements 256

  defmodule Stream do
    @moduledoc "Bounded incomplete-frame state returned by `Codec8Extended.feed/2`."

    @type t :: %__MODULE__{buffer: binary()}
    @enforce_keys [:buffer]
    defstruct [:buffer]
  end

  @type io_element :: %{
          id: non_neg_integer(),
          width: 1 | 2 | 4 | 8 | :variable,
          raw: binary(),
          unsigned: non_neg_integer() | nil
        }
  @type gps :: %{
          longitude_raw: integer(),
          latitude_raw: integer(),
          longitude_deg: float() | nil,
          latitude_deg: float() | nil,
          altitude_m: non_neg_integer(),
          angle_deg: non_neg_integer(),
          satellites: non_neg_integer(),
          speed_km_h: non_neg_integer(),
          availability: :available | :unavailable,
          quality: :valid | :suspect | :unavailable,
          reason: String.t()
        }
  @type avl_record :: %{
          timestamp_ms: non_neg_integer(),
          priority: :low | :high | :panic,
          gps: gps(),
          event_io_id: non_neg_integer(),
          io_elements: [io_element()]
        }
  @type packet :: %{
          codec: 0x8E,
          data_length: pos_integer(),
          record_count: pos_integer(),
          records: [avl_record()],
          crc16: non_neg_integer()
        }

  @doc "Returns an empty bounded stream state for TCP data packets after IMEI admission."
  @spec new_stream() :: Stream.t()
  def new_stream, do: %Stream{buffer: <<>>}

  @doc "Feeds one bounded TCP chunk and returns every complete validated packet."
  @spec feed(term(), term()) ::
          {:ok, Stream.t(), [packet()]} | {:error, Error.t()}
  def feed(%Stream{buffer: buffer}, chunk)
      when is_binary(buffer) and is_binary(chunk) and byte_size(buffer) < @max_frame_bytes and
             byte_size(chunk) <= @max_chunk_bytes do
    drain(buffer <> chunk, [], 0)
  end

  def feed(%Stream{}, chunk) when is_binary(chunk), do: fail(:limit_exceeded)
  def feed(_, _), do: fail(:invalid_input)

  @doc "Rejects EOF while a partial packet remains buffered."
  @spec finish(term()) :: :ok | {:error, Error.t()}
  def finish(%Stream{buffer: <<>>}), do: :ok

  def finish(%Stream{buffer: buffer})
      when is_binary(buffer) and byte_size(buffer) < @max_frame_bytes,
      do: fail(:malformed_frame)

  def finish(_), do: fail(:invalid_input)

  @doc "Decodes exactly one complete Codec 8 Extended TCP AVL packet."
  @spec decode_frame(term()) :: {:ok, packet()} | {:error, Error.t()}
  def decode_frame(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_frame_bytes do
    case take_frame(bytes) do
      {:frame, frame, <<>>} -> decode_complete(frame)
      {:frame, _, _} -> fail(:malformed_frame)
      :incomplete -> fail(:malformed_frame)
      {:error, _} = error -> error
    end
  end

  def decode_frame(bytes) when is_binary(bytes), do: fail(:limit_exceeded)
  def decode_frame(_), do: fail(:invalid_input)

  @doc "Encodes the documented four-byte accepted-record acknowledgement."
  @spec acknowledgement(term()) :: {:ok, binary()} | {:error, Error.t()}
  def acknowledgement(count) when is_integer(count) and count in 0..255,
    do: {:ok, <<count::unsigned-big-32>>}

  def acknowledgement(_), do: fail(:invalid_input)

  defp drain(bytes, packets, count) when count < @max_batch_frames do
    case take_frame(bytes) do
      :incomplete ->
        {:ok, %Stream{buffer: bytes}, Enum.reverse(packets)}

      {:frame, frame, rest} ->
        with {:ok, packet} <- decode_complete(frame),
             do: drain(rest, [packet | packets], count + 1)

      {:error, _} = error ->
        error
    end
  end

  defp drain(<<>>, packets, _count), do: {:ok, new_stream(), Enum.reverse(packets)}
  defp drain(_, _, _), do: fail(:limit_exceeded)

  defp take_frame(bytes) when byte_size(bytes) < 8, do: :incomplete

  defp take_frame(<<0::unsigned-big-32, length::unsigned-big-32, rest::binary>>) do
    cond do
      length < 3 ->
        fail(:malformed_frame)

      length > @max_data_bytes ->
        fail(:limit_exceeded)

      byte_size(rest) < length + 4 ->
        :incomplete

      true ->
        <<data::binary-size(^length), crc::binary-size(4), tail::binary>> = rest
        {:frame, <<0::unsigned-big-32, length::unsigned-big-32, data::binary, crc::binary>>, tail}
    end
  end

  defp take_frame(_), do: fail(:malformed_frame)

  defp decode_complete(
         <<0::unsigned-big-32, length::unsigned-big-32, data::binary-size(length),
           wire_crc::unsigned-big-32>>
       ) do
    calculated = crc16(data)

    with true <- wire_crc <= 0xFFFF and wire_crc == calculated,
         {:ok, count, records} <- decode_data(data) do
      {:ok,
       %{
         codec: @codec,
         data_length: length,
         record_count: count,
         records: records,
         crc16: calculated
       }}
    else
      false -> fail(:malformed_frame, "/crc16")
      {:error, _} = error -> error
    end
  end

  defp decode_complete(_), do: fail(:malformed_frame)

  defp decode_data(<<@codec, count, rest::binary>>) when count in 1..@max_records do
    with {:ok, records, <<second_count>>} <- records(rest, count, []),
         true <- second_count == count do
      {:ok, count, records}
    else
      false -> fail(:malformed_frame, "/record_count")
      {:ok, _, _} -> fail(:malformed_frame)
      {:error, _} = error -> error
    end
  end

  defp decode_data(<<@codec, _count, _::binary>>), do: fail(:limit_exceeded, "/record_count")
  defp decode_data(<<_codec, _::binary>>), do: fail(:unsupported_version, "/codec")
  defp decode_data(_), do: fail(:malformed_frame)

  defp records(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp records(bytes, count, acc) do
    with {:ok, record, rest} <- record(bytes),
         do: records(rest, count - 1, [record | acc])
  end

  defp record(
         <<timestamp::unsigned-big-64, priority, longitude::signed-big-32,
           latitude::signed-big-32, altitude::unsigned-big-16, angle::unsigned-big-16, satellites,
           speed::unsigned-big-16, rest::binary>>
       ) do
    with {:ok, priority} <- priority(priority),
         {:ok, event_io_id, elements, rest} <- io(rest) do
      {:ok,
       %{
         timestamp_ms: timestamp,
         priority: priority,
         gps: gps(longitude, latitude, altitude, angle, satellites, speed),
         event_io_id: event_io_id,
         io_elements: elements
       }, rest}
    end
  end

  defp record(_), do: fail(:malformed_frame, "/records")

  defp priority(0), do: {:ok, :low}
  defp priority(1), do: {:ok, :high}
  defp priority(2), do: {:ok, :panic}
  defp priority(_), do: fail(:malformed_frame, "/records/priority")

  defp gps(longitude, latitude, altitude, angle, satellites, speed) do
    coordinates? =
      longitude in -1_800_000_000..1_800_000_000 and latitude in -900_000_000..900_000_000

    angle? = angle <= 360
    available? = satellites > 0
    {quality, reason} = gps_quality(available?, coordinates? and angle?)
    normalized? = quality == :valid

    %{
      longitude_raw: longitude,
      latitude_raw: latitude,
      longitude_deg: if(normalized?, do: longitude / 10_000_000, else: nil),
      latitude_deg: if(normalized?, do: latitude / 10_000_000, else: nil),
      altitude_m: altitude,
      angle_deg: angle,
      satellites: satellites,
      speed_km_h: speed,
      availability: if(available?, do: :available, else: :unavailable),
      quality: quality,
      reason: reason
    }
  end

  defp gps_quality(false, _), do: {:unavailable, "no_satellites"}
  defp gps_quality(true, true), do: {:valid, "wire_value"}
  defp gps_quality(true, false), do: {:suspect, "gps_field_out_of_range"}

  defp io(<<event_id::unsigned-big-16, total::unsigned-big-16, rest::binary>>)
       when total <= @max_io_elements do
    with {:ok, fixed, rest} <- fixed_groups(rest, [1, 2, 4, 8], []),
         {:ok, variable, rest} <- variable_group(rest),
         elements = fixed ++ variable,
         true <- length(elements) == total do
      {:ok, event_id, elements, rest}
    else
      false -> fail(:malformed_frame, "/records/io/count")
      {:error, _} = error -> error
    end
  end

  defp io(<<_event_id::unsigned-big-16, _total::unsigned-big-16, _::binary>>),
    do: fail(:limit_exceeded, "/records/io/count")

  defp io(_), do: fail(:malformed_frame, "/records/io")

  defp fixed_groups(rest, [], groups),
    do: {:ok, groups |> Enum.reverse() |> List.flatten(), rest}

  defp fixed_groups(<<count::unsigned-big-16, rest::binary>>, [width | widths], groups)
       when count <= @max_io_elements do
    with {:ok, elements, rest} <- fixed_elements(rest, count, width, []),
         true <- Enum.sum(Enum.map(groups, &length/1)) + length(elements) <= @max_io_elements do
      fixed_groups(rest, widths, [Enum.reverse(elements) | groups])
    else
      false -> fail(:limit_exceeded, "/records/io/count")
      {:error, _} = error -> error
    end
  end

  defp fixed_groups(<<_::unsigned-big-16, _::binary>>, _, _),
    do: fail(:limit_exceeded, "/records/io/count")

  defp fixed_groups(_, _, _), do: fail(:malformed_frame, "/records/io")

  defp fixed_elements(rest, 0, _width, acc), do: {:ok, acc, rest}

  defp fixed_elements(<<id::unsigned-big-16, rest::binary>>, count, width, acc)
       when byte_size(rest) >= width do
    <<raw::binary-size(^width), rest::binary>> = rest
    element = %{id: id, width: width, raw: raw, unsigned: :binary.decode_unsigned(raw)}
    fixed_elements(rest, count - 1, width, [element | acc])
  end

  defp fixed_elements(_, _, _, _), do: fail(:malformed_frame, "/records/io")

  defp variable_group(<<count::unsigned-big-16, rest::binary>>) when count <= @max_io_elements,
    do: variable_elements(rest, count, [])

  defp variable_group(<<_::unsigned-big-16, _::binary>>),
    do: fail(:limit_exceeded, "/records/io/count")

  defp variable_group(_), do: fail(:malformed_frame, "/records/io")

  defp variable_elements(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp variable_elements(
         <<id::unsigned-big-16, length::unsigned-big-16, rest::binary>>,
         count,
         acc
       )
       when byte_size(rest) >= length do
    <<raw::binary-size(^length), rest::binary>> = rest
    element = %{id: id, width: :variable, raw: raw, unsigned: nil}
    variable_elements(rest, count - 1, [element | acc])
  end

  defp variable_elements(_, _, _), do: fail(:malformed_frame, "/records/io")

  defp crc16(bytes) do
    Enum.reduce(:binary.bin_to_list(bytes), 0, &crc_byte/2)
  end

  defp crc_byte(byte, crc), do: Enum.reduce(1..8, bxor(crc, byte), &crc_bit/2)

  defp crc_bit(_, value) do
    if band(value, 1) == 1,
      do: bxor(bsr(value, 1), 0xA001),
      else: bsr(value, 1)
  end

  defp fail(code, path \\ "/"), do: {:error, Error.new(code, :decode, path)}
end
