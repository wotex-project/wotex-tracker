defmodule Wotex.Tracker.UI.ActionForm do
  @moduledoc """
  Projects declared Thing Actions into bounded presentation data.

  Forms and device endpoints never leave this boundary. Only primitive inputs
  accepted by the service are editable, and durable status documents are
  admitted against the exact operation, Thing and Action being inspected.
  """

  alias Wotex.Tracker.Service.{Codec, Identifier, PrimitiveSchema}

  @maximum_actions 64
  @maximum_text_bytes 512
  @statuses ~w(queued unknown accepted denied failed)
  @classifications ~w(
    dispatch_started
    authorization_or_revision_changed
    protocol_ok
    protocol_accepted
    runtime_construction
    runtime_selection
    runtime_credentials
    transport_unknown
    dispatch_unknown
  )
  @status_fields ~w(schema operation_id thing action status admitted_at claimed_at settled_at outcome physical_effect)

  @doc "Projects a Thing's Actions without their private execution Forms."
  @spec actions(map()) :: {:ok, [map()]} | {:error, :invalid_actions}
  def actions(%{"actions" => actions})
      when is_map(actions) and not is_struct(actions) and
             map_size(actions) <= @maximum_actions do
    actions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {name, action}, {:ok, projected} ->
      case project(name, action) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        _ -> {:halt, {:error, :invalid_actions}}
      end
    end)
    |> reverse()
  end

  def actions(thing)
      when is_map(thing) and not is_struct(thing) and not is_map_key(thing, "actions"),
      do: {:ok, []}

  def actions(_), do: {:error, :invalid_actions}

  @doc "Decodes one browser scalar and reuses the service's exact input predicate."
  @spec decode_input(map() | nil, String.t() | nil) :: {:ok, term()} | {:error, :invalid_input}
  def decode_input(nil, nil), do: {:ok, nil}

  def decode_input(%{"type" => type} = schema, value) when is_binary(value) do
    with true <- byte_size(value) <= 16_000,
         {:ok, decoded} <- decode(type, value),
         true <- PrimitiveSchema.accepts?(schema, decoded),
         {:ok, _} <- Codec.encode(decoded, 16_384) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_input}
    end
  end

  def decode_input(_, _), do: {:error, :invalid_input}

  @doc "Checks a public Action status against the page's closed recovery identity."
  @spec status?(term(), String.t(), String.t(), String.t()) :: boolean()
  def status?(value, operation, thing, action) do
    status_shape?(value) and identity?(value, operation, thing, action) and
      timing?(value) and status_outcome?(value)
  end

  defp identity?(value, operation, thing, action),
    do:
      value["schema"] == "wtr.action-status.v1" and value["operation_id"] == operation and
        Identifier.operation?(operation) and value["thing"]["id"] == thing and
        Codec.id?(thing) and generation?(value["thing"]["generation"]) and
        value["action"] == action and name?(action)

  defp timing?(value),
    do:
      timestamp?(value["admitted_at"]) and optional_timestamp?(value["claimed_at"]) and
        optional_timestamp?(value["settled_at"])

  defp status_outcome?(value),
    do:
      value["status"] in @statuses and outcome?(value["outcome"]) and
        physical_effect?(value["status"], value["physical_effect"])

  defp project(name, action) do
    with true <- name?(name) and is_map(action) and not is_struct(action),
         true <- invocation_form?(action["forms"]),
         :ok <- optional_text(action["title"]),
         :ok <- optional_text(action["description"]),
         {:ok, schema} <- schema(action["input"]) do
      {:ok,
       %{
         "name" => name,
         "title" => action["title"] || name,
         "description" => action["description"],
         "input" => schema,
         "supported" => supported?(schema)
       }}
    else
      _ -> {:error, :invalid_action}
    end
  end

  defp schema(nil), do: {:ok, nil}

  defp schema(value) do
    with {:ok, projected} <- PrimitiveSchema.project(value),
         true <- bounded_schema?(projected) do
      {:ok, projected}
    else
      _ -> {:error, :invalid_schema}
    end
  end

  defp bounded_schema?(schema) do
    unit = schema["unit"]

    (is_nil(unit) or bounded_text?(unit)) and
      Enum.all?(Map.take(schema, ~w(minLength maxLength)), fn {_, value} ->
        is_integer(value) and value in 0..16_000
      end)
  end

  defp supported?(nil), do: true

  defp supported?(schema),
    do: not Map.has_key?(schema, "pattern") and not Map.has_key?(schema, "multipleOf")

  defp invocation_form?(forms) when is_list(forms) and forms != [] do
    Enum.any?(forms, fn
      %{"op" => "invokeaction"} -> true
      %{"op" => operations} when is_list(operations) -> "invokeaction" in operations
      _ -> false
    end)
  end

  defp invocation_form?(_), do: false

  defp decode("boolean", "true"), do: {:ok, true}
  defp decode("boolean", "false"), do: {:ok, false}

  defp decode("integer", value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp decode("number", value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> decode_float(value)
    end
  end

  defp decode("string", value), do: {:ok, value}
  defp decode(_, _), do: :error

  defp decode_float(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  defp status_shape?(value),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(@status_fields) and
        is_map(value["thing"]) and not is_struct(value["thing"]) and
        Enum.sort(Map.keys(value["thing"])) == ~w(generation id)

  defp outcome?(nil), do: true

  defp outcome?(%{"classification" => classification} = outcome)
       when classification in @classifications do
    Enum.sort(Map.keys(outcome)) in [~w(classification), ~w(classification completed_at)] and
      (not Map.has_key?(outcome, "completed_at") or timestamp?(outcome["completed_at"]))
  end

  defp outcome?(_), do: false

  defp physical_effect?(status, "not_dispatched") when status in ~w(queued denied failed),
    do: true

  defp physical_effect?(status, "unknown") when status in ~w(unknown accepted), do: true
  defp physical_effect?(_, _), do: false

  defp optional_text(nil), do: :ok
  defp optional_text(value), do: if(bounded_text?(value), do: :ok, else: :error)

  defp bounded_text?(value),
    do:
      is_binary(value) and value != "" and byte_size(value) <= @maximum_text_bytes and
        String.valid?(value)

  defp name?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and String.valid?(value) and
        not String.contains?(value, ["\0", "\r", "\n"])

  defp generation?(value), do: match?({:ok, _}, Codec.generation(value))
  defp timestamp?(value), do: is_integer(value) and value in 0..9_007_199_254_740_991
  defp optional_timestamp?(nil), do: true
  defp optional_timestamp?(value), do: timestamp?(value)
  defp reverse({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse(error), do: error
end
