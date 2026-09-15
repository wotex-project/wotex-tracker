defmodule Wotex.Tracker.Service.Codec do
  @moduledoc false

  @options [
    max_bytes: 1_048_576,
    max_depth: 64,
    max_nodes: 65_536,
    max_string_bytes: 262_144,
    max_collection_size: 4096
  ]

  def encode(value, bytes \\ 1_048_576) do
    with {:ok, encoded} <- Wotex.JSON.encode(value, Keyword.put(@options, :max_bytes, bytes)),
         true <- byte_size(encoded) <= bytes do
      {:ok, encoded}
    else
      _ -> {:error, :invalid_json}
    end
  end

  def decode(bytes), do: Wotex.JSON.decode(bytes, @options)

  def encode!(value) do
    {:ok, bytes} = encode(value)
    bytes
  end

  def decode!(bytes) do
    {:ok, value} = decode(bytes)
    value
  end

  def digest(value), do: :crypto.hash(:sha256, encode!(value)) |> Base.encode16(case: :lower)

  def id?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.valid?(value)

  def generation(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 and integer < 9_223_372_036_854_775_807 ->
        if Integer.to_string(integer) == value, do: {:ok, integer}, else: :error

      _ ->
        :error
    end
  end

  def generation(_), do: :error

  def time?(value), do: is_integer(value) and value in 0..9_007_199_254_740_991
end
