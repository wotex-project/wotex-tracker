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

  alias Wotex.Tracker.{DeviceProfile, Error, Measurement}
  alias Wotex.Tracker.Protocols.Teltonika.AssetProfile

  @revision {"teltonika.tat140.codec8e", "1.0.0"}
  @profile "teltonika.tat140.codec8e"
  @contract :teltonika_tat140_codec8e
  @config %{
    profile: @profile,
    revision: @revision,
    model: {"urn:wotex:tm:tracker:cellular-asset-tracker", "1.0.0"},
    mapping_revision: "1.0.0",
    mapping: %{
      "position" => "/properties/position",
      "motion" => "/properties/motion",
      "batteryVoltage" => "/properties/batteryVoltage"
    },
    measurements: [
      %{id: 240, kind: "motion", unit: "1", width: 1, conversion: :boolean},
      %{id: 67, kind: "batteryVoltage", unit: "V", width: 2, conversion: :millivolts}
    ],
    position_revision: "teltonika.tat140.position.v1",
    source_provenance: %{
      "kind" => "documentation",
      "read_at" => "2026-09-20",
      "qualification" => "documentation-fixture",
      "sources" => [
        "https://wiki.teltonika-gps.com/view/TAT100_AVL_ID_List",
        "https://wiki.teltonika-gps.com/view/TAT140_System_settings"
      ]
    }
  }

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

  @doc false
  @spec contract() :: :teltonika_tat140_codec8e
  def contract, do: @contract

  @doc false
  @spec capability_units() :: map()
  def capability_units,
    do: %{"batteryVoltage" => "V", "motion" => "1", "position" => "WGS84"}

  @doc "Builds the documentation-qualified TAT140 Codec 8 Extended profile."
  @spec profile() :: {:ok, DeviceProfile.t()} | {:error, Error.t()}
  def profile, do: AssetProfile.profile(@config)

  @doc "Maps an admitted, explicitly configured TAT140 AVL frame without collapsing records."
  @spec decode(term()) :: {:ok, message()} | {:error, Error.t()}
  def decode(observation), do: AssetProfile.decode(observation, @config)
end
