defmodule Wotex.Tracker.Protocols.Teltonika.AssetProfile do
  @moduledoc false

  alias Wotex.Tracker.{DeviceProfile, Error, Measurement, Observation, Position}
  alias Wotex.Tracker.Protocols.Teltonika.Codec8Extended

  @type config :: %{
          required(:profile) => String.t(),
          required(:revision) => {String.t(), String.t()},
          required(:model) => {String.t(), String.t()},
          required(:mapping_revision) => String.t(),
          required(:mapping) => map(),
          required(:measurements) => [map()],
          required(:position_revision) => String.t(),
          required(:source_provenance) => map()
        }

  @doc false
  @spec profile(config()) :: {:ok, DeviceProfile.t()} | {:error, Error.t()}
  def profile(config) do
    DeviceProfile.new(%{
      id: config.profile,
      version: elem(config.revision, 1),
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
          "value" => config.profile
        }
      ],
      decoder: config.revision,
      model: config.model,
      mapping_revision: config.mapping_revision,
      mapping: config.mapping,
      source_provenance: config.source_provenance
    })
  end

  @doc false
  @spec decode(term(), config()) :: {:ok, map()} | {:error, Error.t()}
  def decode(observation, config) do
    with {:ok, observation} <- Observation.validate(observation),
         :ok <- configured_observation(observation, config.profile),
         {:bytes, frame} <- observation.payload,
         {:ok, packet} <- Codec8Extended.decode_frame(frame),
         :ok <- consistent_record_count(packet, observation),
         {:ok, records} <- records(packet.records, observation, config, 0, []) do
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

  defp configured_observation(%Observation{} = observation, profile) do
    if observation.ingress == "cellular" and
         observation.source["adapter"] === "teltonika-tcp" and
         observation.transport["codec"] === 0x8E and
         observation.provenance["protocol"] === "teltonika-codec8-extended" and
         observation.provenance["configured_profile"] === profile,
       do: :ok,
       else: fail(:invalid_input, "/provenance/configured_profile")
  end

  defp consistent_record_count(packet, observation) do
    if packet.record_count == length(packet.records) and
         observation.transport["record_count"] === packet.record_count,
       do: :ok,
       else: fail(:invalid_input, "/transport/record_count")
  end

  defp records([], _observation, _config, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp records([record | rest], observation, config, index, acc) do
    with :ok <- unique_known_io(record.io_elements, config.measurements, index),
         {:ok, positions} <- positions(record, observation, config),
         {:ok, measurements} <- measurements(record.io_elements, config.measurements) do
      mapped = %{
        index: index,
        timestamp_ms: record.timestamp_ms,
        priority: record.priority,
        trigger: trigger(record.event_io_id, config.measurements),
        gps: gps(record.gps),
        positions: positions,
        measurements: measurements,
        io_elements: Enum.map(record.io_elements, &io_element/1)
      }

      records(rest, observation, config, index + 1, [mapped | acc])
    end
  end

  defp unique_known_io(elements, definitions, record_index) do
    case Enum.find(definitions, fn definition ->
           Enum.count(elements, &(&1.id == definition.id)) > 1
         end) do
      nil -> :ok
      definition -> fail(:invalid_decoder_result, "/records/#{record_index}/io/#{definition.id}")
    end
  end

  defp measurements(elements, definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, mapped} ->
      case measurement(elements, definition) do
        {:ok, nil} -> {:cont, {:ok, mapped}}
        {:ok, value} -> {:cont, {:ok, [value | mapped]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      error -> error
    end)
  end

  defp measurement(elements, definition) do
    case Enum.find(elements, &(&1.id == definition.id)) do
      nil -> {:ok, nil}
      element -> convert(element, definition)
    end
  end

  defp convert(%{width: 1, unsigned: value} = element, %{conversion: :boolean} = definition)
       when value in 0..1,
       do: available(definition, value == 1, element)

  defp convert(%{width: 1, unsigned: value} = element, %{conversion: :percent} = definition)
       when value in 0..100,
       do: available(definition, value, element)

  defp convert(%{width: 2, unsigned: value} = element, %{conversion: :millivolts} = definition),
    do: available(definition, value / 1000, element)

  defp convert(%{width: width} = element, %{width: width} = definition),
    do: unavailable(definition, element, "wire_value_out_of_range")

  defp convert(element, definition),
    do: unavailable(definition, element, "unexpected_wire_width")

  defp available(definition, value, element) do
    Measurement.new(%{
      kind: definition.kind,
      value: value,
      unit: definition.unit,
      availability: :available,
      quality: :valid,
      raw: io_element(element),
      reason: "wire_value"
    })
  end

  defp unavailable(definition, element, reason) do
    Measurement.new(%{
      kind: definition.kind,
      value: nil,
      unit: definition.unit,
      availability: :unavailable,
      quality: :unavailable,
      raw: io_element(element),
      reason: reason
    })
  end

  defp positions(%{gps: %{quality: :valid} = gps, timestamp_ms: timestamp}, observation, config) do
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
      "conversion_revision" => config.position_revision,
      "raw" => gps(gps),
      "receiver_observation_id" => observation.id
    }

    with :ok <- Position.admit_claim(claim), do: {:ok, [claim]}
  end

  defp positions(_record, _observation, _config), do: {:ok, []}

  defp trigger(id, definitions) do
    definition = Enum.find(definitions, &(&1.id == id))
    %{"io_id" => id, "mapped_kind" => if(definition, do: definition.kind, else: nil)}
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
