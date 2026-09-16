defmodule Wotex.Tracker.TransportCandidate do
  @moduledoc """
  An evidence-qualified route with separate bearer and application protocol.

  A candidate binds capability and current-connectivity facts to explicit cost,
  power and acknowledgement classes. It describes no socket, radio process or
  delivery result.
  """

  alias Wotex.Tracker.{Admission, Error, Limits, PolicyFact}

  @fields ~w(id bearer application_protocol capability connectivity cost_class power_class acknowledgement_layers)a
  @acknowledgement_layers ~w(radio network transport application durable_admission)a
  @type acknowledgement_layer ::
          :radio | :network | :transport | :application | :durable_admission
  @type t :: %__MODULE__{}
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @doc "Returns the closed acknowledgement-layer vocabulary in semantic, not strength, order."
  @spec acknowledgement_layers() :: [acknowledgement_layer()]
  def acknowledgement_layers, do: @acknowledgement_layers

  @doc "Returns the required capability predicate for a candidate ID."
  @spec capability_predicate(String.t()) :: String.t()
  def capability_predicate(id), do: "transport.#{id}.capable"

  @doc "Returns the required connectivity predicate for a candidate ID."
  @spec connectivity_predicate(String.t()) :: String.t()
  def connectivity_predicate(id), do: "transport.#{id}.available"

  @doc "Admits a closed route candidate and binds all facts and classes to its identity."
  @spec new(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def new(input, options \\ []) do
    with {:ok, limits} <- Limits.new(options),
         :ok <- Admission.fields(input, @fields),
         :ok <-
           Admission.each(
             [input.id, input.bearer, input.application_protocol],
             &Admission.id(&1, limits)
           ),
         {:ok, capability} <- PolicyFact.validate(input.capability, options),
         {:ok, connectivity} <- PolicyFact.validate(input.connectivity, options),
         :ok <- fact_scope(capability, connectivity, input.id),
         true <- class?(input.cost_class) and class?(input.power_class),
         :ok <- acknowledgement_layers(input.acknowledgement_layers),
         {:ok, identity} <-
           Admission.digest(candidate_map(input, capability, connectivity), Limits.json(limits)) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(input, %{
           capability: capability,
           connectivity: connectivity,
           identity: identity
         })
       )}
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  @doc "Rejects modified route metadata, evidence facts, classes or identity."
  @spec validate(term(), term()) :: {:ok, t()} | {:error, Error.t()}
  def validate(value, options \\ [])

  def validate(%__MODULE__{} = candidate, options) do
    with {:ok, admitted} <- new(Map.take(candidate, @fields), options) do
      if admitted === candidate, do: {:ok, admitted}, else: Admission.fail(:conflict)
    end
  end

  def validate(_, _), do: Admission.fail(:invalid_input)

  defp fact_scope(capability, connectivity, id) do
    if capability.predicate == capability_predicate(id) and
         capability.evidence.kind == :capability and
         connectivity.predicate == connectivity_predicate(id) and
         connectivity.evidence.kind == :transport,
       do: :ok,
       else: Admission.fail(:conflict)
  end

  defp acknowledgement_layers(values) do
    with :ok <- Admission.bounded_list(values, length(@acknowledgement_layers)),
         true <- Enum.all?(values, &(&1 in @acknowledgement_layers)),
         true <- Enum.uniq(values) == values do
      :ok
    else
      false -> Admission.fail(:invalid_input)
      error -> error
    end
  end

  defp class?(value), do: is_integer(value) and value in 0..100

  defp candidate_map(input, capability, connectivity),
    do: %{
      "schema" => "wtr.transport-candidate.v1",
      "id" => input.id,
      "bearer" => input.bearer,
      "application_protocol" => input.application_protocol,
      "capability_fact_identity" => capability.identity,
      "connectivity_fact_identity" => connectivity.identity,
      "cost_class" => input.cost_class,
      "power_class" => input.power_class,
      "acknowledgement_layers" => Enum.map(input.acknowledgement_layers, &Atom.to_string/1)
    }
end
