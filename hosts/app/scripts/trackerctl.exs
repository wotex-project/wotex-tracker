defmodule Wotex.Tracker.Host.CLI.Transport do
  @moduledoc false

  alias Mint.HTTP
  alias Wotex.Binding.HTTP.SSE.Event
  alias Wotex.Tracker.Service.Codec
  alias Wotex.Tracker.Service.HTTP.SSEParser

  @body_limit 4_194_304
  @header_count 32
  @header_bytes 8_192

  def execute(config, request) do
    with {:ok, origin} <- origin(config),
         {:ok, connection} <- connect(origin, config.ca_file) do
      try do
        exchange(connection, origin, config, request)
      after
        HTTP.close(connection)
      end
    else
      {:error, code} -> {:error, code, false}
    end
  end

  defp origin(config) do
    with {:ok, uri} <- URI.new(config.url),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host),
         true <- is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query),
         true <- is_nil(uri.fragment),
         port when port in 1..65_535 <- uri.port || default_port(uri.scheme),
         :ok <- origin_policy(uri, config.ca_file) do
      {:ok, %{scheme: String.to_atom(uri.scheme), host: uri.host, port: port}}
    else
      _ -> {:error, "invalid_origin"}
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp origin_policy(%{scheme: "http", host: host}, nil) when host in ["127.0.0.1", "::1"],
    do: :ok

  defp origin_policy(%{scheme: "https"}, ca_file) when is_nil(ca_file) or is_binary(ca_file),
    do: :ok

  defp origin_policy(_, _), do: {:error, :invalid_origin}

  defp connect(origin, ca_file) do
    options = [mode: :passive, protocols: [:http1], timeout: 5_000, log: false]

    options =
      if origin.scheme == :https,
        do: Keyword.put(options, :transport_opts, tls_options(origin.host, ca_file)),
        else: options

    case HTTP.connect(origin.scheme, origin.host, origin.port, options) do
      {:ok, connection} -> {:ok, connection}
      _ -> {:error, "transport_unavailable"}
    end
  end

  defp tls_options(host, nil) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp tls_options(host, ca_file) do
    [
      verify: :verify_peer,
      cacertfile: String.to_charlist(ca_file),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp exchange(connection, origin, config, request) do
    streaming = request.stream
    accept = request.accept

    headers = [
      {"authorization", "Bearer " <> config.token},
      {"accept", accept},
      {"accept-encoding", "identity"},
      {"connection", "close"}
    ]

    headers =
      if request.body do
        [
          {"content-type", "application/json"},
          {"idempotency-key", request.operation} | headers
        ]
      else
        headers
      end

    deadline =
      System.monotonic_time(:millisecond) +
        if(streaming, do: request.seconds * 1_000, else: 5_000)

    case HTTP.request(
           connection,
           if(request.body, do: "POST", else: "GET"),
           request.path,
           headers,
           request.body
         ) do
      {:ok, connection, reference} ->
        state = %{
          status: nil,
          headers: [],
          body: [],
          bytes: 0,
          parser: SSEParser.new(32_768),
          delivered: 0
        }

        collect(connection, reference, origin, request, deadline, state)

      _ ->
        {:error, "transport_unavailable", true}
    end
  end

  defp collect(connection, reference, origin, request, deadline, state) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, "deadline_exceeded", true}
    else
      receive_response(connection, reference, origin, request, deadline, state, remaining)
    end
  end

  defp receive_response(connection, reference, origin, request, deadline, state, remaining) do
    case HTTP.recv(connection, 0, remaining) do
      {:ok, connection, responses} ->
        responses
        |> reduce_responses(reference, request, state)
        |> continue_response(connection, reference, origin, request, deadline)

      {:error, _connection, reason, responses} ->
        responses
        |> reduce_responses(reference, request, state)
        |> failed_response(reason, origin, request)

      _ ->
        {:error, "transport_unavailable", true}
    end
  end

  defp continue_response(
         {:more, state},
         connection,
         reference,
         origin,
         request,
         deadline
       ),
       do: collect(connection, reference, origin, request, deadline, state)

  defp continue_response({:done, state}, _connection, _reference, origin, request, _deadline),
    do: finish(origin, request, state)

  defp continue_response({:stream_done, _state}, _, _, _, _, _), do: {:ok, 0}
  defp continue_response({:error, code}, _, _, _, _, _), do: {:error, code, true}

  defp failed_response({:done, state}, _reason, origin, request),
    do: finish(origin, request, state)

  defp failed_response({:stream_done, _state}, _reason, _origin, _request), do: {:ok, 0}
  defp failed_response({:error, code}, _reason, _origin, _request), do: {:error, code, true}

  defp failed_response({:more, _state}, reason, _origin, %{stream: true})
       when reason == :timeout or
              (is_struct(reason, Mint.TransportError) and reason.reason == :timeout),
       do: {:error, "deadline_exceeded", true}

  defp failed_response(_, _reason, _origin, _request),
    do: {:error, "transport_unavailable", true}

  defp reduce_responses(responses, reference, request, state) do
    Enum.reduce_while(responses, {:more, state}, fn response, {:more, state} ->
      case response(response, reference, request, state) do
        {:more, state} -> {:cont, {:more, state}}
        result -> {:halt, result}
      end
    end)
  end

  defp response({:status, reference, status}, reference, _request, %{status: nil} = state)
       when status in 100..599,
       do: {:more, %{state | status: status}}

  defp response({:headers, reference, headers}, reference, _request, state) do
    headers = state.headers ++ headers

    if length(headers) <= @header_count and header_bytes(headers) <= @header_bytes,
      do: {:more, %{state | headers: headers}},
      else: {:error, "response_headers_too_large"}
  end

  defp response({:data, reference, bytes}, reference, %{stream: true} = request, state)
       when state.status == 200 do
    with :ok <- validate_headers(state.status, state.headers, request.accept),
         {:ok, parser, frames} <- feed(state.parser, bytes),
         {:ok, delivered} <- emit_frames(frames, request, state.delivered) do
      state = %{state | parser: parser, delivered: delivered}
      if delivered >= request.max_events, do: {:stream_done, state}, else: {:more, state}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp response({:data, reference, bytes}, reference, _request, state) do
    size = state.bytes + byte_size(bytes)

    if size <= @body_limit,
      do: {:more, %{state | body: [bytes | state.body], bytes: size}},
      else: {:error, "response_too_large"}
  end

  defp response({:done, reference}, reference, %{stream: true} = request, state)
       when state.status == 200 do
    case validate_headers(state.status, state.headers, request.accept) do
      :ok -> {:stream_done, state}
      {:error, code} -> {:error, code}
    end
  end

  defp response({:done, reference}, reference, _request, state), do: {:done, state}
  defp response(_, _, _, _), do: {:error, "transport_unavailable"}

  defp finish(_origin, request, state) do
    body = state.body |> Enum.reverse() |> IO.iodata_to_binary()
    expected = if state.status == 200, do: request.accept, else: "application/json"

    with :ok <- validate_headers(state.status, state.headers, expected),
         :ok <- validate_declared_size(state.headers),
         {:ok, value} <- Codec.decode(body),
         :ok <- validate_value(value, state.status, request),
         :ok <- output(request, state.status, value, body) do
      cond do
        state.status == 202 -> {:ok, 3}
        state.status in 200..299 -> {:ok, 0}
        true -> {:ok, 1}
      end
    else
      {:error, code} -> {:error, code, true}
    end
  end

  defp validate_headers(status, headers, expected_media) when is_integer(status) do
    encoding = header(headers, "content-encoding") || "identity"

    media =
      headers |> header("content-type") |> to_string() |> String.split(";", parts: 2) |> hd()

    cond do
      encoding != "identity" -> {:error, "unsupported_content_encoding"}
      media != expected_media -> {:error, "invalid_media_type"}
      true -> :ok
    end
  end

  defp validate_headers(_, _, _), do: {:error, "transport_unavailable"}

  defp validate_declared_size(headers) do
    case header(headers, "content-length") do
      nil -> :ok
      value -> if valid_size?(value), do: :ok, else: {:error, "response_too_large"}
    end
  end

  defp valid_size?(value) do
    case Integer.parse(value) do
      {size, ""} when size in 0..@body_limit -> true
      _ -> false
    end
  end

  defp validate_value(value, 200, %{raw: true}), do: native?(value)

  defp validate_value(value, 200, %{property: true}) do
    if is_number(value) or is_boolean(value), do: :ok, else: {:error, "unsupported_version"}
  end

  defp validate_value(%{"schema" => "wtr.response.v1"}, _status, _request), do: :ok
  defp validate_value(_, _, _), do: {:error, "unsupported_version"}

  defp output(%{output: path}, 200, _value, body) when is_binary(path),
    do: exclusive_write(path, body)

  defp output(_request, _status, value, _body) do
    emit(value)
    :ok
  end

  defp native?(_value), do: :ok

  defp feed(parser, bytes) when byte_size(bytes) <= 65_536,
    do: normalize_feed(SSEParser.feed(parser, bytes))

  defp feed(parser, bytes) do
    <<chunk::binary-size(65_536), rest::binary>> = bytes

    with {:ok, parser, first} <- feed(parser, chunk),
         {:ok, parser, last} <- feed(parser, rest),
         do: {:ok, parser, first ++ last}
  end

  defp normalize_feed({:ok, parser, frames}), do: {:ok, parser, frames}
  defp normalize_feed(_), do: {:error, "event_too_large"}

  defp emit_frames(frames, request, delivered) do
    Enum.reduce_while(frames, {:ok, delivered}, fn frame, {:ok, count} ->
      emit_frame(frame, request, count)
    end)
  end

  defp emit_frame(_frame, request, count) when count >= request.max_events,
    do: {:halt, {:ok, count}}

  defp emit_frame(frame, request, count) do
    case frame_value(frame, request.property) do
      {:ok, nil} ->
        {:cont, {:ok, count}}

      {:ok, value} ->
        emit(value)
        {:cont, {:ok, count + 1}}

      {:error, code} ->
        {:halt, {:error, code}}
    end
  end

  defp frame_value(%Event{} = frame, true) do
    with true <-
           Regex.match?(
             ~r/\Aproperty:(snapshot|event):(0|[1-9][0-9]{0,18}):(0|[1-9][0-9]{0,18})\z/,
             frame.event
           ),
         true <-
           byte_size(frame.id) <= 4_096 and Regex.match?(~r/\Awtrc1\.[A-Za-z0-9_-]+\z/, frame.id),
         {:ok, value} <- Codec.decode(frame.data),
         true <- is_number(value) or is_boolean(value) do
      {:ok,
       %{
         "schema" => "wtr.property.v1",
         "value" => value,
         "event" => frame.event,
         "generation" => frame.event |> String.split(":") |> List.last(),
         "cursor" => frame.id
       }}
    else
      _ -> {:error, "invalid_event"}
    end
  end

  defp frame_value(%Event{event: "tracker", data: data}, false) do
    case Codec.decode(data) do
      {:ok, %{"schema" => "wtr.event.v1"} = event} -> {:ok, event}
      _ -> {:error, "unsupported_version"}
    end
  end

  defp frame_value(%Event{}, false), do: {:ok, nil}

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(key) == name, do: value
    end)
  end

  defp header_bytes(headers),
    do:
      Enum.reduce(headers, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value)
      end)

  defp exclusive_write(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          :ok = File.chmod(path, 0o600)
          :ok = IO.binwrite(file, bytes)
          :ok = :file.sync(file)
          :ok
        after
          File.close(file)
        end

      _ ->
        {:error, "invalid_output"}
    end
  end

  defp emit(value), do: IO.puts(Codec.encode!(value))
end

defmodule Wotex.Tracker.Host.CLI do
  @moduledoc false

  import Bitwise
  alias Wotex.Tracker.Host.CLI.Transport
  alias Wotex.Tracker.Service.{Codec, HostProvisioning, Identifier}

  @resources ~w(observations resolutions evidence enrollments things state rules policies alerts)
  @raw_resources ~w(observations evidence)

  def main(arguments) do
    Application.ensure_all_started(:crypto)
    Application.ensure_all_started(:ssl)

    status =
      try do
        run(arguments)
      rescue
        _ ->
          emit_error("invalid_input")
          1
      catch
        {:usage, code} ->
          emit_error(code)
          2

        {:failure, code} ->
          emit_error(code)
          1
      end

    System.halt(status)
  end

  defp run(arguments) do
    {global, command} = parse(arguments)

    if command.name == :init do
      initialize(global, command)
      0
    else
      execute(global, command)
    end
  end

  defp execute(global, command) do
    {path, body, properties} = target(global.scope, command)
    operation = if body, do: command.operation || Identifier.uuid()
    if operation, do: emit_stderr(%{"schema" => "wtr.cli.v1", "operation_id" => operation})

    try do
      token = token_file(global.token_file)

      request =
        Map.merge(properties, %{
          path: path,
          body: body,
          operation: operation,
          seconds: Map.get(command, :seconds, 5),
          max_events: Map.get(command, :max_events, 0),
          output: Map.get(command, :output)
        })

      case Transport.execute(%{url: global.url, ca_file: global.ca_file, token: token}, request) do
        {:ok, status} ->
          status

        {:error, code, attempted} ->
          emit_error(code, operation, attempted)
          if operation && attempted, do: 3, else: 1
      end
    catch
      {:failure, code} ->
        emit_error(code, operation, false)
        1
    end
  end

  defp parse(arguments) do
    {options, rest, invalid} =
      OptionParser.parse_head(arguments,
        strict: [url: :string, scope: :string, token_file: :string, ca_file: :string]
      )

    if invalid != [], do: usage("invalid_arguments")
    global = Map.new(options)
    command = parse_command(rest)

    unless command.name == :init or
             Enum.all?([global[:url], global[:scope], global[:token_file]], &is_binary/1),
           do: fail("url_scope_and_token_file_required")

    {%{
       url: global[:url],
       scope: global[:scope],
       token_file: global[:token_file],
       ca_file: global[:ca_file]
     }, command}
  end

  defp parse_command(["init" | arguments]) do
    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [
          directory: :string,
          instance_id: :string,
          bind: :string,
          port: :integer,
          expires_in: :integer
        ]
      )

    if invalid != [] or rest != [], do: usage("invalid_arguments")
    values = Map.new(options)

    %{
      name: :init,
      directory: required(values[:directory]),
      instance_id: required(values[:instance_id]),
      bind: required(values[:bind]),
      port: required(values[:port]),
      expires_in: values[:expires_in] || 86_400
    }
  end

  defp parse_command([name]) when name in ["capabilities", "ready", "credentials"],
    do: %{name: String.to_atom(name)}

  defp parse_command(["list", resource | arguments]) do
    options = parse_options(arguments, limit: :integer, cursor: :string, thing: :string)
    thing = if options[:thing], do: identifier(options[:thing])

    # Rule statuses, definitions and alerts have per-Thing reads; only alerts are paged.
    if thing &&
         (resource not in ~w(rules policies alerts) or
            (resource in ~w(rules policies) and (options[:limit] || options[:cursor]))),
       do: usage("invalid_arguments")

    %{
      name: :list,
      resource: resource(resource, @resources),
      limit: options[:limit],
      cursor: options[:cursor],
      thing: thing
    }
  end

  defp parse_command([name, resource, id | arguments])
       when name in ["inspect", "history", "raw"] do
    allowed = if name == "raw", do: @raw_resources, else: @resources
    options = parse_options(arguments, limit: :integer, cursor: :string, output: :string)

    %{
      name: String.to_atom(name),
      resource: resource(resource, allowed),
      id: identifier(id),
      limit: options[:limit],
      cursor: options[:cursor],
      output: options[:output]
    }
  end

  defp parse_command(["import", path | arguments]) do
    options = mutation_options(arguments)
    %{name: :import, value: path, generation: options.generation, operation: options.operation}
  end

  defp parse_command(["enroll", observation | arguments]) do
    options = mutation_options(arguments, title: :string, confirm: :boolean)

    %{
      name: :enroll,
      value: identifier(observation),
      generation: options.generation,
      operation: options.operation,
      title: identifier(required(options[:title])),
      confirm: options[:confirm] == true
    }
  end

  defp parse_command(["associate", thing, observation | arguments]) do
    options = mutation_options(arguments, confirm: :boolean)

    %{
      name: :associate,
      value: identifier(thing),
      observation: identifier(observation),
      generation: options.generation,
      operation: options.operation,
      confirm: options[:confirm] == true
    }
  end

  defp parse_command(["unenroll", thing | arguments]) do
    options = mutation_options(arguments, confirm: :boolean)
    # Removal cannot be undone, so the CLI requires the same explicit confirmation as the browser.
    unless options[:confirm] == true, do: usage("confirmation_required")

    %{
      name: :unenroll,
      value: identifier(thing),
      generation: options.generation,
      operation: options.operation
    }
  end

  defp parse_command([name, value | arguments]) when name in ["materialize", "revoke"] do
    options = mutation_options(arguments)

    %{
      name: String.to_atom(name),
      value: identifier(value),
      generation: options.generation,
      operation: options.operation
    }
  end

  defp parse_command(["operation", id]), do: %{name: :operation, id: operation_id(id)}

  defp parse_command(["read", thing, property]),
    do: %{name: :read, thing: identifier(thing), property: identifier(property)}

  defp parse_command(["observe", thing, property | arguments]) do
    options = parse_options(arguments, cursor: :string, seconds: :integer, max_events: :integer)

    %{
      name: :observe,
      thing: identifier(thing),
      property: identifier(property),
      cursor: options[:cursor],
      seconds: options[:seconds] || 30,
      max_events: options[:max_events] || 100
    }
  end

  defp parse_command(["events" | arguments]) do
    options =
      parse_options(arguments,
        cursor: :string,
        stream: :boolean,
        seconds: :integer,
        max_events: :integer
      )

    %{
      name: :events,
      cursor: required(options[:cursor]),
      stream: options[:stream] == true,
      seconds: options[:seconds] || 30,
      max_events: options[:max_events] || 100
    }
  end

  defp parse_command(_), do: usage("invalid_arguments")

  defp mutation_options(arguments, extra \\ []) do
    options = parse_options(arguments, [generation: :string, operation: :string] ++ extra)

    %{
      generation: generation(required(options[:generation])),
      operation: if(options[:operation], do: operation_id(options[:operation]))
    }
    |> Map.merge(Map.drop(options, [:generation, :operation]))
  end

  defp parse_options(arguments, specification) do
    {options, rest, invalid} = OptionParser.parse(arguments, strict: specification)
    if invalid != [] or rest != [], do: usage("invalid_arguments")
    Map.new(options)
  end

  defp target(scope, command) do
    scope = identifier(scope)
    base = "/api/v1/scopes/" <> encode_segment(scope)
    command_target(command, base)
  end

  defp command_target(%{name: :capabilities}, base),
    do: {base <> "/capabilities", nil, finite("application/json")}

  defp command_target(%{name: :ready}, base),
    do: {base <> "/health/ready", nil, finite("application/json")}

  defp command_target(%{name: :credentials}, base),
    do: {base <> "/credentials", nil, finite("application/json")}

  defp command_target(%{name: :list} = command, base),
    do: resource_target(base, command, false)

  defp command_target(%{name: name} = command, base)
       when name in [:inspect, :history, :raw],
       do: resource_target(base, command, true)

  defp command_target(%{name: :operation, id: id}, base),
    do: {base <> "/operations/" <> encode_segment(id), nil, finite("application/json")}

  defp command_target(%{name: :read} = command, base),
    do: property_target(base, command, false)

  defp command_target(%{name: :observe} = command, base),
    do: property_target(base, command, true)

  defp command_target(%{name: :events} = command, base),
    do: events_target(base, command)

  defp command_target(%{name: name} = command, base)
       when name in [:import, :enroll, :associate, :materialize, :revoke, :unenroll],
       do: mutation_target(base, command)

  defp resource_target(base, command, item?) do
    path =
      case command do
        %{thing: thing} when is_binary(thing) ->
          base <> "/things/" <> encode_segment(thing) <> "/" <> command.resource

        _ ->
          base <> "/" <> command.resource
      end

    path = if item?, do: path <> "/" <> encode_segment(command.id), else: path

    path =
      if command.name in [:history, :raw],
        do: path <> "/" <> Atom.to_string(command.name),
        else: path

    query =
      if command.name in [:list, :history] do
        limit = command.limit
        if limit && limit not in 1..100, do: fail("invalid_limit")
        query(%{"limit" => limit, "cursor" => command.cursor})
      else
        ""
      end

    media =
      if command.name == :raw,
        do: "application/vnd.wotex.tracker.#{String.trim_trailing(command.resource, "s")}+json",
        else: "application/json"

    properties =
      finite(media)
      |> Map.merge(%{raw: command.name == :raw, output: Map.get(command, :output)})

    {path <> query, nil, properties}
  end

  defp property_target(base, command, stream?) do
    path =
      base <>
        "/things/" <>
        encode_segment(command.thing) <> "/properties/" <> encode_segment(command.property)

    if stream? do
      validate_stream(command)
      {path <> "/observe" <> query(%{"cursor" => command.cursor}), nil, stream(true)}
    else
      {path, nil, finite("application/json") |> Map.put(:property, true)}
    end
  end

  defp events_target(base, %{stream: true} = command) do
    validate_stream(command)
    {base <> "/events/stream" <> query(%{"cursor" => command.cursor}), nil, stream(false)}
  end

  defp events_target(base, command) do
    validate_stream(command)
    {base <> "/events" <> query(%{"cursor" => command.cursor}), nil, finite("application/json")}
  end

  defp mutation_target(base, command) do
    {resource, body} =
      case command.name do
        :import ->
          {"observations",
           %{"observation" => input(command.value), "expected_generation" => command.generation}}

        :enroll ->
          {"enrollments",
           %{
             "observation_id" => command.value,
             "title" => command.title,
             "owner_confirmed" => command.confirm,
             "expected_generation" => command.generation
           }}

        :associate ->
          {"associations",
           %{
             "thing_id" => command.value,
             "observation_id" => command.observation,
             "owner_confirmed" => command.confirm,
             "expected_generation" => command.generation
           }}

        :materialize ->
          {"materialisations",
           %{"thing_id" => command.value, "expected_generation" => command.generation}}

        :revoke ->
          {"revocations",
           %{"credential_id" => command.value, "expected_generation" => command.generation}}

        :unenroll ->
          {"unenrollments",
           %{"thing_id" => command.value, "expected_generation" => command.generation}}
      end

    bytes = Codec.encode!(body)
    if byte_size(bytes) > 1_048_576, do: fail("input_too_large")
    {base <> "/" <> resource, bytes, finite("application/json")}
  end

  defp finite(media),
    do: %{stream: false, accept: media, raw: false, property: false, output: nil}

  defp stream(property),
    do: %{stream: true, accept: "text/event-stream", raw: false, property: property, output: nil}

  defp validate_stream(command) do
    unless command.seconds in 1..300 and command.max_events in 1..1_000,
      do: fail("invalid_stream_limit")
  end

  defp query(values) do
    values = Enum.reject(values, fn {_key, value} -> is_nil(value) end)
    if values == [], do: "", else: "?" <> URI.encode_query(values)
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp input(path) do
    bytes = bounded_read(path, 1_048_576, "input_too_large")

    case Codec.decode(bytes) do
      {:ok, value} -> value
      {:error, %Wotex.Error{code: :duplicate_member}} -> fail("duplicate_json_key")
      _ -> fail("invalid_json")
    end
  end

  defp initialize(global, command) do
    unless is_binary(global.scope) and command.bind in ["127.0.0.1", "::1"] and
             command.port in 1..65_535 and command.expires_in in 1..604_800,
           do: fail("invalid_configuration")

    identifier(global.scope)
    identifier(command.instance_id)
    directory = Path.expand(command.directory)
    if Path.type(command.directory) != :absolute, do: fail("private_directory_required")

    HostProvisioning.initialize(%{
      destination_root: directory,
      runtime_root: directory,
      instance_id: command.instance_id,
      scope: global.scope,
      ip: command.bind,
      port: command.port,
      expires_at: System.system_time(:millisecond) + command.expires_in * 1_000
    })
    |> finish_initialize()
  end

  defp finish_initialize(result) do
    case result do
      {:ok, paths} ->
        emit(%{
          "schema" => "wtr.cli.v1",
          "config" => paths.config,
          "token_file" => paths.token_file,
          "data_directory" => paths.data_directory
        })

      {:error, :private_directory_required} ->
        fail("private_directory_required")

      {:error, :configuration_exists} ->
        fail("configuration_exists")

      _ ->
        fail("invalid_configuration")
    end
  end

  defp private_directory(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o700,
         :ok <- real_directories(Path.dirname(path)) do
      :ok
    else
      _ -> fail("private_directory_required")
    end
  end

  defp real_directories(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        parent = Path.dirname(path)
        if parent == path, do: :ok, else: real_directories(parent)

      _ ->
        fail("private_directory_required")
    end
  end

  defp token_file(path) when is_binary(path) do
    private_directory(Path.dirname(path))

    with {:ok, %{type: :regular, links: 1, mode: mode, size: size}} <- File.lstat(path),
         true <- (mode &&& 0o777) == 0o600 and size in 43..44,
         bytes when is_binary(bytes) <- bounded_read(path, 44, "invalid_token"),
         value <-
           if(String.ends_with?(bytes, "\n"), do: String.trim_trailing(bytes, "\n"), else: bytes),
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, value),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(decoded, padding: false) == value do
      value
    else
      _ -> fail("private_token_file_required")
    end
  end

  defp token_file(_), do: fail("private_token_file_required")

  defp bounded_read(path, limit, code) do
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, limit + 1) end) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= limit -> bytes
      _ -> fail(code)
    end
  end

  defp resource(value, allowed) do
    if value in allowed, do: value, else: usage("invalid_resource")
  end

  defp required(nil), do: usage("missing_argument")
  defp required(value), do: value

  defp generation(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 and integer < 9_223_372_036_854_775_807 ->
        if Integer.to_string(integer) == value, do: value, else: usage("invalid_generation")

      _ ->
        usage("invalid_generation")
    end
  end

  defp identifier(value) when is_binary(value) do
    if byte_size(value) in 1..256 and String.valid?(value) and
         not String.contains?(value, Enum.map(0..31, &<<&1>>)),
       do: value,
       else: usage("invalid_identifier")
  end

  defp identifier(_), do: usage("invalid_identifier")

  defp operation_id(value) do
    if Regex.match?(
         ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
         value
       ),
       do: value,
       else: usage("invalid_operation_id")
  end

  defp emit(value), do: IO.puts(Codec.encode!(value))
  defp emit_stderr(value), do: IO.puts(:stderr, Codec.encode!(value))

  defp emit_error(code, operation \\ nil, attempted \\ false) do
    error = %{"code" => code}

    error =
      if operation,
        do:
          Map.merge(error, %{
            "operation_id" => operation,
            "outcome" => if(attempted, do: "unknown", else: "not_committed")
          }),
        else: error

    emit_stderr(%{"schema" => "wtr.cli.v1", "error" => error})
  end

  defp fail(code), do: throw({:failure, code})
  defp usage(code), do: throw({:usage, code})
end

unless System.get_env("WOTEX_TRACKER_CLI_NO_MAIN") == "1" do
  Wotex.Tracker.Host.CLI.main(System.argv())
end
