defmodule Wotex.Tracker.LoopbackClientTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Binding.HTTP.{Request, Response}
  alias Wotex.Tracker.Service.Credentials
  alias Wotex.Tracker.Service.HTTP.LoopbackClient

  test "only an explicit numeric loopback origin and finite scoped Property read are admitted" do
    assert {:ok, _} = LoopbackClient.new("http://[::1]:12345", "workshop")

    for origin <- [
          nil,
          "",
          "http://localhost",
          "http://127.0.0.2",
          "https://127.0.0.1",
          "http://127.0.0.1:0",
          "http://127.0.0.1/path",
          "http://127.0.0.1?query",
          "http://127.0.0.1#fragment",
          "http://user:password@127.0.0.1"
        ] do
      assert {:error, :invalid_configuration} = LoopbackClient.new(origin, "workshop")
    end

    assert {:error, :invalid_configuration} = LoopbackClient.new("http://127.0.0.1", "")
    {:ok, config} = LoopbackClient.new("http://127.0.0.1:1", "workshop")
    credential = Credentials.generate_token()
    request = request(config)

    for change <- [
          %{uri: "http://127.0.0.1:2/api/v1/scopes/workshop/things/a/properties/b"},
          %{uri: "http://127.0.0.1:1/api/v1/scopes/other/things/a/properties/b"},
          %{uri: config.origin <> "/api/v1/scopes/workshop/things/a/properties/"},
          %{uri: request.uri <> "?secret=value"},
          %{method: "POST"},
          %{stream?: true},
          %{body: "1"},
          %{operation: :invokeaction},
          %{headers: [{"authorization", "secret"}]}
        ] do
      assert {:error, :request_failed} =
               LoopbackClient.request(struct(request, change), credential, config)
    end

    assert {:error, :request_failed} = LoopbackClient.request(request, "invalid", config)
    assert {:error, :request_failed} = LoopbackClient.request(nil, credential, config)

    assert {:error, :request_failed} =
             LoopbackClient.subscribe(request, credential, self(), config)

    assert {:error, :request_failed} = LoopbackClient.close(:unknown, config)
    assert {:error, :request_failed} = LoopbackClient.request(request, credential, config)

    assert {:error, :timeout} =
             LoopbackClient.request(
               %{request | deadline: System.monotonic_time(:millisecond) - 1},
               credential,
               config
             )

    assert {:error, :timeout} =
             LoopbackClient.request(
               %{request | deadline: DateTime.add(DateTime.utc_now(), -1)},
               credential,
               config
             )
  end

  test "framing, fields and bodies are bounded before response decoding; every socket closes" do
    for {wire, options, expected} <- [
          {"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n24.3",
           [], {:ok, 200, "24.3"}},
          {"HTTP/1.1 302 Found\r\nLocation: http://example.test/\r\nContent-Length: 0\r\n\r\n",
           [], {:ok, 302, ""}},
          {"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n24\r\n2\r\n.3\r\n0\r\n\r\n",
           [], {:ok, 200, "24.3"}},
          {"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n24.3", [max_response_bytes: 3],
           {:error, :response_rejected}},
          {"HTTP/1.1 200 OK\r\nX-A: one\r\nX-B: two\r\nContent-Length: 0\r\n\r\n",
           [max_header_count: 1], {:error, :response_rejected}},
          {"HTTP/1.1 200 OK\r\nX-Long: " <> String.duplicate("a", 100) <> "\r\n\r\n",
           [max_header_bytes: 32], {:error, :request_failed}},
          {"HTTP/1.1 " <> String.duplicate("x", 100), [max_header_bytes: 32],
           {:error, :request_failed}},
          {"HTTP/1.1 100 Continue\r\n\r\n", [], {:error, :response_rejected}},
          {"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n1",
           [deadline: System.monotonic_time(:millisecond) + 500], {:error, :timeout}}
        ] do
      {config, peer} = peer(wire)
      credential = Credentials.generate_token()
      result = LoopbackClient.request(request(config, options), credential, config)

      case expected do
        {:ok, status, body} -> assert {:ok, %Response{status: ^status, body: ^body}} = result
        error -> assert result == error
      end

      assert :closed = Task.await(peer)
      refute :erlang.term_to_binary(result) =~ credential
    end
  end

  test "caller death releases a pending connection without a connection process or retry" do
    {config, peer} = peer("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:started, self()})
        LoopbackClient.request(request(config), Credentials.generate_token(), config)
      end)

    assert_receive {:started, ^caller}
    assert_receive {:accepted, _}, 1000
    Process.exit(caller, :kill)
    assert :closed = Task.await(peer)
  end

  defp request(config, options \\ []) do
    {:ok, request} =
      Request.new(
        "GET",
        config.origin <> "/api/v1/scopes/workshop/things/a/properties/b",
        [{"accept", "application/json"}],
        nil,
        Keyword.merge(
          [
            request_id: "peer",
            operation: :readproperty,
            max_response_bytes: 1024,
            max_event_bytes: 1024
          ],
          options
        )
      )

    request
  end

  defp peer(wire) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2000)
        send(parent, {:accepted, self()})
        :ok = :gen_tcp.send(socket, wire)
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
