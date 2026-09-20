defmodule Wotex.Tracker.Service.AgentConnectorConfig do
  @moduledoc """
  Closed host configuration for an optional provider-neutral agent connector.

  Authorization material remains in process memory for the configured adapter
  and is excluded from inspection and status output.
  """

  @derive {Inspect,
           only: [
             :provider,
             :endpoint,
             :timeout_ms,
             :max_events,
             :max_response_bytes,
             :max_concurrency
           ]}
  @enforce_keys [
    :provider,
    :endpoint,
    :authorization,
    :timeout_ms,
    :max_events,
    :max_response_bytes,
    :max_concurrency
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider: String.t(),
          endpoint: String.t(),
          authorization: String.t(),
          timeout_ms: pos_integer(),
          max_events: pos_integer(),
          max_response_bytes: pos_integer(),
          max_concurrency: pos_integer()
        }

  @schema "wtr.agent-connector.v1"
  @fields ~w(schema enabled provider endpoint authorization timeout_ms max_events max_response_bytes max_concurrency)

  @doc false
  def admit(%{"schema" => @schema, "enabled" => false} = document)
      when map_size(document) == 2,
      do: :disabled

  def admit(%{"schema" => @schema, "enabled" => true} = document)
      when map_size(document) == length(@fields) do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         true <- provider?(document["provider"]),
         true <- endpoint?(document["endpoint"]),
         true <- authorization?(document["authorization"]),
         true <- document["timeout_ms"] in 100..30_000,
         true <- document["max_events"] in 1..128,
         true <- document["max_response_bytes"] in 256..1_048_576,
         true <- document["max_concurrency"] in 1..8 do
      {:ok,
       struct!(__MODULE__,
         provider: document["provider"],
         endpoint: document["endpoint"],
         authorization: document["authorization"],
         timeout_ms: document["timeout_ms"],
         max_events: document["max_events"],
         max_response_bytes: document["max_response_bytes"],
         max_concurrency: document["max_concurrency"]
       )}
    else
      _ -> {:error, :invalid_options}
    end
  end

  def admit(_), do: {:error, :invalid_options}

  @doc false
  def status(%__MODULE__{} = config, availability, active) do
    %{
      "schema" => "wtr.agent-connector-status.v1",
      "enabled" => true,
      "availability" => availability,
      "provider" => config.provider,
      "endpoint" => config.endpoint,
      "active" => active,
      "capacity" => config.max_concurrency
    }
  end

  defp provider?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: Regex.match?(~r/^[a-z][a-z0-9_-]*$/, value)

  defp provider?(_), do: false

  defp endpoint?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" ->
        String.valid?(value)

      _ ->
        false
    end
  end

  defp endpoint?(_), do: false

  defp authorization?(value) when is_binary(value) and byte_size(value) in 1..4096,
    do: String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"])

  defp authorization?(_), do: false
end
