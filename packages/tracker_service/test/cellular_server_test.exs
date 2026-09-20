defmodule Wotex.Tracker.Service.CellularServerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  import Bitwise, only: [bxor: 2]
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Protocols.Teltonika.{TAT140, TCPSession}
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Cellular.{Connection, Ingress, Server}

  @imei "123456789012345"
  @identity_key :binary.copy(<<7>>, 32)

  setup do
    context = service()
    frame = frame()
    server = start_server(context)
    {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    %{context: context, frame: frame, server: server, port: port}
  end

  test "an independent Erlang peer crosses every login and frame split", context do
    script = Path.expand("fixtures/teltonika_peer.escript", __DIR__)

    {output, 0} =
      System.cmd(
        "escript",
        [
          script,
          "127.0.0.1",
          Integer.to_string(context.port),
          @imei,
          Base.encode16(context.frame)
        ],
        stderr_to_stdout: true
      )

    assert output == "ok 103 cases\n"

    assert {:ok, %{"generation" => "1", "items" => [_]}} =
             observations(context.context)
  end

  test "unknown and malformed logins close without admitting a frame", context do
    unknown = connect(context.port)
    :ok = :gen_tcp.send(unknown, login("123456789012346"))
    assert {:ok, <<0>>} = :gen_tcp.recv(unknown, 1, 1_000)
    assert_closed(unknown)

    malformed = connect(context.port)
    :ok = :gen_tcp.send(malformed, <<0, 14, :binary.copy(<<?1>>, 14)::binary>>)
    assert_closed(malformed)

    assert {:ok, %{"generation" => "0", "items" => []}} = observations(context.context)
  end

  test "malformed, oversized and incomplete frames never receive an ACK", context do
    bad_crc = open_session(context.port)
    prefix_size = byte_size(context.frame) - 1
    <<prefix::binary-size(^prefix_size), last>> = context.frame
    :ok = :gen_tcp.send(bad_crc, <<prefix::binary, bxor(last, 1)>>)
    assert_closed(bad_crc)

    oversized = open_session(context.port)
    :ok = :gen_tcp.send(oversized, <<0::32, 1_281::32>>)
    assert_closed(oversized)

    incomplete = open_session(context.port)
    :ok = :gen_tcp.send(incomplete, binary_part(context.frame, 0, 20))
    :ok = :gen_tcp.close(incomplete)

    eventually(fn ->
      match?({:ok, %{"generation" => "0", "items" => []}}, observations(context.context))
    end)
  end

  test "connection loss before and after commit reconciles one durable observation", context do
    faulted = service(fault: fn phase -> if phase == :after_commit, do: :abort, else: :ok end)
    server = start_server(faulted)
    {:ok, {_, port}} = Server.listener_info(server)

    partial = open_session(port)
    :ok = :gen_tcp.send(partial, binary_part(context.frame, 0, 20))
    :ok = :gen_tcp.close(partial)

    eventually(fn ->
      match?({:ok, %{"generation" => "0"}}, observations(faulted))
    end)

    lost_ack = open_session(port)
    :ok = :gen_tcp.send(lost_ack, context.frame)
    assert_closed(lost_ack)

    eventually(fn ->
      match?({:ok, %{"generation" => "1", "items" => [_]}}, observations(faulted))
    end)

    retransmit = open_session(port)
    :ok = :gen_tcp.send(retransmit, context.frame)
    assert {:ok, <<0, 0, 0, 1>>} = :gen_tcp.recv(retransmit, 4, 1_000)
    :ok = :gen_tcp.close(retransmit)

    assert {:ok, %{"generation" => "1", "items" => [_]}} =
             observations(faulted)
  end

  test "absolute login and frame deadlines release the finite connection slot" do
    context = service()

    server =
      start_server(context,
        maximum_sessions: 1,
        login_timeout_ms: 50,
        frame_timeout_ms: 50
      )

    {:ok, {_, port}} = Server.listener_info(server)
    stalled = connect(port)
    overflow = connect(port)
    assert_closed(overflow)
    assert_closed(stalled)

    session = open_session(port)
    assert_closed(session)

    recovered = open_session(port)
    :ok = :gen_tcp.close(recovered)
  end

  test "configuration is explicit and bounded", context do
    base = server_options(context.context)

    invalid = [
      [],
      Keyword.delete(base, :ip),
      Keyword.put(base, :service, :invalid),
      Keyword.put(base, :identity_key, <<0>>),
      Keyword.put(base, :devices, []),
      Keyword.put(base, :ip, {127, 0, 0}),
      Keyword.put(base, :ip, {127, 0, 0, 256}),
      Keyword.put(base, :port, -1),
      Keyword.put(base, :login_timeout_ms, 0),
      Keyword.put(base, :frame_timeout_ms, 300_001),
      Keyword.put(base, :send_timeout_ms, :infinity),
      Keyword.put(base, :shutdown_timeout_ms, 0),
      Keyword.put(base, :maximum_sessions, 33),
      Keyword.put(base, :maximum_retries, 4),
      base ++ [unknown: true],
      base ++ [port: 0]
    ]

    for options <- invalid do
      assert {:error, :invalid_configuration} = Server.start_link(options)
    end

    assert {:error, :invalid_configuration} = Server.start_link(:invalid)
    assert {:ok, _server} = Server.start_link(Keyword.put(base, :ip, ipv6_loopback()))
  end

  test "listener discovery fails after shutdown", context do
    assert :ok = Supervisor.stop(context.server)
    assert {:error, :unavailable} = Server.listener_info(context.server)
  end

  test "transport error and shutdown callbacks release private sessions", context do
    {:ok, ingress} = Server.ingress(context.server)

    for callback <- [:handle_error, :handle_shutdown] do
      assert {:ok, session} = Ingress.login(ingress, @imei)
      state = %{ingress: ingress, session: session}

      case callback do
        :handle_error -> assert :ok = Connection.handle_error(:closed, nil, state)
        :handle_shutdown -> assert :ok = Connection.handle_shutdown(nil, state)
      end

      _ = :sys.get_state(ingress)
      assert {:error, :unauthorized} = Ingress.submit(ingress, session, %{})
    end
  end

  defp start_server(context, changes \\ []) do
    options = Keyword.merge(server_options(context), changes)

    start_supervised!(
      Supervisor.child_spec({Server, options}, id: make_ref(), restart: :temporary)
    )
  end

  defp server_options(context) do
    {:ok, identity_digest} = TCPSession.identity_digest(@imei, @identity_key)

    [
      service: context.service,
      identity_key: @identity_key,
      devices: [
        %{
          identity_digest: identity_digest,
          token: context.admin,
          scope: context.scope,
          id: "configured-tracker",
          profile: TAT140.configured_profile()
        }
      ],
      ip: {127, 0, 0, 1},
      port: 0,
      clock: fn -> context.now end,
      login_timeout_ms: 500,
      frame_timeout_ms: 500,
      send_timeout_ms: 500,
      shutdown_timeout_ms: 500
    ]
  end

  defp frame do
    {:ok, fixture} =
      Wotex.JSON.decode(File.read!("../../test/fixtures/teltonika/codec8_extended.json"))

    [vector] = fixture["vectors"]
    Base.decode16!(vector["hex"])
  end

  defp login(imei), do: <<byte_size(imei)::unsigned-big-16, imei::binary>>

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, nodelay: true], 1_000)

    socket
  end

  defp open_session(port) do
    socket = connect(port)
    :ok = :gen_tcp.send(socket, login(@imei))
    assert {:ok, <<1>>} = :gen_tcp.recv(socket, 1, 1_000)
    socket
  end

  defp assert_closed(socket) do
    assert {:error, reason} = :gen_tcp.recv(socket, 0, 1_000)
    assert reason in [:closed, :econnreset]
  end

  defp observations(context) do
    Service.list(
      context.service,
      context.admin,
      context.scope,
      "observations",
      %{"limit" => 10},
      context.now
    )
  end

  defp eventually(function, attempts \\ 100)
  defp eventually(function, 0), do: assert(function.())

  defp eventually(function, attempts) do
    if function.() do
      :ok
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  defp ipv6_loopback, do: {0, 0, 0, 0, 0, 0, 0, 1}
end
