defmodule Wotex.Tracker.Predicate do
  @moduledoc """
  Closed declarative fingerprints over admitted capture facts. Byte/length and
  JSON equality/membership predicates execute no supplied code or regular expression.
  """
  alias Wotex.Tracker.{Admission, Error, Limits, Observation}

  @fields ~w(ingress source addressing radio transport provenance payload_json)
  @type t :: %__MODULE__{document: map()}
  @enforce_keys [:document]
  defstruct [:document]

  @doc "Admits one closed predicate definition under JSON budgets."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(document, options \\ []) do
    with {:ok, limits} <- Limits.new(options), :ok <- Admission.object(document, limits) do
      if shape?(document),
        do: {:ok, %__MODULE__{document: document}},
        else: Admission.fail(:invalid_predicate)
    end
  end

  @doc "Matches only after revalidating both the predicate and observation."
  @spec match?(term(), term(), term()) :: {:ok, boolean()} | {:error, Error.t()}
  def match?(predicate, observation, options \\ [])

  def match?(%__MODULE__{document: document}, observation, options) do
    with {:ok, _} <- new(document, options),
         {:ok, observation} <- Observation.validate(observation, options) do
      {:ok, evaluate_admitted(document, observation)}
    end
  end

  def match?(_, _, _), do: Admission.fail(:invalid_predicate)

  @doc "Classifies whether a predicate uses protocol evidence beyond names and radio strength."
  @spec discriminating?(t()) :: boolean()
  def discriminating?(%__MODULE__{document: %{"op" => "byte"}}), do: true

  def discriminating?(%__MODULE__{document: %{"field" => "transport", "pointer" => pointer}}),
    do: pointer in ~w(/manufacturer_id /service_uuids /service_data /protocol /codec /version)

  def discriminating?(%__MODULE__{document: %{"field" => "payload_json", "pointer" => pointer}}),
    do: pointer in ~w(/format /version /codec /protocol)

  def discriminating?(_), do: false

  defp shape?(%{"op" => "byte", "offset" => offset, "value" => value} = map),
    do:
      map_size(map) == 3 and is_integer(offset) and offset >= 0 and offset < 65_536 and
        is_integer(value) and value in 0..255

  defp shape?(%{"op" => "length", "value" => value} = map),
    do: map_size(map) == 2 and is_integer(value) and value in 0..65_536

  defp shape?(%{"op" => op, "field" => field, "pointer" => pointer, "value" => _} = map),
    do: map_size(map) == 4 and op in ~w(eq member) and field in @fields and pointer?(pointer)

  defp shape?(_), do: false

  defp pointer?(""), do: true
  defp pointer?("/" <> rest), do: not Regex.match?(~r/~(?![01])/, rest)
  defp pointer?(_), do: false

  # Internal execution seam. Stable entry points admit the entire snapshot first.
  @doc false
  @spec evaluate_admitted(map(), Observation.t()) :: boolean()
  def evaluate_admitted(%{"op" => "byte", "offset" => offset, "value" => value}, %{
        payload: {:bytes, bytes}
      }),
      do: offset < byte_size(bytes) and :binary.at(bytes, offset) === value

  def evaluate_admitted(%{"op" => "length", "value" => value}, %{payload: {:bytes, bytes}}),
    do: byte_size(bytes) === value

  def evaluate_admitted(
        %{"op" => op, "field" => field, "pointer" => pointer, "value" => value},
        observation
      ) do
    case fetch(field, observation) do
      {:ok, json} -> compare(Wotex.JSON.resolve_pointer(json, pointer), op, value)
      :error -> false
    end
  end

  def evaluate_admitted(_, _), do: false

  defp fetch("payload_json", %{payload: {:json, json}}), do: {:ok, json}
  defp fetch("payload_json", _), do: :error
  defp fetch("ingress", observation), do: {:ok, observation.ingress}
  defp fetch("source", observation), do: {:ok, observation.source}
  defp fetch("addressing", observation), do: {:ok, observation.addressing}
  defp fetch("radio", observation), do: {:ok, observation.radio}
  defp fetch("transport", observation), do: {:ok, observation.transport}
  defp fetch("provenance", observation), do: {:ok, observation.provenance}

  defp compare({:ok, actual}, "eq", expected), do: actual === expected

  defp compare({:ok, values}, "member", expected) when is_list(values),
    do: Enum.any?(values, &(&1 === expected))

  defp compare(_, _, _), do: false
end
