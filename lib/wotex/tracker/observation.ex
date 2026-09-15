defmodule Wotex.Tracker.Observation do
  @moduledoc """
  Bounded capture facts with explicit receiver Unix milliseconds and physical ingress.

  `new/2` admits atom-keyed constructor fields. `from_map/2` admits the versioned
  string-keyed export. Byte payloads use canonical Base64 in that export; JSON
  payloads preserve native types. No transport address implies device identity.
  """
  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(id observed_at ingress source addressing payload radio transport provenance)a
  @ingresses ~w(ble cellular lorawan mqtt http serial imported)
  @type t :: %__MODULE__{
          id: String.t(),
          observed_at: integer(),
          ingress: String.t(),
          source: map(),
          addressing: map(),
          payload: {:bytes, binary()} | {:json, term()},
          radio: map(),
          transport: map(),
          provenance: map()
        }
  @enforce_keys @fields
  defstruct @fields

  @doc "Admits capture facts without reading a clock or invoking a decoder."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.id(input.id, limits),
         true <- is_integer(input.observed_at),
         true <- input.ingress in @ingresses,
         :ok <-
           Admission.each(
             [input.source, input.addressing, input.radio, input.transport, input.provenance],
             &Admission.object(&1, limits)
           ),
         :ok <- payload(input.payload, limits) do
      {:ok, struct!(__MODULE__, input)}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Re-admits all fields, including values behind an untrusted struct tag."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])
  def validate(%__MODULE__{} = value, options), do: new(Map.from_struct(value), options)
  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Exports the exact observation as version 1 JSON, with a tagged payload."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, observation} <- validate(value, options) do
      map = Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(observation, &1)})

      {:ok,
       map
       |> Map.put("payload", export_payload(observation.payload))
       |> Map.put("schema", "wtr.observation.v1")}
    end
  end

  @doc "Admits a versioned native JSON export without creating atoms from input."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- export_shape(map),
         {:ok, payload} <- import_payload(map["payload"], limits) do
      fields = Map.new(@fields, &{&1, Map.fetch!(map, Atom.to_string(&1))})
      new(Map.put(fields, :payload, payload), options)
    end
  end

  @doc "Admits a JSON wire envelope through upstream duplicate-preserving bounded parsing."
  @spec from_json(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_json(source, options \\ []) do
    with {:ok, limits} <- Limits.new(options) do
      case Wotex.JSON.decode(source, export_limits(limits)) do
        {:ok, map} -> from_map(map, options)
        {:error, _} -> Admission.fail(:invalid_json)
      end
    end
  end

  @doc "Content identity covers every field with type-strict upstream canonical JSON."
  @spec identity(term(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def identity(value, options \\ []) do
    with {:ok, limits} <- Limits.new(options), {:ok, map} <- to_map(value, options) do
      Admission.digest(map, export_limits(limits))
    end
  end

  @doc "Checks idempotence using full type-strict admitted content."
  @spec same?(term(), term()) :: boolean()
  def same?(left, right) do
    case {validate(left), validate(right)} do
      {{:ok, a}, {:ok, b}} -> a === b
      _ -> false
    end
  end

  defp payload({:bytes, bytes}, limits) when is_binary(bytes) do
    if byte_size(bytes) <= limits.max_payload_bytes,
      do: :ok,
      else: Admission.fail(:limit_exceeded)
  end

  defp payload({:json, json}, limits), do: Admission.json(json, limits)
  defp payload(_, _), do: Admission.fail(:invalid_input)

  defp export_payload({:bytes, bytes}),
    do: %{"kind" => "bytes", "encoding" => "base64", "data" => Base.encode64(bytes)}

  defp export_payload({:json, json}), do: %{"kind" => "json", "value" => json}

  defp import_payload(%{"kind" => "bytes", "encoding" => "base64", "data" => data} = map, limits)
       when map_size(map) == 3 and is_binary(data) do
    if byte_size(data) <= 4 * div(limits.max_payload_bytes + 2, 3) do
      decode_base64(data)
    else
      Admission.fail(:limit_exceeded)
    end
  end

  defp import_payload(%{"kind" => "json", "value" => value} = map, _limits)
       when map_size(map) == 2,
       do: {:ok, {:json, value}}

  defp import_payload(_, _), do: Admission.fail(:invalid_input)

  defp decode_base64(data) do
    with {:ok, bytes} <- Base.decode64(data),
         true <- Base.encode64(bytes) == data do
      {:ok, {:bytes, bytes}}
    else
      _ -> Admission.fail(:invalid_input)
    end
  end

  defp export_shape(map) when is_map(map) and map_size(map) == 10 do
    if map["schema"] == "wtr.observation.v1" and
         Enum.all?(@fields, &Map.has_key?(map, Atom.to_string(&1))),
       do: :ok,
       else: Admission.fail(:invalid_input)
  end

  defp export_shape(_), do: Admission.fail(:invalid_input)

  # Export is larger than each separately admitted input, chiefly because Base64 expands bytes.
  defp export_limits(limits) do
    [
      max_bytes: 6 * limits.max_bytes + 4 * div(limits.max_payload_bytes + 2, 3) + 8192,
      max_depth: limits.max_depth + 3,
      max_nodes: 6 * limits.max_nodes + 64,
      max_collection_size: max(16, limits.max_collection_size),
      max_string_bytes:
        max(
          4 * div(limits.max_payload_bytes + 2, 3),
          max(limits.max_string_bytes, limits.max_id_bytes)
        ) + 64
    ]
  end
end
