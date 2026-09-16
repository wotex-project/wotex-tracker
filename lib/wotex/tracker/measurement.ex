defmodule Wotex.Tracker.Measurement do
  @moduledoc """
  Represents one decoder measurement and its interpretation.

  `new/2` admits a numeric or boolean available value, or an unavailable value
  represented by `nil`. Kind, unit, quality, raw source value, and reason remain
  explicit. `to_map/2` and `from_map/2` carry the complete interpretation into
  evidence claims without treating missing data as zero or false.
  """

  alias Wotex.Tracker.{Admission, Error, Limits}

  @fields ~w(kind value unit availability quality raw reason)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields
  defstruct @fields

  @doc "Admits a native measurement, keeping unavailable separate from zero and false."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.kind, input.unit, input.reason], &Admission.id(&1, limits)),
         true <- availability?(input),
         :ok <- Admission.json(input.value, limits),
         :ok <- Admission.json(input.raw, limits) do
      {:ok, struct!(__MODULE__, input)}
    else
      false -> Admission.fail(:invalid_decoder_result)
      error -> error
    end
  end

  @doc "Revalidates a measurement struct."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])
  def validate(%__MODULE__{} = value, options), do: new(Map.from_struct(value), options)
  def validate(_, _), do: Admission.fail(:invalid_decoder_result)

  @doc "Projects all interpretation fields into an evidence claim."
  @spec to_map(term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, options \\ []) do
    with {:ok, measurement} <- validate(value, options) do
      {:ok,
       Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(measurement, &1)})
       |> Map.put("availability", Atom.to_string(measurement.availability))
       |> Map.put("quality", Atom.to_string(measurement.quality))}
    end
  end

  @doc "Admits the exact string-keyed evidence claim produced by `to_map/2`."
  @spec from_map(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map, options \\ []) do
    expected = Enum.map(@fields, &Atom.to_string/1)

    with true <-
           is_map(map) and map_size(map) == length(expected) and
             Enum.all?(expected, &Map.has_key?(map, &1)),
         {:ok, availability} <- availability(map["availability"]),
         {:ok, quality} <- quality(map["quality"]) do
      new(
        %{
          kind: map["kind"],
          value: map["value"],
          unit: map["unit"],
          availability: availability,
          quality: quality,
          raw: map["raw"],
          reason: map["reason"]
        },
        options
      )
    else
      false -> Admission.fail(:invalid_decoder_result)
      error -> error
    end
  end

  defp availability?(%{availability: :unavailable, quality: :unavailable, value: nil}), do: true

  defp availability?(%{availability: :available, quality: quality, value: value}),
    do: quality in [:valid, :suspect] and (is_number(value) or is_boolean(value))

  defp availability?(_), do: false

  defp availability("available"), do: {:ok, :available}
  defp availability("unavailable"), do: {:ok, :unavailable}
  defp availability(_), do: Admission.fail(:invalid_decoder_result)

  defp quality("valid"), do: {:ok, :valid}
  defp quality("suspect"), do: {:ok, :suspect}
  defp quality("unavailable"), do: {:ok, :unavailable}
  defp quality(_), do: Admission.fail(:invalid_decoder_result)
end
