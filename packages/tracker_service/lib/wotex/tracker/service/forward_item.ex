defmodule Wotex.Tracker.Service.ForwardItem do
  @moduledoc """
  A closed store-and-forward admission prepared by a trusted host adapter.

  The value keeps route metadata, required acknowledgement, source reliability
  and native JSON payload explicit. It does not claim transmission or delivery.
  """

  alias Wotex.Tracker.Service.Codec

  @fields ~w(scope id candidate_id bearer application_protocol payload source admitted_at required_acknowledgement)a
  @acknowledgement_layers ~w(radio network transport application durable_admission)a
  @acknowledgements [:none | @acknowledgement_layers]
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @doc "Returns the exact acknowledgement layers shared with the pure transport contract."
  @spec acknowledgement_layers() :: [atom()]
  def acknowledgement_layers, do: @acknowledgement_layers

  @doc "Admits one bounded queue item and derives its stable content identity."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_forward_item}
  def new(input) do
    with true <-
           is_map(input) and not is_struct(input) and
             Enum.sort(Map.keys(input)) == Enum.sort(@fields),
         true <-
           Enum.all?(
             [
               input.scope,
               input.id,
               input.candidate_id,
               input.bearer,
               input.application_protocol
             ],
             &Codec.id?/1
           ),
         {:ok, _} <- Codec.encode(input.payload, 262_144),
         true <- input.source in [:lossy, :reliable],
         true <- Codec.time?(input.admitted_at),
         true <- input.required_acknowledgement in @acknowledgements do
      document = document_map(input)
      identity = Codec.digest(document)
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      _ -> {:error, :invalid_forward_item}
    end
  end

  @doc "Re-admits a value and rejects changed fields or identity."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_forward_item | :forward_conflict}
  def validate(%__MODULE__{} = item) do
    with {:ok, admitted} <- new(Map.take(item, @fields)) do
      if admitted === item, do: {:ok, admitted}, else: {:error, :forward_conflict}
    end
  end

  def validate(_), do: {:error, :invalid_forward_item}

  @doc false
  @spec document(t()) :: map()
  def document(%__MODULE__{} = item), do: document_map(Map.take(item, @fields))

  defp document_map(input),
    do: %{
      "schema" => "wtr.forward-item.v1",
      "scope" => input.scope,
      "id" => input.id,
      "candidate_id" => input.candidate_id,
      "bearer" => input.bearer,
      "application_protocol" => input.application_protocol,
      "payload" => input.payload,
      "source" => Atom.to_string(input.source),
      "admitted_at" => input.admitted_at,
      "required_acknowledgement" => Atom.to_string(input.required_acknowledgement)
    }
end
