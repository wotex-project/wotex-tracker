defmodule Wotex.Tracker.Host.Development.PassiveSimulatorConfig do
  @moduledoc """
  Private dev/test-only configuration for the deterministic passive BLE peer.

  This module is absent from production builds. The configuration must name the
  simulator explicitly and its credential must already hold `ingest` authority
  in the ordinary host configuration.
  """

  alias Wotex.Tracker.Service.{Credentials, PassiveAdvertisement}
  alias Wotex.Tracker.Service.Development.PassiveSimulator
  alias Wotex.Tracker.Service.HTTP.FileConfig

  @derive {Inspect, only: [:adapter, :scope, :advertisement_count]}
  @enforce_keys [:adapter, :scope, :advertisement_count, :ingress, :scanner]
  defstruct @enforce_keys

  @doc "Loads one private finite simulator scenario."
  @spec load(term(), keyword()) :: {:ok, struct()} | {:error, :invalid_configuration}
  def load(path, service_options) when is_list(service_options) do
    with {:ok, document} <- FileConfig.read_document(path),
         true <- simulator_document?(document),
         credentials when not is_nil(credentials) <- service_options[:credentials],
         true <-
           Credentials.configured?(
             credentials,
             document["token"],
             document["scope"],
             "ingest"
           ),
         {:ok, advertisements} <- advertisements(document["advertisements"]) do
      {:ok,
       %__MODULE__{
         adapter: document["adapter"],
         scope: document["scope"],
         advertisement_count: length(advertisements),
         ingress: [
           token: document["token"],
           scope: document["scope"],
           adapter: document["adapter"]
         ],
         scanner: [
           adapter: {PassiveSimulator, advertisements},
           interval_ms: document["interval_ms"],
           timeout_ms: document["timeout_ms"]
         ]
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def load(_, _), do: {:error, :invalid_configuration}

  defp simulator_document?(document) when is_map(document) and map_size(document) == 7 do
    document["schema"] == "wtr.passive-ble-simulator.v1" and
      document["adapter"] == "development-passive-simulator" and
      is_binary(document["token"]) and is_binary(document["scope"]) and
      is_integer(document["interval_ms"]) and document["interval_ms"] in 0..60_000 and
      is_integer(document["timeout_ms"]) and document["timeout_ms"] in 1..30_000 and
      Map.has_key?(document, "advertisements")
  end

  defp simulator_document?(_), do: false

  defp advertisements(values) when is_list(values) and values != [] and length(values) <= 1_024,
    do: admit_advertisements(values, [])

  defp advertisements(_), do: {:error, :invalid_scenario}

  defp admit_advertisements([], admitted), do: {:ok, Enum.reverse(admitted)}

  defp admit_advertisements([value | rest], admitted) do
    with {:ok, input} <- advertisement_input(value),
         {:ok, advertisement} <- PassiveAdvertisement.new(input) do
      admit_advertisements(rest, [advertisement | admitted])
    else
      _ -> {:error, :invalid_scenario}
    end
  end

  defp advertisement_input(value) when is_map(value) and map_size(value) == 9 do
    with true <-
           Enum.sort(Map.keys(value)) ==
             Enum.sort(
               ~w(id observed_at receiver address address_type manufacturer_id payload_hex rssi provenance)
             ),
         {:ok, address_type} <- address_type(value["address_type"]),
         {:ok, payload} <- payload(value["payload_hex"]) do
      {:ok,
       %{
         id: value["id"],
         observed_at: value["observed_at"],
         receiver: value["receiver"],
         address: value["address"],
         address_type: address_type,
         manufacturer_id: value["manufacturer_id"],
         payload: payload,
         rssi: value["rssi"],
         provenance: value["provenance"]
       }}
    else
      _ -> {:error, :invalid_advertisement}
    end
  end

  defp advertisement_input(_), do: {:error, :invalid_advertisement}

  defp address_type("public"), do: {:ok, :public}
  defp address_type("random_private_resolvable"), do: {:ok, :random_private_resolvable}
  defp address_type("random_private_non_resolvable"), do: {:ok, :random_private_non_resolvable}
  defp address_type("unknown"), do: {:ok, :unknown}
  defp address_type(_), do: {:error, :invalid_advertisement}

  defp payload(value) when is_binary(value) and byte_size(value) in 2..1_024//2 do
    with {:ok, decoded} <- Base.decode16(value, case: :upper),
         true <- Base.encode16(decoded, case: :upper) == value do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_advertisement}
    end
  end

  defp payload(_), do: {:error, :invalid_advertisement}
end
