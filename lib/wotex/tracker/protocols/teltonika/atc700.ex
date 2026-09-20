defmodule Wotex.Tracker.Protocols.Teltonika.ATC700 do
  @moduledoc """
  Documentation-qualified ATC700 Codec 8 Extended profile and semantic mapping.

  The profile maps only Teltonika's current documented ATC700 movement (AVL
  240), battery voltage (AVL 67), battery level (AVL 113), and valid Codec GPS
  fields. It preserves every record and all unknown IO bytes. The configured
  profile marker is operator routing evidence, not proof of model, firmware,
  network, identity, or physical capability.
  """

  alias Wotex.Tracker.{DeviceProfile, Error}
  alias Wotex.Tracker.Protocols.Teltonika.AssetProfile

  @revision {"teltonika.atc700.codec8e", "1.0.0"}
  @profile "teltonika.atc700.codec8e"
  @contract :teltonika_atc700_codec8e
  @config %{
    profile: @profile,
    revision: @revision,
    model: {"urn:wotex:tm:tracker:cellular-asset-tracker", "1.1.0"},
    mapping_revision: "1.0.0",
    mapping: %{
      "position" => "/properties/position",
      "motion" => "/properties/motion",
      "batteryVoltage" => "/properties/batteryVoltage",
      "batteryLevel" => "/properties/batteryLevel"
    },
    measurements: [
      %{id: 240, kind: "motion", unit: "1", width: 1, conversion: :boolean},
      %{id: 67, kind: "batteryVoltage", unit: "V", width: 2, conversion: :millivolts},
      %{id: 113, kind: "batteryLevel", unit: "%", width: 1, conversion: :percent}
    ],
    position_revision: "teltonika.atc700.position.v1",
    source_provenance: %{
      "kind" => "documentation",
      "read_at" => "2026-09-20",
      "qualification" => "documentation-fixture",
      "sources" => [
        "https://wiki.teltonika-gps.com/view/ATC700_Teltonika_Data_Sending_Parameters_ID",
        "https://wiki.teltonika-gps.com/view/ATC700_Tracking_settings",
        "https://wiki.teltonika-gps.com/view/ATC700_Mobile_network"
      ]
    }
  }

  @doc "Returns the immutable record-mapper revision for explicit host configuration."
  @spec revision() :: {String.t(), String.t()}
  def revision, do: @revision

  @doc "Returns the exact configured-profile marker required on observations."
  @spec configured_profile() :: String.t()
  def configured_profile, do: @profile

  @doc false
  @spec contract() :: :teltonika_atc700_codec8e
  def contract, do: @contract

  @doc false
  @spec capability_units() :: map()
  def capability_units,
    do: %{
      "batteryLevel" => "%",
      "batteryVoltage" => "V",
      "motion" => "1",
      "position" => "WGS84"
    }

  @doc "Builds the documentation-qualified ATC700 Codec 8 Extended profile."
  @spec profile() :: {:ok, DeviceProfile.t()} | {:error, Error.t()}
  def profile, do: AssetProfile.profile(@config)

  @doc "Maps an admitted, explicitly configured ATC700 AVL frame without collapsing records."
  @spec decode(term()) :: {:ok, map()} | {:error, Error.t()}
  def decode(observation), do: AssetProfile.decode(observation, @config)
end
