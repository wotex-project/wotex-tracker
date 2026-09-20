defmodule Wotex.Tracker.Host.TrackerctlTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Wotex.Tracker.Service.{Codec, Identifier}

  @cli Path.expand("bin/trackerctl")
  @token String.duplicate("A", 43)

  setup do
    directory = Path.expand("_build/test/cli-unit/#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    token_path = Path.join(directory, "operator.token")
    File.write!(token_path, @token <> "\n")
    File.chmod!(token_path, 0o600)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, token_path: token_path}
  end

  test "private token and local input failures happen before a mutation attempt", context do
    File.chmod!(context.token_path, 0o644)
    result = run_cli(context, ["materialize", "thing", "--generation", "0"])
    assert error(result)["outcome"] == "not_committed"
    assert result.status == 1

    File.chmod!(context.token_path, 0o600)
    input = Path.join(context.directory, "observation.json")
    File.write!(input, ~s({"payload":1,"payload":2}))

    assert error(run_cli(context, ["import", input, "--generation", "0"]))["code"] ==
             "duplicate_json_key"

    File.write!(input, :binary.copy(" ", 1_048_577))
    result = run_cli(context, ["import", input, "--generation", "0"])
    assert error(result)["code"] == "input_too_large"
  end

  test "a disconnected mutation is unknown and is not retried", context do
    operation = Identifier.uuid()

    {result, observations} =
      peer(context, <<>>, [
        "materialize",
        "thing",
        "--generation",
        "0",
        "--operation",
        operation
      ])

    assert observations == [:accepted]
    assert result.status == 3
    assert error(result)["outcome"] == "unknown"
    assert error(result)["operation_id"] == operation
  end

  test "an accepted unknown receipt keeps the operation identity", context do
    operation = Identifier.uuid()

    body =
      Codec.encode!(%{
        "schema" => "wtr.response.v1",
        "data" => %{"outcome" => "unknown", "operation_id" => operation}
      })

    response = http_response(202, "Accepted", "application/json", body)

    {result, _observations} =
      peer(context, response, [
        "materialize",
        "thing",
        "--generation",
        "0",
        "--operation",
        operation
      ])

    assert result.status == 3
    assert response_value(result)["data"]["operation_id"] == operation
  end

  test "Action invocation is a single bounded mutation and status polling is read-only",
       context do
    operation = Identifier.uuid()
    input = Path.join(context.directory, "action-input.json")
    File.write!(input, "5")

    receipt =
      Codec.encode!(%{
        "schema" => "wtr.response.v1",
        "data" => %{
          "outcome" => "committed",
          "operation_id" => operation,
          "generation" => "4",
          "disposition" => "queued",
          "data" => %{"action_id" => operation, "status" => "queued"}
        }
      })

    {result, request} =
      peer_request(
        context,
        http_response(200, "OK", "application/json", receipt),
        [
          "action",
          "invoke",
          "thing one",
          "refresh now",
          "--input",
          input,
          "--generation",
          "4",
          "--operation",
          operation
        ]
      )

    assert result.status == 0

    assert request =~
             "POST /api/v1/scopes/workshop/things/thing%20one/actions/refresh%20now HTTP/1.1"

    assert String.downcase(request) =~ "idempotency-key: #{operation}"
    assert request =~ ~s({"expected_generation":"4","input":5})

    status =
      Codec.encode!(%{
        "schema" => "wtr.response.v1",
        "data" => %{
          "schema" => "wtr.action-status.v1",
          "operation_id" => operation,
          "status" => "unknown",
          "physical_effect" => "unknown"
        }
      })

    {result, request} =
      peer_request(
        context,
        http_response(200, "OK", "application/json", status),
        ["action", "status", operation]
      )

    assert result.status == 0
    assert request =~ "GET /api/v1/scopes/workshop/actions/#{operation} HTTP/1.1"
    refute String.downcase(request) =~ "idempotency-key:"

    File.write!(input, :binary.copy(" ", 16_385))

    result =
      run_cli(context, [
        "action",
        "invoke",
        "thing",
        "refresh",
        "--input",
        input,
        "--generation",
        "4"
      ])

    assert result.status == 1
    assert error(result)["code"] == "input_too_large"
  end

  test "response byte, header, media and version limits fail closed", context do
    oversized = :binary.copy(" ", 4_194_305)

    cases = [
      {
        "response_too_large",
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " <>
          Integer.to_string(byte_size(oversized)) <> "\r\n\r\n" <> oversized
      },
      {
        "response_headers_too_large",
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
          :binary.copy("X: y\r\n", 32) <> "Content-Length: 0\r\n\r\n"
      },
      {"invalid_media_type", http_response(200, "OK", "text/plain", "{}")},
      {
        "unsupported_content_encoding",
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
          "Content-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}"
      },
      {"unsupported_version", http_response(200, "OK", "application/json", "{}")},
      {
        "invalid_media_type",
        "HTTP/1.1 302 Found\r\nLocation: https://untrusted.example/\r\n" <>
          "Content-Type: text/plain\r\nContent-Length: 0\r\n\r\n"
      }
    ]

    for {code, response} <- cases do
      {result, _observations} = peer(context, response, ["capabilities"])
      assert result.status == 1
      assert error(result)["code"] == code
    end
  end

  test "property streams preserve native values and reject invalid samples", context do
    handshake = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
    prefix = "id: wtrc1.opaque\nevent: property:event:4:4\ndata: "

    for {encoded, expected} <- [{"0", 0}, {"1.0", 1.0}, {"false", false}] do
      {result, _observations} =
        peer(context, handshake <> prefix <> encoded <> "\n\n", [
          "observe",
          "thing",
          "temperature",
          "--max-events",
          "1"
        ])

      assert result.status == 0
      sample = response_value(result)
      assert sample["schema"] == "wtr.property.v1"
      assert sample["value"] === expected
      assert sample["generation"] == "4"
    end

    invalid_frames = [
      prefix <> "null\n\n",
      prefix <> "{}\n\n",
      "data: 1\n\n",
      "id: invalid\nevent: property:event:4:4\ndata: 1\n\n",
      prefix <> "1\ndata: 2\n\n"
    ]

    for frame <- invalid_frames do
      {result, _observations} =
        peer(context, handshake <> frame, ["observe", "thing", "temperature"])

      assert result.status == 1
      assert error(result)["code"] == "invalid_event"
    end

    result = run_cli(context, ["observe", "thing", "temperature", "--seconds", "301"])
    assert error(result)["code"] == "invalid_stream_limit"
  end

  @tag timeout: 10_000
  test "a stream deadline closes the socket and oversized frames fail", context do
    handshake = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"

    {result, observations} =
      peer(
        context,
        handshake,
        ["events", "--cursor", "cursor", "--stream", "--seconds", "1"],
        true
      )

    assert result.status == 1
    assert error(result)["code"] == "deadline_exceeded"
    assert :closed in observations

    {result, _observations} =
      peer(
        context,
        handshake <> "data: " <> :binary.copy("x", 32_769),
        ["events", "--cursor", "cursor", "--stream"]
      )

    assert error(result)["code"] == "event_too_large"
  end

  defp run_cli(context, arguments, port \\ 1) do
    base = [
      "--url",
      "http://127.0.0.1:#{port}",
      "--scope",
      "workshop",
      "--token-file",
      context.token_path
    ]

    {output, status} =
      System.cmd(@cli, base ++ arguments,
        stderr_to_stdout: true,
        env: [
          {"HTTP_PROXY", "http://127.0.0.1:1"},
          {"HTTPS_PROXY", "http://127.0.0.1:1"}
        ]
      )

    refute output =~ @token
    %{output: output, status: status, values: decode_lines(output)}
  end

  defp peer(context, response, arguments, pending \\ false) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    task = Task.async(fn -> serve(listener, response, pending) end)
    result = run_cli(context, arguments, port)
    {result, Task.await(task, 4_000)}
  end

  defp peer_request(context, response, arguments) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    task = Task.async(fn -> serve_request(listener, response) end)
    result = run_cli(context, arguments, port)
    {result, Task.await(task, 4_000)}
  end

  defp serve(listener, response, pending) do
    {observations, _request} = exchange(listener, response, pending)
    observations
  end

  defp serve_request(listener, response) do
    {_observations, request} = exchange(listener, response, false)
    request
  end

  defp exchange(listener, response, pending) do
    {:ok, connection} = :gen_tcp.accept(listener, 3_000)
    :ok = :gen_tcp.close(listener)
    request = receive_headers(connection, <<>>)

    if byte_size(request) > 16_384, do: raise("test request exceeded bounds")
    if response != <<>>, do: :ok = :gen_tcp.send(connection, response)

    observations =
      if pending do
        case :gen_tcp.recv(connection, 1, 3_000) do
          {:error, :closed} -> [:accepted, :closed]
          _ -> [:accepted, :unexpected]
        end
      else
        [:accepted]
      end

    :gen_tcp.close(connection)
    {observations, request}
  end

  defp receive_headers(_connection, request) when byte_size(request) > 16_384,
    do: request

  defp receive_headers(connection, request) do
    if :binary.match(request, "\r\n\r\n") == :nomatch do
      case :gen_tcp.recv(connection, 0, 3_000) do
        {:ok, bytes} -> receive_headers(connection, request <> bytes)
        {:error, :closed} -> request
      end
    else
      request
    end
  end

  defp decode_lines(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Codec.decode(line) do
        {:ok, value} -> [value]
        _ -> []
      end
    end)
  end

  defp error(result), do: Enum.find_value(result.values, & &1["error"])

  defp response_value(result) do
    Enum.find(result.values, fn
      %{"schema" => "wtr.cli.v1", "operation_id" => _} -> false
      _ -> true
    end)
  end

  defp http_response(status, reason, media, body) do
    "HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{media}\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
  end
end
