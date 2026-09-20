defmodule Wotex.Tracker.ProbeContract do
  @moduledoc """
  Closed declarative contract for one bounded, read-only profile probe.

  Contracts contain no callback or transport handle. They bind a profile-owned
  probe revision to a public GATT target, finite execution/value budgets and a
  conjunction of byte predicates. A successful match may strengthen profile
  confidence; a mismatch is explicitly either rejecting or uninformative.
  """

  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(id revision transport operation target timeout_ms max_value_bytes predicates match_confidence mismatch failure)
  @target_fields ~w(service_uuid characteristic_uuid)
  @uuid ~r/\A(?:[0-9a-f]{4}|[0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/

  @type confidence :: :exact | :strong
  @type t :: %__MODULE__{document: map(), predicates: [tuple()]}
  @enforce_keys [:document, :predicates]
  defstruct @enforce_keys

  @doc "Admits one exact probe contract with finite byte and execution bounds."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(document, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.object(document, limits),
         true <- exact_fields?(document, @fields),
         :ok <- Admission.id(document["id"], limits),
         :ok <- Admission.id(document["revision"], limits),
         true <- document["transport"] == "ble_gatt",
         true <- document["operation"] == "read",
         true <- target?(document["target"]),
         true <- document["timeout_ms"] in 100..30_000,
         true <- document["max_value_bytes"] in 1..512,
         :ok <- Admission.bounded_list(document["predicates"], limits.max_predicates),
         true <- document["predicates"] != [],
         {:ok, predicates} <- predicates(document["predicates"], document["max_value_bytes"]),
         true <- Enum.any?(predicates, &(elem(&1, 0) in [:byte, :bytes])),
         true <- document["match_confidence"] in ~w(exact strong),
         true <- document["mismatch"] in ~w(reject uninformative),
         true <- document["failure"] == "unavailable" do
      {:ok, %__MODULE__{document: document, predicates: predicates}}
    else
      false -> Admission.fail(:invalid_profile)
      {:error, %Error{}} = error -> error
      _ -> Admission.fail(:invalid_profile)
    end
  end

  @doc "Revalidates a contract, including a forged struct."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{document: document} = value, options) do
    with {:ok, admitted} <- new(document, options), true <- admitted === value do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_profile)

  @doc "Evaluates admitted response bytes without invoking supplied code."
  @spec match?(term(), term(), term()) :: {:ok, boolean()} | {:error, Error.t()}
  def match?(contract, value, options \\ []) do
    with {:ok, contract} <- validate(contract, options),
         true <- is_binary(value),
         true <- byte_size(value) <= contract.document["max_value_bytes"] do
      {:ok, Enum.all?(contract.predicates, &evaluate(&1, value))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc false
  @spec key(t()) :: {String.t(), String.t()}
  def key(%__MODULE__{document: document}), do: {document["id"], document["revision"]}

  @doc false
  @spec promotion(t()) :: confidence()
  def promotion(%__MODULE__{document: %{"match_confidence" => "exact"}}), do: :exact
  def promotion(%__MODULE__{document: %{"match_confidence" => "strong"}}), do: :strong

  @doc false
  @spec mismatch(t()) :: :reject | :uninformative
  def mismatch(%__MODULE__{document: %{"mismatch" => "reject"}}), do: :reject
  def mismatch(%__MODULE__{document: %{"mismatch" => "uninformative"}}), do: :uninformative

  @doc false
  @spec compatible_confidence?(t(), atom()) :: boolean()
  def compatible_confidence?(contract, confidence) do
    rank = %{unknown: 0, candidate: 1, strong: 2, exact: 3}
    Map.has_key?(rank, confidence) and rank[promotion(contract)] >= rank[confidence]
  end

  @doc false
  @spec equivalent_uuid?(term(), term()) :: boolean()
  def equivalent_uuid?(left, right) do
    uuid?(left) and uuid?(right) and canonical_uuid(left) == canonical_uuid(right)
  end

  defp predicates(definitions, max_value_bytes) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, acc} ->
      case predicate(definition, max_value_bytes) do
        {:ok, predicate} -> {:cont, {:ok, [predicate | acc]}}
        :error -> {:halt, Admission.fail(:invalid_profile)}
      end
    end)
    |> case do
      {:ok, predicates} -> {:ok, Enum.reverse(predicates)}
      error -> error
    end
  end

  defp predicate(%{"op" => "length", "value" => value} = document, max)
       when map_size(document) == 2 and is_integer(value) and value >= 0 and value <= max,
       do: {:ok, {:length, value}}

  defp predicate(%{"op" => "byte", "offset" => offset, "value" => value} = document, max)
       when map_size(document) == 3 and is_integer(offset) and offset >= 0 and offset < max and
              is_integer(value) and value in 0..255,
       do: {:ok, {:byte, offset, value}}

  defp predicate(
         %{"op" => "bytes", "offset" => offset, "encoding" => "base64", "data" => data} =
           document,
         max
       )
       when map_size(document) == 4 and is_integer(offset) and offset >= 0 and is_binary(data) do
    with {:ok, bytes} <- Base.decode64(data),
         true <- bytes != <<>>,
         true <- Base.encode64(bytes) == data,
         true <- offset + byte_size(bytes) <= max do
      {:ok, {:bytes, offset, bytes}}
    else
      _ -> :error
    end
  end

  defp predicate(_, _), do: :error

  defp evaluate({:length, expected}, value), do: byte_size(value) == expected

  defp evaluate({:byte, offset, expected}, value),
    do: offset < byte_size(value) and :binary.at(value, offset) == expected

  defp evaluate({:bytes, offset, expected}, value) do
    size = byte_size(expected)
    offset + size <= byte_size(value) and binary_part(value, offset, size) == expected
  end

  defp target?(target) do
    exact_fields?(target, @target_fields) and uuid?(target["service_uuid"]) and
      uuid?(target["characteristic_uuid"])
  end

  defp exact_fields?(value, fields) when is_map(value) and map_size(value) == length(fields),
    do: Enum.sort(Map.keys(value)) == Enum.sort(fields)

  defp exact_fields?(_, _), do: false

  defp uuid?(value) when is_binary(value), do: Regex.match?(@uuid, value)
  defp uuid?(_), do: false

  defp canonical_uuid(<<uuid::binary-size(4)>>),
    do: "0000" <> uuid <> "-0000-1000-8000-00805f9b34fb"

  defp canonical_uuid(<<uuid::binary-size(8)>>),
    do: uuid <> "-0000-1000-8000-00805f9b34fb"

  defp canonical_uuid(uuid), do: uuid
end
