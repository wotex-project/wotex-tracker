defmodule Wotex.Tracker.Service.ActionIntent do
  @moduledoc """
  One authorized, durable request for a single WoT Action invocation.

  The retained access proof is private host state used for dispatch-time
  reauthorization. The intent does not claim transport acceptance or a physical
  effect, and its operation identity is never eligible for automatic retry.
  """

  alias Wotex.Tracker.Service.{Access, Authority, Codec, Identifier}

  @fields ~w(scope id thing_id thing_generation thing_identity name input admitted_at access)a
  @enforce_keys @fields ++ [:identity]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          scope: String.t(),
          id: String.t(),
          thing_id: String.t(),
          thing_generation: String.t(),
          thing_identity: String.t(),
          name: String.t(),
          input: Wotex.JSON.json_value(),
          admitted_at: non_neg_integer(),
          access: Access.t(),
          identity: String.t()
        }

  @doc "Admits one bounded Action intent and derives its stable content identity."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_action_intent}
  def new(input) do
    with true <-
           is_map(input) and not is_struct(input) and
             Enum.sort(Map.keys(input)) == Enum.sort(@fields),
         true <- Codec.id?(input.scope) and Identifier.operation?(input.id),
         true <- Codec.id?(input.thing_id) and name?(input.name),
         {:ok, _} <- Codec.generation(input.thing_generation),
         true <- digest?(input.thing_identity),
         {:ok, _} <- Codec.encode(input.input, 16_384),
         true <- Codec.time?(input.admitted_at) and Authority.valid?(input.access),
         true <- input.access.scope == input.scope do
      identity = input |> public_document() |> Codec.digest()
      {:ok, struct!(__MODULE__, Map.put(input, :identity, identity))}
    else
      _ -> {:error, :invalid_action_intent}
    end
  end

  @doc "Re-admits a value and rejects forged fields or content identity."
  @spec validate(term()) :: {:ok, t()} | {:error, atom()}
  def validate(%__MODULE__{} = intent) do
    with {:ok, admitted} <- new(Map.take(intent, @fields)) do
      if admitted === intent, do: {:ok, admitted}, else: {:error, :action_conflict}
    end
  end

  def validate(_), do: {:error, :invalid_action_intent}

  @doc false
  def document(%__MODULE__{} = intent) do
    intent
    |> public_document()
    |> Map.put("authority", Authority.projection(intent.access))
  end

  @doc false
  def restore(
        %{
          "schema" => "wtr.action-intent.v1",
          "scope" => scope,
          "operation_id" => id,
          "thing" => %{"id" => thing, "generation" => generation, "identity" => identity},
          "action" => name,
          "input" => input,
          "admitted_at" => admitted_at,
          "authority" => authority
        } = document
      )
      when map_size(document) == 8 do
    with {:ok, access} <- Authority.restore(authority),
         do:
           new(%{
             scope: scope,
             id: id,
             thing_id: thing,
             thing_generation: generation,
             thing_identity: identity,
             name: name,
             input: input,
             admitted_at: admitted_at,
             access: access
           })
  end

  def restore(_), do: {:error, :invalid_action_intent}

  defp public_document(intent),
    do: %{
      "schema" => "wtr.action-intent.v1",
      "scope" => intent.scope,
      "operation_id" => intent.id,
      "thing" => %{
        "id" => intent.thing_id,
        "generation" => intent.thing_generation,
        "identity" => intent.thing_identity
      },
      "action" => intent.name,
      "input" => intent.input,
      "admitted_at" => intent.admitted_at
    }

  defp name?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"])

  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _}, Base.decode16(value, case: :lower))

  defp digest?(_), do: false
end
