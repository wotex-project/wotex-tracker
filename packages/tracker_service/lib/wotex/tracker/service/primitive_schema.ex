defmodule Wotex.Tracker.Service.PrimitiveSchema do
  @moduledoc false

  @primitive_types ~w(boolean integer number string)
  @numeric_fields ~w(exclusiveMaximum exclusiveMinimum maximum minimum multipleOf type unit)
  @string_fields ~w(maxLength minLength pattern type)
  @boolean_fields ~w(type)
  @unsupported_fields ~w(allOf anyOf items oneOf properties)

  def project(nil), do: {:ok, nil}

  def project(%{"type" => type} = value) when type in @primitive_types do
    fields = fields(type)

    with true <- Enum.all?(Map.keys(value), &(&1 in fields)),
         false <- Enum.any?(@unsupported_fields, &Map.has_key?(value, &1)),
         projected <- Map.take(value, fields),
         true <- constraints?(projected, type) do
      {:ok, projected}
    else
      _ -> {:error, :unsupported}
    end
  end

  def project(_), do: {:error, :unsupported}

  def accepts?(nil, nil), do: true
  def accepts?(nil, _), do: false

  def accepts?(schema, value) do
    with {:ok, projected} <- project(schema),
         false <- Map.has_key?(projected, "pattern"),
         false <- Map.has_key?(projected, "multipleOf") do
      value?(projected, value)
    else
      _ -> false
    end
  end

  defp fields(type) when type in ~w(integer number), do: @numeric_fields
  defp fields("string"), do: @string_fields
  defp fields("boolean"), do: @boolean_fields

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

  defp value?(%{"type" => "boolean"}, value), do: is_boolean(value)

  defp value?(%{"type" => "integer"} = schema, value) when is_integer(value),
    do: numeric?(schema, value)

  defp value?(%{"type" => "number"} = schema, value) when is_number(value),
    do: numeric?(schema, value)

  defp value?(%{"type" => "string"} = schema, value) when is_binary(value) do
    if String.valid?(value) do
      length = value |> String.codepoints() |> length()
      lower?(length, schema["minLength"]) and upper?(length, schema["maxLength"])
    else
      false
    end
  end

  defp value?(_, _), do: false

  defp numeric?(schema, value),
    do:
      lower?(value, schema["minimum"]) and upper?(value, schema["maximum"]) and
        exclusive_lower?(value, schema["exclusiveMinimum"]) and
        exclusive_upper?(value, schema["exclusiveMaximum"])

  defp lower?(_, nil), do: true
  defp lower?(value, minimum), do: value >= minimum
  defp upper?(_, nil), do: true
  defp upper?(value, maximum), do: value <= maximum
  defp exclusive_lower?(_, nil), do: true
  defp exclusive_lower?(value, minimum), do: value > minimum
  defp exclusive_upper?(_, nil), do: true
  defp exclusive_upper?(value, maximum), do: value < maximum

  defp valid_unit?(schema), do: is_nil(schema["unit"]) or bounded_string?(schema["unit"])
  defp bounded_string?(value), do: is_binary(value) and value != "" and String.valid?(value)
end
