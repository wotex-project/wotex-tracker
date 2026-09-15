defmodule Wotex.Tracker.Decoders.RuuviRawV2 do
  @moduledoc """
  Pure Ruuvi format-5 decoder, revision 1.0.0, for the exact 24-byte payload.
  The little-endian company ID is separate from big-endian sensor fields.
  Sentinels remain unavailable. Humidity above 100% is suspect evidence.
  This proves format support, not SKU, identity, movement state or battery percentage.
  """
  import Bitwise, only: [band: 2, bsr: 2]
  alias Wotex.Tracker.{DeviceProfile, Error, Measurement, Observation}

  @revision {"ruuvi.rawv2", "1.0.0"}
  @properties ~w(temperature humidity pressure accelerationX accelerationY accelerationZ batteryVoltage txPower movementCounter measurementSequence)

  @doc "Returns the immutable decoder revision for explicit host configuration."
  @spec revision() :: {String.t(), String.t()}
  def revision, do: @revision

  @doc "Builds the format-family profile, without claiming a specific physical SKU."
  @spec profile() :: {:ok, DeviceProfile.t()} | {:error, Error.t()}
  def profile do
    DeviceProfile.new(%{
      id: "ruuvi.rawv2",
      version: "1.0.0",
      confidence: :exact,
      fingerprints: [
        %{"op" => "eq", "field" => "ingress", "pointer" => "", "value" => "ble"},
        %{
          "op" => "eq",
          "field" => "transport",
          "pointer" => "/manufacturer_id",
          "value" => 0x0499
        },
        %{"op" => "length", "value" => 24},
        %{"op" => "byte", "offset" => 0, "value" => 5}
      ],
      decoder: @revision,
      model: {"urn:wotex:tm:tracker:environmental-sensor", "1.0.0"},
      mapping_revision: "1.0.0",
      mapping: Map.new(@properties, &{&1, "/properties/" <> &1}),
      source_provenance: %{
        "kind" => "documentation",
        "source" =>
          "https://docs.ruuvi.com/communication/bluetooth-advertisements/data-format-5-rawv2",
        "source_sha256" => "8e698f0d9a484c11106e3d540431a08b2450158f1f5b3c50002252d1bdf869fd",
        "qualification" => "fixture"
      }
    })
  end

  @doc "Separates company bytes from an exact 26-byte manufacturer-data field."
  @spec manufacturer_data(term()) :: {:ok, map()} | {:error, Error.t()}
  def manufacturer_data(<<0x99, 0x04, payload::binary-size(24)>>),
    do: {:ok, %{payload: {:bytes, payload}, transport: %{"manufacturer_id" => 0x0499}}}

  def manufacturer_data(_), do: {:error, Error.new(:malformed_frame, :decode)}

  @doc "Decodes an admitted capture into measurements and unauthenticated protocol identity facts."
  @spec decode(term()) :: {:ok, map()} | {:error, Error.t()}
  def decode(observation) do
    with {:ok, observation} <- Observation.validate(observation),
         do: decode_payload(observation.payload)
  end

  defp decode_payload({:bytes, bytes}) when byte_size(bytes) == 24 do
    case bytes do
      <<5, temperature::signed-16, humidity::16, pressure::16, x::signed-16, y::signed-16,
        z::signed-16, power::16, movement, sequence::16, mac::binary-size(6)>> ->
        measurements = [
          value("temperature", temperature, -32_768, "Cel", &(&1 / 200)),
          value("humidity", humidity, 65_535, "%", &(&1 / 400)),
          value("pressure", pressure, 65_535, "Pa", &(&1 + 50_000)),
          value("accelerationX", x, -32_768, "g", &(&1 / 1000)),
          value("accelerationY", y, -32_768, "g", &(&1 / 1000)),
          value("accelerationZ", z, -32_768, "g", &(&1 / 1000)),
          value("batteryVoltage", bsr(power, 5), 2047, "V", &((&1 + 1600) / 1000)),
          value("txPower", band(power, 31), 31, "dBm", &(&1 * 2 - 40)),
          value("movementCounter", movement, 255, "1", & &1),
          value("measurementSequence", sequence, 65_535, "1", & &1)
        ]

        {:ok,
         %{
           measurements: measurements,
           identity: %{
             "protocol_mac" => mac(mac),
             "assurance" => "unauthenticated_protocol_identifier"
           }
         }}

      _ ->
        {:error, Error.new(:unsupported_version, :decode)}
    end
  end

  defp decode_payload(_), do: {:error, Error.new(:malformed_frame, :decode)}

  defp value(kind, raw, sentinel, unit, scale) do
    available = raw != sentinel
    value = if available, do: scale.(raw), else: nil
    suspect = available and kind == "humidity" and value > 100
    {quality, reason} = quality(available, suspect)

    {:ok, measurement} =
      Measurement.new(%{
        kind: kind,
        raw: raw,
        value: value,
        unit: unit,
        availability: if(available, do: :available, else: :unavailable),
        quality: quality,
        reason: reason
      })

    measurement
  end

  defp quality(false, _), do: {:unavailable, "wire_sentinel"}
  defp quality(true, true), do: {:suspect, "humidity_above_physical_range"}
  defp quality(true, false), do: {:valid, "wire_value"}

  defp mac(<<255, 255, 255, 255, 255, 255>>), do: nil
  defp mac(bytes), do: Base.encode16(bytes, case: :lower)
end
