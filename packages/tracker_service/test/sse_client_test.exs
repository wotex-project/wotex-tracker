defmodule Wotex.Tracker.SSEClientTest do
  use ExUnit.Case, async: true
  alias Wotex.Binding.HTTP.{Request, Response}
  alias Wotex.Binding.HTTP.SSE.Event
  alias Wotex.Tracker.Service.Credentials
  alias Wotex.Tracker.Service.HTTP.{LoopbackClient, SSEConnection}

  @headers "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"

  test "handshake rejects ambiguous media, encoding, status and excess headers and closes the socket" do
    for {wire, options} <- [
          {"HTTP/1.1 302 Found\r\nLocation: http://example.test/\r\n\r\n", []},
          {"HTTP/1.1 100 Continue\r\n\r\n", []},
          {"HTTP/1.1 200 OK\r\n\r\n", []},
          {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n", []},
          {String.replace(@headers, "\r\n\r\n", "\r\nContent-Encoding: gzip\r\n\r\n"), []},
          {String.replace(@headers, "\r\n\r\n", "\r\nContent-Type: text/event-stream\r\n\r\n"),
           []},
          {String.replace(
             @headers,
             "\r\n\r\n",
             "\r\nContent-Encoding: identity\r\nContent-Encoding: identity\r\n\r\n"
           ), []},
          {String.replace(@headers, "\r\n\r\n", "\r\nX-Extra: one\r\n\r\n"),
           [max_header_count: 1]},
          {String.replace(
             @headers,
             "\r\n\r\n",
             "\r\nX-Long: " <> String.duplicate("x", 100) <> "\r\n\r\n"
           ), [max_header_bytes: 32]},
          {"HTTP/1.1 " <> String.duplicate("x", 100), [max_header_bytes: 32]}
        ] do
      {config, peer} = peer(wire)
      credential = Credentials.generate_token()
      result = LoopbackClient.subscribe(request(config, options), credential, self(), config)
      assert {:error, :request_failed} = result
      assert_closed(peer)
      refute :erlang.term_to_binary(result) =~ credential
    end
  end

  test "pending headers have a deadline and owner or caller death releases them immediately" do
    {config, peer} = peer("HTTP/1.1 200 OK\r\n")
    assert {:error, :timeout} = open(config, self(), deadline: deadline(200))
    assert_closed(peer)

    for participant <- [:owner, :caller] do
      {config, peer} = peer("HTTP/1.1 200 OK\r\n")
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      parent = self()
      caller = spawn(fn -> send(parent, {:result, open(config, owner)}) end)
      assert_receive {:accepted, peer_pid}, 1000
      assert peer_pid == peer.pid
      Process.exit(if(participant == :owner, do: owner, else: caller), :kill)
      assert :closed = Task.await(peer, 1000)
      if participant == :owner, do: assert_receive({:result, {:error, :request_failed}}, 1000)
      Process.exit(owner, :kill)
    end
  end

  test "expired deadlines and dead owners allocate no connection" do
    {:ok, config} = LoopbackClient.new("http://127.0.0.1:1", "workshop")
    assert {:error, :timeout} = open(config, self(), deadline: deadline(-1))

    assert {:error, :timeout} =
             open(config, self(), deadline: DateTime.add(DateTime.utc_now(), -1))

    owner = spawn(fn -> :ok end)
    monitor = Process.monitor(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    assert {:error, :request_failed} = open(config, owner)
    assert {:error, :request_failed} = open(config, self())
    assert {:error, :request_failed} = LoopbackClient.subscribe(nil, "invalid", nil, config)
  end

  test "each handle closes only its own connection, without credentials in reader state" do
    {config, peer} = peer(@headers <> "id: one\nevent: property\ndata: 24.3\n\n")
    credential = Credentials.generate_token()

    assert {:ok, handle, %Response{status: 200, body: ""}} =
             LoopbackClient.subscribe(request(config, []), credential, self(), config)

    assert_receive {:wotex_transport_frame, %Event{data: "24.3", id: "one"}}, 1000
    {SSEConnection, {pid, _reference}, origin, scope} = handle
    refute :erlang.term_to_binary(:sys.get_state(pid)) =~ credential
    refute inspect(:sys.get_status(pid)) =~ credential
    send(pid, :unrelated)
    wrong = {SSEConnection, {pid, make_ref()}, origin, scope}
    assert {:error, :request_failed} = LoopbackClient.close(wrong, config)
    assert {:error, :request_failed} = LoopbackClient.close(handle, %{config | scope: "other"})
    assert {:error, :request_failed} = LoopbackClient.close(handle, nil)
    assert {:error, :request_failed} = SSEConnection.close(:invalid)
    assert Process.alive?(pid)
    monitor = Process.monitor(pid)
    assert :ok = LoopbackClient.close(handle, config)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
    assert_closed(peer)
    assert :ok = LoopbackClient.close(handle, config)
  end

  test "stream lifetime, invalid frames, exhausted body and broken transport close owned readers" do
    for {wire, options, action} <- [
          {@headers, [deadline: deadline(500)], :wait},
          {@headers, [max_event_bytes: 8], "data: 1\n\n"},
          {@headers, [], "data: " <> <<255>> <> "\n\n"},
          {@headers, [], :disconnect},
          {String.replace(@headers, "\r\n\r\n", "\r\nContent-Length: 0\r\n\r\n"), [], :wait}
        ] do
      {config, peer} = peer(wire, action)
      assert {:ok, handle, _} = open(config, self(), options)
      {SSEConnection, {pid, _}, _, _} = handle
      monitor = Process.monitor(pid)
      send(peer.pid, :release)
      assert_receive {:wotex_transport_status, :transport_down}, 1500
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1000
      assert_closed(peer)
    end
  end

  test "owner mailbox pressure stops a stream instead of accumulating unbounded frames" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    for _ <- 1..32, do: send(owner, :backlog)
    {config, peer} = peer(@headers, "data: 1\n\n")
    assert {:ok, handle, _} = open(config, owner)
    {SSEConnection, {pid, _}, _, _} = handle
    monitor = Process.monitor(pid)
    send(peer.pid, :release)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1000
    assert_closed(peer)
    assert {:message_queue_len, 33} = Process.info(owner, :message_queue_len)
    send(owner, :stop)
  end

  defp open(config, owner, options \\ []),
    do:
      LoopbackClient.subscribe(
        request(config, options),
        Credentials.generate_token(),
        owner,
        config
      )

  defp request(config, options) do
    {:ok, request} =
      Request.new(
        "GET",
        config.origin <> "/api/v1/scopes/workshop/things/a/properties/b/observe",
        [{"accept", "text/event-stream"}],
        nil,
        Keyword.merge(
          [
            request_id: "peer",
            operation: :observeproperty,
            stream?: true,
            max_response_bytes: 1024,
            max_event_bytes: 1024
          ],
          options
        )
      )

    request
  end

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  defp assert_closed(peer) do
    assert_receive {:accepted, peer_pid}, 1000
    assert peer_pid == peer.pid
    assert :closed = Task.await(peer, 2000)
  end

  defp peer(wire, action \\ :immediate) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2000)
        send(parent, {:accepted, self()})

        case :gen_tcp.send(socket, wire) do
          :ok -> :ok
          {:error, :closed} -> :ok
        end

        if action != :immediate do
          receive do: (:release -> :ok)
        end

        case action do
          bytes when is_binary(bytes) -> :gen_tcp.send(socket, bytes)
          :disconnect -> :gen_tcp.close(socket)
          _ -> :ok
        end

        result = :gen_tcp.recv(socket, 0, 3000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)

        case result do
          {:error, :closed} -> :closed
          other -> other
        end
      end)

    {:ok, config} = LoopbackClient.new("http://127.0.0.1:#{port}", "workshop")
    {config, peer}
  end
end
