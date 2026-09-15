defmodule Wotex.Tracker.Service.Operation do
  @moduledoc false
  alias Wotex.Tracker.Service.{Codec, SQL}

  def digest(request, generation, observation_identity),
    do:
      Codec.digest(%{
        "request" => request,
        "expected_generation" => generation,
        "observation_identity" => observation_identity
      })

  def lookup(db, scope, principal, id, digest, now) do
    case SQL.rows!(
           db,
           "SELECT digest,result,expires_at FROM operations WHERE scope=? AND principal=? AND id=?",
           [scope, principal, id]
         ) do
      [[^digest, result, expires]] when now < expires -> {:ok, Codec.decode!(result)}
      [[^digest, _, _]] -> throw({:storage, :operation_expired})
      [[_, _, _]] -> throw({:storage, :idempotency_conflict})
      [] -> :new
    end
  end

  def valid_intent?(
        %{
          operation_id: id,
          request: request,
          expected_generation: generation,
          observation_identity: identity
        } = intent
      )
      when map_size(intent) == 4 do
    Codec.id?(id) and match?({:ok, _}, Codec.generation(generation)) and
      (is_nil(identity) or Codec.id?(identity)) and match?({:ok, _}, Codec.encode(request))
  end

  def valid_intent?(_), do: false
end
