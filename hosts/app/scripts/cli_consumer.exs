defmodule Wotex.Tracker.Host.CLIConsumer do
  @moduledoc false

  alias Wotex.Tracker.Service.{Codec, Identifier}

  @now 1_700_000_000_000
  @payload "BRL8U5TDfAAE//wEDKw2QgDNy7gzTIhP"

  def main([descriptor_path]) do
    descriptor = descriptor_path |> File.read!() |> Codec.decode!()
    token = descriptor["token_file"] |> File.read!() |> String.trim()

    context = %{
      base: [
        "--url",
        descriptor["url"],
        "--scope",
        "workshop",
        "--token-file",
        descriptor["token_file"]
      ],
      cli: descriptor["cli"],
      token: token
    }

    [%{"data" => %{"writable" => true}}] = call(context, ["ready"])

    [%{"data" => %{"runtime" => %{"readproperty" => "available"}, "rules" => "heartbeat_battery_definitions"}}] =
      call(context, ["capabilities"])

    [%{"data" => %{"items" => [], "cursor" => nil, "generation" => "0"}}] =
      call(context, ["list", "rules", "--limit", "1"])

    [%{"error" => %{"code" => "not_found"}}] =
      call(context, ["inspect", "rules", "heartbeat:missing"], 1)

    [%{"error" => %{"code" => "not_found"}}] =
      call(context, ["history", "rules", "heartbeat:missing"], 1)

    [%{"data" => snapshot}] = call(context, ["list", "state"])
    observation_path = Path.join(Path.dirname(descriptor["token_file"]), "observation.json")
    observation = observation("cli-observation", @payload)
    File.write!(observation_path, Codec.encode!(observation))
    operation = Identifier.uuid()

    [%{"data" => receipt}] =
      call(context, [
        "import",
        observation_path,
        "--generation",
        "0",
        "--operation",
        operation
      ])

    "committed" = receipt["outcome"]

    [%{"data" => ^receipt}] =
      call(context, [
        "import",
        observation_path,
        "--generation",
        "0",
        "--operation",
        operation
      ])

    [%{"data" => ^receipt}] = call(context, ["operation", operation])

    [%{"error" => %{"code" => "idempotency_conflict"}}] =
      call(
        context,
        [
          "import",
          observation_path,
          "--generation",
          "1",
          "--operation",
          operation
        ],
        1
      )

    observation_id = get_in(receipt, ["data", "observation_id"])

    [%{"data" => %{"value" => %{"id" => ^observation_id}}}] =
      call(context, ["inspect", "observations", observation_id])

    [^observation] = call(context, ["raw", "observations", observation_id])
    export = Path.join(Path.dirname(observation_path), "export.json")
    [] = call(context, ["raw", "observations", observation_id, "--output", export])
    ^observation = export |> File.read!() |> Codec.decode!()
    bytes = File.read!(export)
    true = String.contains?(bytes, ~s("integer":1))
    true = String.contains?(bytes, ~s("float":1.0))
    0o600 = Bitwise.band(File.stat!(export).mode, 0o777)

    [%{"data" => enrolled}] =
      call(context, [
        "enroll",
        observation_id,
        "--title",
        "CLI sensor",
        "--confirm",
        "--generation",
        "1",
        "--operation",
        Identifier.uuid()
      ])

    thing = get_in(enrolled, ["data", "thing_id"])

    call(context, [
      "materialize",
      thing,
      "--generation",
      "2",
      "--operation",
      Identifier.uuid()
    ])

    [24.3] = call(context, ["read", thing, "temperature"])
    [100_044] = call(context, ["read", thing, "pressure"])

    [%{"error" => %{"code" => "not_found"}}] =
      call(context, ["read", thing, "missing"], 1)

    [%{"data" => %{"items" => replay}}] =
      call(context, ["events", "--cursor", snapshot["stream_cursor"]])

    ["1", "2", "3"] = Enum.map(replay, & &1["id"])

    streamed =
      call(context, [
        "events",
        "--cursor",
        snapshot["stream_cursor"],
        "--stream",
        "--max-events",
        "3",
        "--seconds",
        "3"
      ])

    ["1", "2", "3"] = Enum.map(streamed, & &1["id"])

    [initial] =
      call(context, [
        "observe",
        thing,
        "temperature",
        "--max-events",
        "1",
        "--seconds",
        "3"
      ])

    %{
      "schema" => "wtr.property.v1",
      "value" => 24.3,
      "event" => "property:snapshot:3:3",
      "generation" => "3"
    } = initial

    call(context, [
      "materialize",
      thing,
      "--generation",
      "3",
      "--operation",
      Identifier.uuid()
    ])

    [next_value] =
      call(context, [
        "observe",
        thing,
        "temperature",
        "--cursor",
        initial["cursor"],
        "--max-events",
        "1",
        "--seconds",
        "3"
      ])

    %{"event" => "property:event:4:4", "value" => 24.3} = next_value
    [%{"data" => history}] = call(context, ["history", "things", thing, "--limit", "1"])
    [%{"generation" => "3"}] = history["items"]

    [%{"data" => %{"items" => [%{"generation" => "4"}]}}] =
      call(context, ["history", "things", thing, "--cursor", history["cursor"]])

    later_observation = observation("cli-later-observation", warmer_payload())
    File.write!(observation_path, Codec.encode!(later_observation))

    [%{"data" => %{"data" => %{"observation_id" => later}}}] =
      call(context, [
        "import",
        observation_path,
        "--generation",
        "4",
        "--operation",
        Identifier.uuid()
      ])

    [%{"data" => %{"data" => %{"thing_id" => ^thing}}}] =
      call(context, [
        "associate",
        thing,
        later,
        "--confirm",
        "--generation",
        "5",
        "--operation",
        Identifier.uuid()
      ])

    [24.3] = call(context, ["read", thing, "temperature"])

    call(context, [
      "materialize",
      thing,
      "--generation",
      "6",
      "--operation",
      Identifier.uuid()
    ])

    [30.0] = call(context, ["read", thing, "temperature"])
    [%{"data" => %{"items" => [_]}}] = call(context, ["list", "things"])

    [%{"data" => %{"items" => enrollment_history}}] =
      call(context, ["history", "enrollments", thing])

    ["2", "6"] = Enum.map(enrollment_history, & &1["generation"])

    [%{"data" => %{"outcome" => "committed"}}] =
      call(context, [
        "revoke",
        "operator",
        "--generation",
        "7",
        "--operation",
        Identifier.uuid()
      ])

    [%{"error" => %{"code" => "unauthorized"}}] = call(context, ["list", "things"], 1)

    IO.puts(
      "CLI_CONSUMER_PASS workflow=true explicit_association=true history=true " <>
        "sse=true property_observation=true native_types=true self_revocation=true rule_status=true"
    )
  end

  def main(_arguments), do: raise("usage: cli_consumer.exs DESCRIPTOR")

  defp call(context, arguments, expected_status \\ 0) do
    {output, status} =
      System.cmd(context.cli, context.base ++ arguments,
        stderr_to_stdout: true,
        env: [
          {"HTTP_PROXY", "http://127.0.0.1:1"},
          {"HTTPS_PROXY", "http://127.0.0.1:1"}
        ]
      )

    if status != expected_status,
      do: raise("#{hd(arguments)} returned #{status}, expected #{expected_status}: #{output}")

    if String.contains?(output, context.token), do: raise("CLI disclosed its bearer token")

    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&decode_line/1)
  end

  defp decode_line(line) do
    case Codec.decode(line) do
      {:ok, %{"schema" => "wtr.cli.v1", "operation_id" => operation_id} = value}
      when map_size(value) == 2 and is_binary(operation_id) ->
        []

      {:ok, value} ->
        [value]

      _ ->
        []
    end
  end

  defp observation(id, payload) do
    %{
      "schema" => "wtr.observation.v1",
      "id" => id,
      "observed_at" => @now,
      "ingress" => "ble",
      "source" => %{"integer" => 1, "float" => 1.0, "wide" => 9_007_199_254_740_993},
      "addressing" => %{},
      "radio" => %{},
      "transport" => %{"manufacturer_id" => 1_177},
      "provenance" => %{},
      "payload" => %{"kind" => "bytes", "encoding" => "base64", "data" => payload}
    }
  end

  defp warmer_payload do
    <<head, _temperature::binary-size(2), rest::binary>> = Base.decode64!(@payload)
    Base.encode64(<<head, 6_000::unsigned-big-integer-size(16), rest::binary>>)
  end
end

Wotex.Tracker.Host.CLIConsumer.main(System.argv())
