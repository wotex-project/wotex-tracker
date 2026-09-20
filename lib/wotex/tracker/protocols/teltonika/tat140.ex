defmodule Wotex.Tracker.Protocols.Teltonika.TAT140 do
  @moduledoc """
  Pure TAT140 profile and record-aware Codec 8 Extended semantic mapping.

  The mapper consumes one admitted cellular observation and preserves every AVL
  record in order. It maps only the documented TAT140 movement (AVL 240) and
  battery-voltage (AVL 67) elements, plus valid Codec GPS fields. All IO bytes
  remain in the result, including unsupported identifiers. A frame is an
  `:avl_data` message even when none of its records contains a usable position or
  mapped measurement.

  The configured profile marker is operator routing evidence. It permits a
  strong deterministic profile match but does not authenticate the hardware,
  IMEI, firmware, carrier, or deployment. This implementation is qualified only
  against documentation-derived fixtures.
  """

  alias Wotex.Tracker.{DeviceProfile, Error, Measurement, Observation, Position}
  alias Wotex.Tracker.Protocols.Teltonika.Codec8Extended

  @revision {"teltonika.tat140.codec8e", "1.0.0"}
  @profile "teltonika.tat140.codec8e"
  @known_io [67, 240]

  @type mapped_record :: %{
          index: non_neg_integer(),
          timestamp_ms: non_neg_integer(),
          priority: :low | :high | :panic,
          trigger: map(),
          gps: map(),
          positions: [map()],
          measurements: [Measurement.t()],
          io_elements: [map()]
        }
  @type message :: %{
          kind: :avl_data,
          protocol: String.t(),
          codec: 0x8E,
          record_count: pos_integer(),
          records: [mapped_record()]
        }

  @doc "Returns the immutable record-mapper revision for explicit host configuration."
  @spec revision() :: {String.t(), String.t()}
  def revision, do: @revision

  @doc "Returns the exact configured-profile marker required on observations."
  @spec configured_profile() :: String.t()
  def configured_profile, do: @profile

  @doc "Builds the documentation-qualified TAT140 Codec 8 Extended profile."
  @spec profile() :: {:ok, DeviceProfile.t()} | {:error, Error.t()}
  def profile do
    DeviceProfile.new(%{
      id: @profile,
      version: "1.0.0",
      confidence: :strong,
      fingerprints: [
        %{"op" => "eq", "field" => "ingress", "pointer" => "", "value" => "cellular"},
        %{
          "op" => "eq",
          "field" => "source",
          "pointer" => "/adapter",
          "value" => "teltonika-tcp"
        },
        %{"op" => "eq", "field" => "transport", "pointer" => "/codec", "value" => 0x8E},
        %{
          "op" => "eq",
          "field" => "provenance",
          "pointer" => "/configured_profile",
          "value" => @profile
        }
      ],
      decoder: @revision,
      model: {"urn:wotex:tm:tracker:cellular-asset-tracker", "1.0.0"},
      mapping_revision: "1.0.0",
      mapping: %{
        "position" => "/properties/position",
        "motion" => "/properties/motion",
        "batteryVoltage" => "/properties/batteryVoltage"
      },
      source_provenance: %{
        "kind" => "documentation",
        "read_at" => "2026-09-20",
        "qualification" => "documentation-fixture",
        "sources" => [
          "https://wiki.teltonika-gps.com/view/TAT100_AVL_ID_List",
          "https://wiki.teltonika-gps.com/view/TAT140_System_settings"
        ]
      }
    })
  end

  @doc "Maps an admitted, explicitly configured TAT140 AVL frame without collapsing records."
  @spec decode(term()) :: {:ok, message()} | {:error, Error.t()}
  def decode(observation) do
    with {:ok, observation} <- Observation.validate(observation),
         :ok <- configured_observation(observation),
         {:bytes, frame} <- observation.payload,
         {:ok, packet} <- Codec8Extended.decode_frame(frame),
         :ok <- consistent_record_count(packet, observation),
         {:ok, records} <- records(packet.records, observation, 0, []) do
      {:ok,
       %{
         kind: :avl_data,
         protocol: "teltonika-codec8-extended",
         codec: packet.codec,
         record_count: packet.record_count,
         records: records
       }}
    else
      {:error, %Error{}} = error -> error
      _ -> fail(:invalid_input)
    end
  end

  defp configured_observation(%Observation{} = observation) do
    if observation.ingress == "cellular" and
         observation.source["adapter"] === "teltonika-tcp" and
         observation.transport["codec"] === 0x8E and
         observation.provenance["protocol"] === "teltonika-codec8-extended" and
         observation.provenance["configured_profile"] === @profile,
       do: :ok,
       else: fail(:invalid_input, "/provenance/configured_profile")
  end

  defp consistent_record_count(packet, observation) do
    if packet.record_count == length(packet.records) and
         observation.transport["record_count"] === packet.record_count,
       do: :ok,
       else: fail(:invalid_input, "/transport/record_count")
  end

  defp records([], _observation, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp records([record | rest], observation, index, acc) do
    with :ok <- unique_known_io(record.io_elements, index),
         {:ok, positions} <- positions(record, observation),
         {:ok, measurements} <- measurements(record.io_elements) do
      mapped = %{
        index: index,
        timestamp_ms: record.timestamp_ms,
        priority: record.priority,
        trigger: trigger(record.event_io_id),
        gps: gps(record.gps),
        positions: positions,
        measurements: measurements,
        io_elements: Enum.map(record.io_elements, &io_element/1)
      }

      records(rest, observation, index + 1, [mapped | acc])
    end
  end

  defp unique_known_io(elements, record_index) do
    case Enum.find(@known_io, fn id -> Enum.count(elements, &(&1.id == id)) > 1 end) do
      nil -> :ok
      id -> fail(:invalid_decoder_result, "/records/#{record_index}/io/#{id}")
    end
  end

  defp measurements(elements) do
    with {:ok, movement} <- measurement(elements, 240, &movement/1),
         {:ok, battery} <- measurement(elements, 67, &battery_voltage/1) do
      {:ok, Enum.reject([movement, battery], &is_nil/1)}
    end
  end

  defp measurement(elements, id, mapper) do
    case Enum.find(elements, &(&1.id == id)) do
      nil -> {:ok, nil}
      element -> mapper.(element)
    end
  end

  defp movement(%{width: 1, unsigned: value} = element) when value in 0..1,
    do: available("motion", value == 1, "1", element)

  defp movement(element), do: unavailable("motion", "1", element, "wire_value_out_of_range")

  defp battery_voltage(%{width: 2, unsigned: value} = element),
    do: available("batteryVoltage", value / 1000, "V", element)

  defp battery_voltage(element),
    do: unavailable("batteryVoltage", "V", element, "unexpected_wire_width")

  defp available(kind, value, unit, element) do
    Measurement.new(%{
      kind: kind,
      value: value,
      unit: unit,
      availability: :available,
      quality: :valid,
      raw: io_element(element),
      reason: "wire_value"
    })
  end

  defp unavailable(kind, unit, element, reason) do
    Measurement.new(%{
      kind: kind,
      value: nil,
      unit: unit,
      availability: :unavailable,
      quality: :unavailable,
      raw: io_element(element),
      reason: reason
    })
  end

  defp positions(%{gps: %{quality: :valid} = gps, timestamp_ms: timestamp}, observation) do
    claim = %{
      "schema" => "wtr.position.v1",
      "latitude" => gps.latitude_deg,
      "longitude" => gps.longitude_deg,
      "altitude_m" => gps.altitude_m,
      "speed_m_s" => gps.speed_km_h / 3.6,
      "horizontal_accuracy_m" => nil,
      "accuracy_kind" => "unknown",
      "source" => "gnss",
      "fix_at" => timestamp,
      "device_at" => timestamp,
      "received_at" => observation.observed_at,
      "fix_clock" => "untrusted",
      "device_clock" => "untrusted",
      "availability" => "available",
      "quality" => "valid",
      "source_units" => %{
        "latitude" => "deg",
        "longitude" => "deg",
        "altitude" => "m",
        "speed" => "km/h",
        "accuracy" => nil,
        "fix_time" => "unix-ms",
        "device_time" => "unix-ms",
        "receiver_time" => "unix-ms"
      },
      "conversion_revision" => "teltonika.tat140.position.v1",
      "raw" => gps(gps),
      "receiver_observation_id" => observation.id
    }

    with :ok <- Position.admit_claim(claim), do: {:ok, [claim]}
  end

  defp positions(_record, _observation), do: {:ok, []}

  defp trigger(id) do
    %{
      "io_id" => id,
      "mapped_kind" =>
        case id do
          67 -> "batteryVoltage"
          240 -> "motion"
          _ -> nil
        end
    }
  end

  defp gps(gps) do
    %{
      "longitude_raw" => gps.longitude_raw,
      "latitude_raw" => gps.latitude_raw,
      "longitude_deg" => gps.longitude_deg,
      "latitude_deg" => gps.latitude_deg,
      "altitude_m" => gps.altitude_m,
      "angle_deg" => gps.angle_deg,
      "satellites" => gps.satellites,
      "speed_km_h" => gps.speed_km_h,
      "availability" => Atom.to_string(gps.availability),
      "quality" => Atom.to_string(gps.quality),
      "reason" => gps.reason
    }
  end

  defp io_element(element) do
    %{
      "id" => element.id,
      "width" => if(element.width == :variable, do: "variable", else: element.width),
      "raw_hex" => Base.encode16(element.raw),
      "unsigned" => element.unsigned
    }
  end

  defp fail(code, path \\ "/"), do: {:error, Error.new(code, :decode, path)}
end
