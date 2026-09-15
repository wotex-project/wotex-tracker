defmodule Wotex.Tracker.Service.Interaction do
  @moduledoc false
  alias Wotex.Runtime.{Context, ExposedThing}
  alias Wotex.ThingDescription
  alias Wotex.Tracker.Service.{Codec, Snapshot}

  def read(service, access, thing, name, context, now) do
    with {:ok, sample} <-
           execute(service, access, thing, name, {:readproperty, nil}, context, now),
         do: {:ok, Map.take(sample, ["value", "generation"])}
  end

  def observe(service, access, thing, name, generation, context, now),
    do: execute(service, access, thing, name, {:observeproperty, generation}, context, now)

  defp execute(service, access, thing, name, {operation, generation}, context, now) do
    with true <- Codec.id?(thing) and Codec.id?(name),
         :ok <- deadline(context),
         {:ok, row} <- Snapshot.fetch(service, access, "things", thing, generation, "read", now),
         {:ok, state} <-
           Snapshot.fetch(service, access, "state", thing, row["generation"], "read", now),
         {:ok, td} <- ThingDescription.from_map(row["value"]["public"]),
         :ok <- supported(td, name, operation),
         {:ok, exposed} <- ExposedThing.new(td, handlers(td, state["value"]["public"])),
         {:ok, value} <- ExposedThing.dispatch(exposed, operation, name, nil, context) do
      {:ok,
       %{
         "value" => value,
         "generation" => row["generation"],
         "event_cursor" => row["event_cursor"]
       }}
    else
      false -> {:error, :invalid_request}
      {:error, %Wotex.Runtime.Error{code: :affordance_not_found}} -> {:error, :not_found}
      {:error, %Wotex.Runtime.Error{}} -> {:error, :unsupported}
      {:error, %Wotex.Error{}} -> {:error, :storage_unavailable}
      {:error, errors} when is_list(errors) -> {:error, :storage_unavailable}
      error -> error
    end
  end

  defp supported(td, name, :observeproperty) do
    case ThingDescription.to_map(td)["properties"][name] do
      nil -> {:error, :not_found}
      %{"observable" => true} -> :ok
      _ -> {:error, :unsupported}
    end
  end

  defp supported(_, _, :readproperty), do: :ok

  defp handlers(td, state) do
    td
    |> ThingDescription.to_map()
    |> Map.fetch!("properties")
    |> Enum.flat_map(fn {name, property} ->
      operations =
        if property["observable"] == true,
          do: [:readproperty, :observeproperty],
          else: [:readproperty]

      Enum.map(operations, fn operation ->
        {{operation, name},
         fn _, context ->
           with :ok <- deadline(context), do: sample(state, name, property)
         end}
      end)
    end)
    |> Map.new()
  end

  defp sample(state, name, property) do
    measurement = Enum.find(state["measurements"], &(&1["kind"] == name))

    if measurement && measurement["availability"] == "available" &&
         measurement["unit"] == property["unit"] && property["readOnly"] == true,
       do: scalar(measurement["value"], property["type"]),
       else: {:error, :unavailable}
  end

  # This host supports the packaged scalar model. It does not claim general
  # JSON Schema instance validation or silently round a wide protocol integer.
  defp scalar(%{"type" => "number", "value" => value}, "number") when is_float(value),
    do: {:ok, value}

  defp scalar(%{"type" => "integer", "value" => value}, type)
       when is_integer(value) and type in ["integer", "number"],
       do: {:ok, value}

  defp scalar(%{"type" => "boolean", "value" => value}, "boolean") when is_boolean(value),
    do: {:ok, value}

  defp scalar(_, _), do: {:error, :unavailable}

  defp deadline(%Context{} = context) do
    deadline = Context.deadline(context)

    clock =
      if match?(%DateTime{}, deadline),
        do: DateTime.utc_now(),
        else: System.monotonic_time(:millisecond)

    case Context.remaining_ms(deadline, clock) do
      remaining when remaining == :infinity or (is_integer(remaining) and remaining > 0) -> :ok
      _ -> {:error, :deadline_exceeded}
    end
  end

  defp deadline(_), do: {:error, :invalid_request}
end
