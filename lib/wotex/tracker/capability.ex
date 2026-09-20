defmodule Wotex.Tracker.Capability do
  @moduledoc """
  Evidence-backed affordance support, independent of current sample availability.

  Readable Properties carry their declared unit. Invokable Actions carry no
  unit and require a distinct trusted-decoder capability claim. Admitting an
  Action here proves only that the selected profile declares the affordance; it
  does not execute it or establish a physical effect.
  """

  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits}

  @fields ~w(id kind operations unit evidence_ids)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields
  defstruct @fields

  @doc "Admits closed Property-read or Action-invoke support from matching evidence."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, bundle, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.id(input.id, limits),
         true <- interaction?(input, limits),
         :ok <- Admission.ids(input.evidence_ids, limits, limits.max_sources),
         true <- input.evidence_ids != [],
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         :ok <- Admission.each(input.evidence_ids, &supported(&1, input, bundle)) do
      {:ok, struct!(__MODULE__, input)}
    else
      false -> Admission.fail(:unsupported)
      error -> error
    end
  end

  @doc "Revalidates a capability against the explicit evidence snapshot."
  @spec validate(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, bundle, options \\ [])

  def validate(%__MODULE__{} = value, bundle, options),
    do: new(Map.from_struct(value), bundle, options)

  def validate(_, _, _), do: Admission.fail(:invalid_input)

  @doc "Projects a capability and its evidence references after revalidation."
  @spec to_map(term(), term(), term()) :: {:ok, map()} | {:error, Error.t()}
  def to_map(value, bundle, options \\ []) do
    with {:ok, capability} <- validate(value, bundle, options) do
      {:ok,
       %{
         "id" => capability.id,
         "kind" => Atom.to_string(capability.kind),
         "operations" => Enum.map(capability.operations, &Atom.to_string/1),
         "unit" => capability.unit,
         "evidence_ids" => capability.evidence_ids
       }}
    end
  end

  defp supported(id, input, bundle) do
    case Map.fetch(bundle.evidence, id) do
      {:ok, %{kind: :capability, claim: claim}} ->
        if claim["capability"] === input.id and claim["unit"] === input.unit and
             claim["interaction"] === Atom.to_string(input.kind) and
             claim["operations"] === Enum.map(input.operations, &Atom.to_string/1),
           do: :ok,
           else: Admission.fail(:missing_capability)

      _ ->
        Admission.fail(:dangling_reference)
    end
  end

  defp interaction?(%{kind: :property, operations: [:read], unit: unit}, limits),
    do: match?(:ok, Admission.id(unit, limits))

  defp interaction?(%{kind: :action, operations: [:invoke], unit: nil}, _limits), do: true
  defp interaction?(_, _), do: false
end
