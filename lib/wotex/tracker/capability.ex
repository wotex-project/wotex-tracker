defmodule Wotex.Tracker.Capability do
  @moduledoc """
  Evidence-backed affordance support, independent of current sample availability.
  The initial decoder slice implements readable Properties only. Events, writes
  and physical Actions require their own qualified evidence and adapters.
  """
  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits}

  @fields ~w(id kind operations unit evidence_ids)a
  @type t :: %__MODULE__{}
  @enforce_keys @fields
  defstruct @fields

  @doc "Admits readable support only when matching capability claims resolve in the bundle."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, bundle, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <- Admission.each([input.id, input.unit], &Admission.id(&1, limits)),
         true <- input.kind === :property and input.operations === [:read],
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
         "kind" => "property",
         "operations" => ["read"],
         "unit" => capability.unit,
         "evidence_ids" => capability.evidence_ids
       }}
    end
  end

  defp supported(id, input, bundle) do
    case Map.fetch(bundle.evidence, id) do
      {:ok, %{kind: :capability, claim: claim}} ->
        if claim["capability"] === input.id and claim["unit"] === input.unit and
             claim["interaction"] === "property" and claim["operations"] === ["read"],
           do: :ok,
           else: Admission.fail(:missing_capability)

      _ ->
        Admission.fail(:dangling_reference)
    end
  end
end
