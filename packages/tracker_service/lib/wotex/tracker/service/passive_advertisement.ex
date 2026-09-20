defmodule Wotex.Tracker.Service.PassiveAdvertisement do
  @moduledoc """
  Closed capture returned by one explicitly configured passive BLE adapter.

  This is reception evidence, not device identity. In particular, the observed
  address may be private and may change between otherwise related captures.
  """

  alias Wotex.Tracker.Service.Codec

  @keys ~w(id observed_at receiver address address_type manufacturer_id payload rssi provenance)a
  @address_types ~w(public random_private_resolvable random_private_non_resolvable unknown)a
  @maximum_payload_bytes 512

  @enforce_keys @keys
  defstruct @keys

  @type t :: %__MODULE__{
          id: String.t(),
          observed_at: integer(),
          receiver: String.t(),
          address: String.t(),
          address_type:
            :public
            | :random_private_resolvable
            | :random_private_non_resolvable
            | :unknown,
          manufacturer_id: non_neg_integer(),
          payload: binary(),
          rssi: integer(),
          provenance: map()
        }

  @doc "Admits one bounded passive advertisement without reading a clock."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_advertisement}
  def new(input) when is_map(input) do
    with true <- map_size(input) == length(@keys),
         true <- Enum.all?(@keys, &Map.has_key?(input, &1)),
         true <- Codec.id?(input.id),
         true <- is_integer(input.observed_at),
         true <- Codec.id?(input.receiver),
         true <- token?(input.address, 128),
         true <- input.address_type in @address_types,
         true <- is_integer(input.manufacturer_id) and input.manufacturer_id in 0..65_535,
         true <-
           is_binary(input.payload) and byte_size(input.payload) in 1..@maximum_payload_bytes,
         true <- is_integer(input.rssi) and input.rssi in -127..20,
         true <- provenance?(input.provenance) do
      {:ok, struct!(__MODULE__, input)}
    else
      _ -> {:error, :invalid_advertisement}
    end
  end

  def new(_), do: {:error, :invalid_advertisement}

  @doc "Re-admits a capture, including fields behind an untrusted struct tag."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_advertisement}
  def validate(%__MODULE__{} = value), do: value |> Map.from_struct() |> new()
  def validate(_), do: {:error, :invalid_advertisement}

  defp provenance?(value) when is_map(value) and map_size(value) in 1..8 do
    Enum.all?(value, fn {key, item} -> token?(key, 64) and scalar?(item) end)
  end

  defp provenance?(_), do: false

  defp scalar?(value) when is_boolean(value) or is_integer(value), do: true
  defp scalar?(value), do: token?(value, 256)

  defp token?(value, maximum) when is_binary(value) and byte_size(value) in 1..maximum//1,
    do: String.valid?(value) and not String.contains?(value, ["\0", "\n", "\r"])

  defp token?(_, _), do: false
end
