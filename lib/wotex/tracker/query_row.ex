defmodule Wotex.Tracker.QueryRow do
  @moduledoc """
  Admits one numeric history row for deterministic analytics.

  A row names its measurement, series, event time, unit, quality, availability,
  and source evidence. `new/2` binds those fields to a content identity;
  `validate/2` detects changes, and `to_map/2` and `from_map/2` use a closed
  versioned JSON shape. Unavailable values remain distinct from numeric zero.
  """

  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(measurement series event_at value unit availability quality evidence_identity)a
  @serialized_fields ~w(schema measurement series event_at value unit availability quality evidence_identity identity)
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Admits one qualified numeric or explicitly unavailable measurement row."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <-
           Admission.each(
             [input.measurement, input.series, input.unit, input.evidence_identity],
             &Admission.id(&1, limits)
           ),
         true <- is_integer(input.event_at) and input.event_at in 0..9_007_199_254_740_991,
         true <- input.quality in [:valid, :suspect, :invalid],
         true <- value_matches?(input.availability, input.value),
         {:ok, identity} <- Admission.digest(row_map(input), Limits.json(limits)) do
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Revalidates the row and rejects changed qualification or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = value, options) do
    with {:ok, admitted} <- new(Map.take(value, @fields), options) do
      if admitted === value, do: {:ok, value}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  @doc "Projects one qualified row to closed native JSON."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, row} <- validate(value, options),
         do: {:ok, Map.put(row_map(row), "identity", row.identity)}
  end

  @doc "Restores and revalidates one qualified row from closed native JSON."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(document, options \\ []) do
    with true <- exact_fields?(document, @serialized_fields),
         true <- document["schema"] == "wtr.query-row.v1",
         {:ok, availability} <- availability_atom(document["availability"]),
         {:ok, quality} <- quality_atom(document["quality"]),
         {:ok, row} <-
           new(
             %{
               measurement: document["measurement"],
               series: document["series"],
               event_at: document["event_at"],
               value: document["value"],
               unit: document["unit"],
               availability: availability,
               quality: quality,
               evidence_identity: document["evidence_identity"]
             },
             options
           ),
         true <- row.identity == document["identity"] do
      {:ok, row}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  defp value_matches?(:available, value), do: finite_number?(value)
  defp value_matches?(:unavailable, nil), do: true
  defp value_matches?(_, _), do: false

  defp finite_number?(value) when is_integer(value), do: true
  defp finite_number?(value) when is_float(value), do: value > -1.0e308 and value < 1.0e308
  defp finite_number?(_), do: false

  defp row_map(input),
    do: %{
      "schema" => "wtr.query-row.v1",
      "measurement" => input.measurement,
      "series" => input.series,
      "event_at" => input.event_at,
      "value" => input.value,
      "unit" => input.unit,
      "availability" => Atom.to_string(input.availability),
      "quality" => Atom.to_string(input.quality),
      "evidence_identity" => input.evidence_identity
    }

  defp availability_atom("available"), do: {:ok, :available}
  defp availability_atom("unavailable"), do: {:ok, :unavailable}
  defp availability_atom(_), do: Admission.fail(:invalid_input)

  defp quality_atom("valid"), do: {:ok, :valid}
  defp quality_atom("suspect"), do: {:ok, :suspect}
  defp quality_atom("invalid"), do: {:ok, :invalid}
  defp quality_atom(_), do: Admission.fail(:invalid_input)

  defp exact_fields?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
