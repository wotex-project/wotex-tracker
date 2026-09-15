defmodule Wotex.Tracker.InteractionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Binding.HTTP
  alias Wotex.Runtime.{ConsumedThing, Context, Result}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.HTTP.{Config, LoopbackClient, Server}
  alias Wotex.Tracker.Service.{Identifier, PeerCredentials}

  test "ExposedThing reads one committed generation and preserves unavailable state" do
    c = service()
    {thing, td} = materialized(c)
    context = Context.new!(request_id: "read")
    assert {:ok, %{"value" => 24.3, "generation" => "3"}} = read(c, thing, "temperature", context)
    assert {:ok, %{"value" => 100_044}} = read(c, thing, "pressure", context)
    assert {:error, %{"code" => "not_found"}} = read(c, thing, "missing", context)
    assert {:error, %{"code" => "not_found"}} = read(c, "missing", "temperature", context)
    assert {:error, %{"code" => "invalid_request"}} = read(c, thing, "", context)

    assert {:error, %{"code" => "unauthorized"}} =
             read(%{c | reader: "invalid"}, thing, "temperature", context)

    expired =
      Context.new!(request_id: "expired", deadline: System.monotonic_time(:millisecond) - 1)

    assert {:error, %{"code" => "deadline_exceeded"}} = read(c, thing, "temperature", expired)

    unavailable = service()
    <<5, _temperature::16, rest::binary>> = observation().payload |> elem(1)

    {unavailable_id, unavailable_td} =
      materialized(unavailable, %{payload: {:bytes, <<5, 0x8000::16, rest::binary>>}})

    assert unavailable_td["properties"] ==
             td["properties"] |> replace_origin_id(thing, unavailable_id)

    assert {:error, %{"code" => "unavailable"}} =
             read(unavailable, unavailable_id, "temperature", context)

    assert {:ok, %{"value" => 100_044}} = read(unavailable, unavailable_id, "pressure", context)
  end

  test "ConsumedThing follows the materialized TD over a real authenticated HTTP binding" do
    for available? <- [true, false] do
      c = service()
      server = start_supervised!(Supervisor.child_spec({Server, options(c)}, id: make_ref()))
      {:ok, {_, port}} = Server.listener_info(server)
      {:ok, config} = LoopbackClient.new("http://127.0.0.1:#{port}", c.scope)
      {:ok, service} = Server.context(server, server_config(c))
      c = %{c | service: service}
      <<5, _temperature::16, rest::binary>> = observation().payload |> elem(1)

      changes =
        if available?, do: %{}, else: %{payload: {:bytes, <<5, 0x8000::16, rest::binary>>}}

      {thing, document} = materialized(c, changes)
      {:ok, td} = Wotex.ThingDescription.from_map(document)
      table = :ets.new(:peer_credentials, [:private])
      :ets.insert(table, {:token, c.reader})
      {:ok, profile} = HTTP.profile()
      {:ok, binding} = HTTP.config(client: {LoopbackClient, config})

      {:ok, consumed} =
        ConsumedThing.new(td,
          profiles: [profile],
          transports: %{http: HTTP.transport(binding)},
          credentials: {PeerCredentials, table}
        )

      refute :erlang.term_to_binary(consumed) =~ c.reader

      context =
        Context.new!(request_id: "peer", deadline: System.monotonic_time(:millisecond) + 3000)

      if available? do
        assert {:ok, %Result{payload: 24.3, status: :ok, operation: :readproperty}} =
                 ConsumedThing.read_property(consumed, "temperature", context)
      else
        assert {:error, _} = ConsumedThing.read_property(consumed, "temperature", context)
      end

      assert {:ok, %Result{payload: 100_044}} =
               ConsumedThing.read_property(consumed, "pressure", context)

      assert {:error, _} = ConsumedThing.write_property(consumed, "temperature", 1, context)

      assert {:error, _} =
               ConsumedThing.observation_child_spec(consumed, "temperature", context,
                 id: :unsupported,
                 receiver: self()
               )

      assert {:ok, _} =
               Service.revoke(
                 service,
                 c.admin,
                 c.scope,
                 Identifier.uuid(),
                 %{"credential_id" => "reader", "expected_generation" => "3"},
                 c.now
               )

      assert {:error, error} = ConsumedThing.read_property(consumed, "temperature", context)
      refute inspect(error) =~ c.reader
      refute inspect(error) =~ thing
      :ets.delete(table)
    end
  end

  defp read(c, thing, name, context),
    do: Service.read_property(c.service, c.reader, c.scope, thing, name, context, c.now)

  defp replace_origin_id(properties, old, new) do
    properties
    |> Jason.encode!()
    |> String.replace(
      URI.encode(old, &URI.char_unreserved?/1),
      URI.encode(new, &URI.char_unreserved?/1)
    )
    |> Jason.decode!()
  end

  defp options(c),
    do: [
      directory: c.directory,
      credentials: c.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> c.now end
    ]

  defp server_config(c) do
    {:ok, config} = Config.new(options(c))
    config
  end
end
