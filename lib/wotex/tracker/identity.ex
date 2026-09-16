defmodule Wotex.Tracker.Identity do
  @moduledoc """
  Explicit caller-issued pseudonym and association evidence. The first strategy
  admits a UUIDv4 URN, never a MAC/IMEI-derived public ID. It creates no persistent
  enrollment and confers no authorization. The host owns uniqueness and custody.
  """

  alias Wotex.Tracker.{Admission, Error, EvidenceBundle, Limits}

  @type t :: %__MODULE__{}
  @enforce_keys [:thing_id, :association_id, :revision, :evidence_id, :bundle_identity]
  defstruct @enforce_keys
  @uuid ~r/\Aurn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  @doc "Associates a caller-issued pseudonym with an explicit identity claim in a bundle."
  @spec new(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, bundle, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, ~w(thing_id association_id revision evidence_id)a),
         :ok <- Admission.each(Map.values(input), &Admission.id(&1, limits)),
         true <- Regex.match?(@uuid, input.thing_id),
         {:ok, bundle} <- EvidenceBundle.validate(bundle, options),
         :ok <- association(input, bundle) do
      {:ok, struct!(__MODULE__, Map.put(input, :bundle_identity, bundle.identity))}
    else
      false -> Admission.fail(:invalid_id)
      error -> error
    end
  end

  @doc "Revalidates the exact association against the supplied immutable bundle."
  @spec validate(term(), term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(identity, bundle, options \\ [])

  def validate(%__MODULE__{} = identity, bundle, options) do
    with {:ok, admitted} <-
           new(identity |> Map.from_struct() |> Map.delete(:bundle_identity), bundle, options),
         true <- admitted === identity do
      {:ok, admitted}
    else
      false -> Admission.fail(:conflict)
      error -> error
    end
  end

  def validate(_, _, _), do: Admission.fail(:invalid_input)

  defp association(input, bundle) do
    case Map.fetch(bundle.evidence, input.evidence_id) do
      {:ok,
       %{
         kind: :identity,
         association_id: association,
         claim: claim,
         source_observation_ids: sources
       }} ->
        if Enum.sort(sources) === Enum.sort(Map.keys(bundle.observations)) and
             association === input.association_id and claim["thing_id"] === input.thing_id and
             claim["strategy"] === "operator-pseudonym-v1" and
             claim["revision"] === input.revision,
           do: :ok,
           else: Admission.fail(:association_mismatch)

      _ ->
        Admission.fail(:dangling_reference)
    end
  end
end
