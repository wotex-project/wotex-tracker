defmodule Wotex.Tracker.Measurement do
  @moduledoc "A decoder value with explicit unit, raw interpretation and independent availability/quality."
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

  defp availability?(%{availability: :unavailable, quality: :unavailable, value: nil}), do: true

  defp availability?(%{availability: :available, quality: quality, value: value}),
    do: quality in [:valid, :suspect] and not is_nil(value)

  defp availability?(_), do: false
end
