defmodule Wotex.Tracker.OpenAPIAudit do
  @moduledoc false

  alias Wotex.Tracker.Service.Codec

  @target Path.expand("../packages/tracker_service/priv/openapi/v1.json", __DIR__)
  @methods ~w(get post put patch delete options head trace)
  @schema_types ~w(null boolean object array number integer string)

  def main(arguments) when arguments in [[], ["--check"]] do
    document = @target |> File.read!() |> Codec.decode!()
    validate_document!(document)
    IO.puts("OpenAPI 3.1.0 contract validated")
  end

  def main(_arguments), do: raise("usage: openapi.exs [--check]")

  defp validate_document!(
         %{
           "openapi" => "3.1.0",
           "info" => %{
             "title" => title,
             "version" => version,
             "description" => description
           },
           "jsonSchemaDialect" => "https://json-schema.org/draft/2020-12/schema",
           "security" => [%{"bearer" => []}],
           "paths" => paths,
           "components" => %{
             "securitySchemes" => %{
               "bearer" => %{"type" => "http", "scheme" => "bearer"}
             },
             "parameters" => parameters,
             "schemas" => schemas
           }
         } = document
       ) do
    unless map_size(document) == 6, do: fail("unexpected top-level OpenAPI members")
    validate_text!(title, "info.title")
    validate_text!(version, "info.version")
    validate_text!(description, "info.description")
    validate_nonempty_map!(paths, "paths")
    validate_nonempty_map!(parameters, "components.parameters")
    validate_nonempty_map!(schemas, "components.schemas")

    unless Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+\z/, version),
      do: fail("info.version must be semantic")

    operations = validate_paths!(paths)
    validate_unique_operations!(operations)
    validate_parameters!(parameters)
    Enum.each(schemas, fn {name, schema} -> validate_schema!(schema, "schema #{name}") end)
    validate_refs!(document)
  end

  defp validate_document!(_document), do: fail("invalid top-level OpenAPI document")

  defp validate_text!(value, _location) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp validate_text!(_value, location), do: fail("invalid #{location}")

  defp validate_nonempty_map!(value, _location) when is_map(value) and map_size(value) > 0,
    do: :ok

  defp validate_nonempty_map!(_value, location), do: fail("invalid #{location}")

  defp validate_paths!(paths) do
    Enum.flat_map(paths, fn entry -> validate_path!(entry) end)
  end

  defp validate_path!({path, item})
       when is_binary(path) and is_map(item) and map_size(item) > 0 do
    unless String.starts_with?(path, "/"), do: fail("invalid path item")
    Enum.map(item, fn operation -> validate_path_operation!(operation, path) end)
  end

  defp validate_path!(_entry), do: fail("invalid path item")

  defp validate_path_operation!({method, operation}, path) when method in @methods,
    do: validate_operation!(operation, method <> " " <> path)

  defp validate_path_operation!({method, _operation}, _path),
    do: fail("unsupported operation method #{inspect(method)}")

  defp validate_operation!(
         %{"operationId" => operation_id, "parameters" => parameters, "responses" => responses} =
           operation,
         location
       )
       when is_binary(operation_id) and is_list(parameters) and is_map(responses) do
    unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, operation_id),
      do: fail("invalid operationId at #{location}")

    unless Map.has_key?(responses, "default") and
             Enum.any?(Map.keys(responses), &Regex.match?(~r/\A[1-5][0-9][0-9]\z/, &1)),
           do: fail("responses must include a status and default at #{location}")

    Enum.each(parameters, &validate_parameter_reference!(&1, location))

    Enum.each(responses, fn {status, response} ->
      validate_response!(response, status, location)
    end)

    case operation do
      %{"requestBody" => body} -> validate_request_body!(body, location)
      _ -> :ok
    end

    operation_id
  end

  defp validate_operation!(_operation, location), do: fail("invalid operation at #{location}")

  defp validate_parameter_reference!(%{"$ref" => "#/components/parameters/" <> name}, _location)
       when byte_size(name) > 0,
       do: :ok

  defp validate_parameter_reference!(_parameter, location),
    do: fail("operation parameter must use a component reference at #{location}")

  defp validate_response!(
         %{"description" => description, "content" => content},
         status,
         location
       )
       when is_binary(description) and byte_size(description) > 0 and is_map(content) and
              map_size(content) > 0 do
    Enum.each(content, fn {media, value} ->
      unless is_binary(media) and byte_size(media) > 0 and match?(%{"schema" => _}, value),
        do: fail("invalid response #{status} at #{location}")

      validate_schema!(value["schema"], "response #{status} at #{location}")
    end)
  end

  defp validate_response!(_response, status, location),
    do: fail("invalid response #{status} at #{location}")

  defp validate_request_body!(
         %{
           "required" => true,
           "content" => %{"application/json" => %{"schema" => schema}}
         },
         location
       ),
       do: validate_schema!(schema, "request at #{location}")

  defp validate_request_body!(_body, location), do: fail("invalid request body at #{location}")

  defp validate_unique_operations!(operations) do
    if length(operations) != MapSet.size(MapSet.new(operations)),
      do: fail("operationId values must be unique")
  end

  defp validate_parameters!(parameters) do
    Enum.each(parameters, fn parameter -> validate_parameter!(parameter) end)
  end

  defp validate_parameter!(
         {name, %{"name" => wire_name, "in" => place, "schema" => schema} = parameter}
       )
       when is_binary(wire_name) and byte_size(wire_name) > 0 and
              place in ["path", "query", "header"] do
    if place == "path" and parameter["required"] != true,
      do: fail("path parameter #{name} must be required")

    validate_schema!(schema, "parameter #{name}")
  end

  defp validate_parameter!({name, _parameter}),
    do: fail("invalid component parameter #{name}")

  defp validate_schema!(schema, _location) when is_boolean(schema), do: :ok

  defp validate_schema!(schema, location) when is_map(schema) do
    validate_type!(schema["type"], location)
    validate_required!(schema, location)
    validate_bounds!(schema, location)
    validate_pattern!(schema["pattern"], location)
    validate_variants!(schema, location)
    validate_items!(schema["items"], location)
    validate_additional_properties!(schema["additionalProperties"], location)
    validate_properties!(schema["properties"], location)
  end

  defp validate_schema!(_schema, location), do: fail("invalid schema at #{location}")

  defp validate_pattern!(nil, _location), do: :ok

  defp validate_pattern!(pattern, _location) when is_binary(pattern) do
    _compiled = Regex.compile!(pattern)
    :ok
  end

  defp validate_pattern!(_pattern, location), do: fail("invalid pattern at #{location}")

  defp validate_variants!(schema, location) do
    for key <- ["oneOf", "anyOf", "allOf"], variants = schema[key], not is_nil(variants) do
      validate_variant_list!(variants, key, location)
    end
  end

  defp validate_variant_list!(variants, key, location)
       when is_list(variants) and variants != [],
       do: Enum.each(variants, &validate_schema!(&1, location <> " " <> key))

  defp validate_variant_list!(_variants, key, location),
    do: fail("invalid #{key} at #{location}")

  defp validate_items!(nil, _location), do: :ok
  defp validate_items!(items, location), do: validate_schema!(items, location <> " items")

  defp validate_additional_properties!(value, location) when is_map(value),
    do: validate_schema!(value, location <> " additionalProperties")

  defp validate_additional_properties!(value, _location) when value in [nil, true, false],
    do: :ok

  defp validate_additional_properties!(_value, location),
    do: fail("invalid additionalProperties at #{location}")

  defp validate_properties!(nil, _location), do: :ok

  defp validate_properties!(properties, location) when is_map(properties) do
    Enum.each(properties, fn {name, property} ->
      validate_schema!(property, location <> "." <> name)
    end)
  end

  defp validate_properties!(_properties, location),
    do: fail("invalid properties at #{location}")

  defp validate_type!(nil, _location), do: :ok

  defp validate_type!(type, location) when is_binary(type) do
    unless type in @schema_types, do: fail("invalid type at #{location}")
  end

  defp validate_type!(types, location) when is_list(types) and types != [] do
    unless Enum.uniq(types) == types and Enum.all?(types, &(&1 in @schema_types)),
      do: fail("invalid type union at #{location}")
  end

  defp validate_type!(_type, location), do: fail("invalid type at #{location}")

  defp validate_required!(%{"required" => required}, location) when is_list(required) do
    unless required != [] and Enum.uniq(required) == required and
             Enum.all?(required, &(is_binary(&1) and byte_size(&1) > 0)),
           do: fail("invalid required members at #{location}")
  end

  defp validate_required!(_schema, _location), do: :ok

  defp validate_bounds!(schema, location) do
    Enum.each(
      [
        {"minimum", "maximum"},
        {"minLength", "maxLength"},
        {"minItems", "maxItems"}
      ],
      &validate_bound_pair!(schema, &1, location)
    )

    validate_enum!(schema["enum"], location)
  end

  defp validate_bound_pair!(schema, {minimum, maximum}, location) do
    if Map.has_key?(schema, minimum) and Map.has_key?(schema, maximum) do
      unless is_number(schema[minimum]) and is_number(schema[maximum]) and
               schema[minimum] <= schema[maximum],
             do: fail("invalid #{minimum}/#{maximum} at #{location}")
    end
  end

  defp validate_enum!(nil, _location), do: :ok

  defp validate_enum!(values, location) when is_list(values) and values != [] do
    unless Enum.uniq(values) == values, do: fail("duplicate enum at #{location}")
  end

  defp validate_enum!(_values, location), do: fail("invalid enum at #{location}")

  defp validate_refs!(document) do
    walk(document, fn
      {"$ref", "#/" <> _ = reference} -> resolve_reference!(document, reference)
      {"$ref", _reference} -> fail("external or malformed OpenAPI reference")
      _ -> :ok
    end)
  end

  defp resolve_reference!(document, "#/" <> pointer) do
    pointer
    |> String.split("/", trim: true)
    |> Enum.map(&(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))
    |> Enum.reduce(document, fn segment, value ->
      case value do
        %{^segment => child} -> child
        _ -> fail("unresolved OpenAPI reference #/#{pointer}")
      end
    end)
  end

  defp walk(map, callback) when is_map(map) do
    Enum.each(map, fn entry = {_key, value} ->
      callback.(entry)
      walk(value, callback)
    end)
  end

  defp walk(list, callback) when is_list(list), do: Enum.each(list, &walk(&1, callback))
  defp walk(_value, _callback), do: :ok

  defp fail(message), do: raise("OpenAPI validation failed: " <> message)
end

Wotex.Tracker.OpenAPIAudit.main(System.argv())
