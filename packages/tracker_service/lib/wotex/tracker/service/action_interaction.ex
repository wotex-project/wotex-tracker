defmodule Wotex.Tracker.Service.ActionInteraction do
  @moduledoc false

  alias Wotex.Tracker.Service.{
    ActionIntent,
    Codec,
    Identifier,
    PrimitiveSchema,
    Snapshot,
    Store
  }

  def admit(%{"expected_generation" => generation, "input" => input} = request)
      when map_size(request) == 2 do
    with {:ok, _} <- Codec.generation(generation),
         {:ok, _} <- Codec.encode(input, 16_384) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admit(_), do: {:error, :invalid_request}

  def prepare(service, access, operation, thing, name, request, now) do
    with true <- Identifier.operation?(operation) and Codec.id?(thing) and name?(name),
         :ok <- admit(request),
         {:ok, row} <-
           Snapshot.fetch(
             service,
             access,
             "things",
             thing,
             nil,
             "interact",
             now
           ),
         true <- row["generation"] == request["expected_generation"],
         td when is_map(td) <- row["value"]["public"],
         {:ok, action} <- action(td, name),
         :ok <- input(action, request["input"]),
         {:ok, intent} <-
           ActionIntent.new(%{
             scope: access.scope,
             id: operation,
             thing_id: thing,
             thing_generation: row["generation"],
             thing_identity: Codec.digest(td),
             name: name,
             input: request["input"],
             admitted_at: now,
             access: access
           }) do
      Store.admit_action(service.store, intent)
    else
      false -> {:error, :revision_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp action(td, name) do
    with {:ok, _} <- Wotex.ThingDescription.from_map(td),
         %{} = action <- get_in(td, ["actions", name]),
         true <- operation?(action, "invokeaction") do
      {:ok, action}
    else
      nil -> {:error, :not_found}
      _ -> {:error, :unsupported}
    end
  end

  defp operation?(%{"forms" => forms}, operation) when is_list(forms) do
    Enum.any?(forms, fn
      %{"op" => ^operation} -> true
      %{"op" => [^operation]} -> true
      _ -> false
    end)
  end

  defp operation?(_, _), do: false

  defp input(action, value) do
    if PrimitiveSchema.accepts?(action["input"], value),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp name?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"])
end
