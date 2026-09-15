defmodule Wotex.Tracker.RuntimeObservationTest do
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Binding.HTTP
  alias Wotex.Runtime.{ConsumedThing, Context, Subscription}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.HTTP.{Config, LoopbackClient, Server, SSEConnection}
  alias Wotex.Tracker.Service.{Identifier, PeerCredentials}

  test "actual Runtime subscriptions deliver native values, resume and close one of several connections" do
    {c, thing, document, config, vault} = instance()
    consumed = consumed(document, config, vault)
    refute :erlang.term_to_binary(consumed) =~ c.reader
    temperature = subscribe(consumed, "temperature", :temperature)
    pressure = subscribe(consumed, "pressure", :pressure)
    assert_receive {:wotex_runtime, :temperature, {:ok, 24.3, first}}, 2000
    assert first.operation == :observeproperty
    assert first.event =~ "property:snapshot:3"
    assert first.id =~ "wtrc1."
    assert_receive {:wotex_runtime, :pressure, {:ok, 100_044, _}}, 2000

    {temperature_connection, pressure_connection} =
      {connection(temperature), connection(pressure)}

    for pid <- [temperature_connection, pressure_connection] do
      refute :erlang.term_to_binary(:sys.get_state(pid)) =~ c.reader
      refute inspect(:sys.get_status(pid)) =~ c.reader
    end

    monitor = Process.monitor(temperature_connection)
    assert :ok = Subscription.stop(temperature)
    assert_receive {:DOWN, ^monitor, :process, ^temperature_connection, _}, 1000
    assert Process.alive?(pressure_connection)
    change(c, thing, "3", 6000)
    assert_receive {:wotex_runtime, :pressure, {:ok, 100_044, meta}}, 2000
    assert meta.event == "property:event:6:6"
    refute_receive {:wotex_runtime, :temperature, {:ok, _, _}}
    resumed = consumed(document, config, vault, [{"last-event-id", first.id}])
    temperature = subscribe(resumed, "temperature", :resumed)
    assert_receive {:wotex_runtime, :resumed, {:ok, 30.0, replayed}}, 2000
    assert replayed.event == "property:event:6:6"
    assert :ok = Subscription.stop(temperature)
    assert :ok = Subscription.stop(pressure)
  end

  test "revocation closes actual streams and rejects reopening without retaining credentials" do
    {c, _thing, document, config, vault} = instance()
    consumed = consumed(document, config, vault)
    pid = subscribe(consumed, "temperature", :revoked)
    assert_receive {:wotex_runtime, :revoked, {:ok, 24.3, _}}, 2000
    connection = connection(pid)
    monitor = Process.monitor(pid)
    connection_monitor = Process.monitor(connection)

    {:ok, _} =
      Service.revoke(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"credential_id" => "reader", "expected_generation" => "3"},
        c.now
      )

    assert_receive {:wotex_runtime, :revoked, {:status, :transport_down}}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1000
    assert_receive {:DOWN, ^connection_monitor, :process, ^connection, _}, 1000
    reopened = subscribe(consumed, "temperature", :denied)
    monitor = Process.monitor(reopened)
    assert_receive {:wotex_runtime, :denied, {:error, error}}, 2000
    refute inspect(error) =~ c.reader
    assert_receive {:DOWN, ^monitor, :process, ^reopened, _}, 1000
  end

  test "receiver death, killed owner and unavailable state release the actual connection" do
    {c, thing, document, config, vault} = instance()
    consumed = consumed(document, config, vault)

    receiver =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pid = subscribe(consumed, "temperature", :receiver, receiver)
    wait_active(pid)
    connection = connection(pid)
    monitor = Process.monitor(connection)
    send(receiver, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _}, 1000
    pid = subscribe(consumed, "temperature", :killed)
    assert_receive {:wotex_runtime, :killed, {:ok, 24.3, _}}, 2000
    connection = connection(pid)
    monitor = Process.monitor(connection)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^connection, _}, 1000
    pid = subscribe(consumed, "temperature", :unavailable)
    assert_receive {:wotex_runtime, :unavailable, {:ok, 24.3, _}}, 2000
    monitor = Process.monitor(pid)
    change(c, thing, "3", 0x8000)
    assert_receive {:wotex_runtime, :unavailable, {:status, :transport_down}}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1000
    refute_receive {:wotex_runtime, :unavailable, {:ok, nil, _}}
  end

  defp instance do
    c = service()

    options = [
      directory: c.directory,
      credentials: c.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> c.now end,
      poll_interval: 25
    ]

    server = start_supervised!(Supervisor.child_spec({Server, options}, id: make_ref()))
    {:ok, {_, port}} = Server.listener_info(server)
    {:ok, host} = Config.new(options)
    {:ok, service} = Server.context(server, host)
    c = %{c | service: service}
    {thing, td} = materialized(c)
    {:ok, config} = LoopbackClient.new("http://127.0.0.1:#{port}", c.scope)
    vault = start_supervised!({PeerCredentials, c.reader})
    {c, thing, td, config, vault}
  end

  defp consumed(document, config, vault, headers \\ []) do
    {:ok, td} = Wotex.ThingDescription.from_map(document)
    {:ok, profile} = HTTP.profile()
    {:ok, binding} = HTTP.config(client: {LoopbackClient, config}, headers: headers)

    {:ok, consumed} =
      ConsumedThing.new(td,
        profiles: [profile],
        transports: %{http: HTTP.transport(binding)},
        credentials: {PeerCredentials, vault}
      )

    consumed
  end

  defp subscribe(consumed, name, id, receiver \\ self()) do
    context =
      Context.new!(
        request_id: Atom.to_string(id),
        deadline: System.monotonic_time(:millisecond) + 5000
      )

    {:ok, spec} =
      ConsumedThing.observation_child_spec(consumed, name, context,
        id: id,
        receiver: receiver,
        max_queue_length: 32,
        overflow: :stop
      )

    start_supervised!(Supervisor.child_spec(spec, restart: :temporary))
  end

  defp connection(pid) do
    state = :sys.get_state(pid)

    {LoopbackClient, {SSEConnection, {connection, _reference}, _, _}, _, _} =
      HTTP.Subscription.unwrap(state.handle)

    connection
  end

  defp wait_active(pid, remaining \\ 100) do
    if :sys.get_state(pid).active? do
      :ok
    else
      assert remaining > 0
      Process.sleep(10)
      wait_active(pid, remaining - 1)
    end
  end

  defp change(c, thing, generation, raw) do
    number = String.to_integer(generation)
    <<5, _::16, rest::binary>> = elem(observation().payload, 1)

    {:ok, receipt} =
      Service.submit(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        import_request(
          %{id: "sample-" <> generation, payload: {:bytes, <<5, raw::16, rest::binary>>}},
          generation
        ),
        c.now
      )

    {:ok, _} =
      Service.associate(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{
          "thing_id" => thing,
          "observation_id" => receipt["data"]["observation_id"],
          "owner_confirmed" => true,
          "expected_generation" => Integer.to_string(number + 1)
        },
        c.now
      )

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => thing, "expected_generation" => Integer.to_string(number + 2)},
        c.now
      )
  end
end
