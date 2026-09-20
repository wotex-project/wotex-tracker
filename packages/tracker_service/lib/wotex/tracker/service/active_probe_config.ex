defmodule Wotex.Tracker.Service.ActiveProbeConfig do
  @moduledoc """
  Closed configuration for an optional active-probe owner.

  Configuration selects only a supported transport and finite resource limits.
  Peer handles, pairing material and operating-system transport state stay in
  the configured adapter context and are excluded from inspection and status.
  """

  @derive {Inspect, only: [:max_concurrency]}
  @enforce_keys [:probes, :max_concurrency]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          probes: [map()],
          max_concurrency: pos_integer()
        }

  @schema "wtr.active-probe-host.v1"
  @fields ~w(schema enabled probes max_concurrency)
  @plan_fields ~w(profile probe transport operation target timeout_ms max_value_bytes)
  @identity_fields ~w(id version)
  @probe_fields ~w(id revision)
  @target_fields ~w(service_uuid characteristic_uuid handle object_path generation)
  @uuid ~r/\A(?:[0-9a-f]{4}|[0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/
  @maximum_json_integer 9_007_199_254_740_991

  @doc false
  @spec admit(term()) :: {:ok, t()} | :disabled | {:error, :invalid_options}
  def admit(%{"schema" => @schema, "enabled" => false} = document)
      when map_size(document) == 2,
      do: :disabled

  def admit(%{"schema" => @schema, "enabled" => true} = document)
      when map_size(document) == length(@fields) do
    with true <- Enum.sort(Map.keys(document)) == Enum.sort(@fields),
         {:ok, probes} <- probes(document["probes"]),
         true <- document["max_concurrency"] in 1..8 do
      {:ok,
       %__MODULE__{
         probes: probes,
         max_concurrency: document["max_concurrency"]
       }}
    else
      _ -> {:error, :invalid_options}
    end
  end

  def admit(_), do: {:error, :invalid_options}

  @doc false
  @spec plan(t(), map(), map()) :: {:ok, map()} | {:error, :invalid_request}
  def plan(%__MODULE__{probes: probes}, profile, probe) do
    case Enum.find(probes, &(&1["profile"] == profile and &1["probe"] == probe)) do
      nil -> {:error, :invalid_request}
      plan -> {:ok, plan}
    end
  end

  @doc false
  @spec status(t(), String.t(), non_neg_integer()) :: map()
  def status(%__MODULE__{} = config, availability, active) do
    %{
      "schema" => "wtr.active-probe-status.v1",
      "enabled" => true,
      "availability" => availability,
      "transports" => config.probes |> Enum.map(& &1["transport"]) |> Enum.uniq() |> Enum.sort(),
      "probes" => length(config.probes),
      "active" => active,
      "capacity" => config.max_concurrency
    }
  end

  defp probes(values) when is_list(values) and values != [] and length(values) <= 32 do
    with true <- Enum.all?(values, &plan?/1),
         identities = Enum.map(values, &{&1["profile"], &1["probe"]}),
         true <- length(identities) == length(Enum.uniq(identities)) do
      {:ok, values}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp probes(_), do: {:error, :invalid_options}

  defp plan?(plan) when is_map(plan) and map_size(plan) == length(@plan_fields) do
    Enum.sort(Map.keys(plan)) == Enum.sort(@plan_fields) and
      revision?(plan["profile"], @identity_fields) and
      revision?(plan["probe"], @probe_fields) and plan["transport"] == "ble_gatt" and
      plan["operation"] == "read" and target?(plan["target"]) and
      plan["timeout_ms"] in 100..30_000 and plan["max_value_bytes"] in 1..512
  end

  defp plan?(_), do: false

  defp revision?(value, fields) when is_map(value) and map_size(value) == 2 do
    Enum.sort(Map.keys(value)) == Enum.sort(fields) and Enum.all?(Map.values(value), &label?/1)
  end

  defp revision?(_, _), do: false

  defp label?(value) when is_binary(value) and byte_size(value) in 1..128,
    do: String.valid?(value) and not String.contains?(value, ["\0", "\r", "\n"])

  defp label?(_), do: false

  defp target?(target) when is_map(target) and map_size(target) == length(@target_fields) do
    Enum.sort(Map.keys(target)) == Enum.sort(@target_fields) and
      uuid?(target["service_uuid"]) and uuid?(target["characteristic_uuid"]) and
      nullable_handle?(target["handle"]) and nullable_path?(target["object_path"]) and
      nullable_generation?(target["generation"])
  end

  defp target?(_), do: false

  defp uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  defp uuid?(_), do: false

  defp nullable_handle?(nil), do: true
  defp nullable_handle?(value), do: is_integer(value) and value in 1..65_535

  defp nullable_path?(nil), do: true

  defp nullable_path?(value) when is_binary(value) and byte_size(value) in 1..1024,
    do:
      String.starts_with?(value, "/") and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"])

  defp nullable_path?(_), do: false

  defp nullable_generation?(nil), do: true

  defp nullable_generation?(value),
    do: is_integer(value) and value in 0..@maximum_json_integer
end
