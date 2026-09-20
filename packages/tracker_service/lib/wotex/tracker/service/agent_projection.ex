defmodule Wotex.Tracker.Service.AgentProjection do
  @moduledoc """
  Closed, provider-neutral projection of authorized Thing affordances.

  The projection contains only explicit read tools and action proposals. It
  never includes Forms, endpoints, credentials, observations or stored state.
  """

  alias Wotex.Tracker.Service.{Codec, Identifier}

  @request_schema "wtr.agent-projection-request.v1"
  @response_schema "wtr.agent-tools.v1"
  @maximum_tools 32
  @maximum_name_bytes 128
  @primitive_types ~w(boolean integer number string)
  @numeric_fields ~w(exclusiveMaximum exclusiveMinimum maximum minimum multipleOf type unit)
  @string_fields ~w(maxLength minLength pattern type)
  @boolean_fields ~w(type)
  @ignored_affordance_fields ~w(description descriptions forms observable readOnly title titles writeOnly)
  @unsupported_schema_fields ~w(allOf anyOf items oneOf properties)

  @doc false
  def admit(
        %{
          "schema" => @request_schema,
          "thing_id" => "urn:uuid:" <> uuid,
          "expected_generation" => generation,
          "read_properties" => properties,
          "propose_actions" => actions
        } = request
      )
      when map_size(request) == 5 do
    with true <- Identifier.operation?(uuid),
         {:ok, _} <- Codec.generation(generation),
         true <- names?(properties),
         true <- names?(actions),
         true <- length(properties) + length(actions) <= @maximum_tools do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admit(_), do: {:error, :invalid_request}

  @doc false
  def project(document, generation, request) do
    with :ok <- admit(request),
         true <- generation == request["expected_generation"],
         {:ok, td} <- thing_description(document),
         td <- Wotex.ThingDescription.to_map(td),
         true <- td["id"] == request["thing_id"],
         {:ok, properties} <-
           tools(td, generation, "property", "read", request["read_properties"]),
         {:ok, actions} <-
           tools(td, generation, "action", "proposal", request["propose_actions"]) do
      {:ok,
       %{
         "schema" => @response_schema,
         "thing" => %{"id" => td["id"], "generation" => generation},
         "tools" => Enum.sort_by(properties ++ actions, &{&1["kind"], &1["name"]})
       }}
    else
      false -> {:error, :revision_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  defp thing_description(document) when is_map(document) do
    case Wotex.ThingDescription.from_map(document) do
      {:ok, td} -> {:ok, td}
      _ -> {:error, :invalid_request}
    end
  end

  defp thing_description(_), do: {:error, :invalid_request}

  defp tools(td, generation, kind, mode, names) do
    key = if(kind == "property", do: "properties", else: "actions")
    affordances = Map.get(td, key, %{})

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, projected} ->
      case project_named_tool(affordances, td["id"], generation, kind, mode, name) do
        {:ok, value} -> {:cont, {:ok, [value | projected]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      error -> error
    end)
  end

  defp project_named_tool(affordances, thing, generation, kind, mode, name) do
    case Map.fetch(affordances, name) do
      {:ok, affordance} -> tool(thing, generation, kind, mode, name, affordance)
      :error -> {:error, :not_found}
    end
  end

  defp tool(thing, generation, "property" = kind, mode, name, affordance) do
    with true <- affordance["readOnly"] == true and affordance["writeOnly"] != true,
         true <- operation?(affordance, "readproperty"),
         {:ok, output} <- schema(affordance, @ignored_affordance_fields) do
      identity = identity(thing, generation, kind, name, mode)

      {:ok,
       Map.merge(identity, %{
         "id" => tool_id(identity),
         "mode" => mode,
         "output_schema" => output
       })}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp tool(thing, generation, "action" = kind, mode, name, affordance) do
    with true <- operation?(affordance, "invokeaction"),
         {:ok, input} <- optional_schema(affordance["input"]),
         {:ok, output} <- optional_schema(affordance["output"]) do
      identity = identity(thing, generation, kind, name, mode)

      {:ok,
       Map.merge(identity, %{
         "id" => tool_id(identity),
         "mode" => mode,
         "input_schema" => input,
         "output_schema" => output
       })}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp identity(thing, generation, kind, name, mode),
    do: %{
      "thing_id" => thing,
      "thing_generation" => generation,
      "kind" => kind,
      "name" => name,
      "operation" => mode
    }

  defp tool_id(identity), do: "wtrtool1_" <> Codec.digest(identity)

  defp operation?(%{"forms" => forms}, operation) when is_list(forms) do
    Enum.any?(forms, fn
      %{"op" => ^operation} -> true
      %{"op" => operations} when is_list(operations) -> operation in operations
      _ -> false
    end)
  end

  defp operation?(_, _), do: false

  defp optional_schema(nil), do: {:ok, nil}
  defp optional_schema(value), do: schema(value, [])

  defp schema(%{"type" => type} = value, ignored) when type in @primitive_types do
    fields = schema_fields(type)
    keys = Map.keys(value) -- ignored

    with true <- Enum.all?(keys, &(&1 in fields)),
         false <- Enum.any?(@unsupported_schema_fields, &Map.has_key?(value, &1)),
         projected <- Map.take(value, fields),
         true <- constraints?(projected, type) do
      {:ok, projected}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp schema(_, _), do: {:error, :unsupported}

  defp schema_fields(type) when type in ~w(integer number), do: @numeric_fields
  defp schema_fields("string"), do: @string_fields
  defp schema_fields("boolean"), do: @boolean_fields

  defp constraints?(schema, type) when type in ~w(integer number) do
    Enum.all?(Map.drop(schema, ~w(type unit)), fn {_, value} -> is_number(value) end) and
      valid_unit?(schema)
  end

  defp constraints?(schema, "string") do
    Enum.all?(Map.take(schema, ~w(minLength maxLength)), fn {_, value} ->
      is_integer(value) and value >= 0
    end) and
      (is_nil(schema["pattern"]) or bounded_string?(schema["pattern"]))
  end

  defp constraints?(schema, "boolean"), do: map_size(schema) == 1

  defp valid_unit?(schema), do: is_nil(schema["unit"]) or bounded_string?(schema["unit"])

  defp names?(names) when is_list(names) and length(names) <= @maximum_tools,
    do: Enum.all?(names, &bounded_name?/1) and length(Enum.uniq(names)) == length(names)

  defp names?(_), do: false

  defp bounded_name?(name),
    do:
      bounded_string?(name) and byte_size(name) <= @maximum_name_bytes and
        not String.contains?(name, ["\0", "\r", "\n"])

  defp bounded_string?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
