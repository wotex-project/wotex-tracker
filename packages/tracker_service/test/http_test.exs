defmodule Wotex.Tracker.HTTPTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service.{Codec, Store}
  alias Wotex.Tracker.Service.HTTP.{Capacity, Server}

  test "an independent non-Elixir HTTP/SSE client executes the authenticated workflow" do
    context = service()
    server = start_supervised!({Server, options(context)})
    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    path = Path.join(context.directory, "client.json")

    File.write!(
      path,
      Codec.encode!(%{
        "url" => "http://127.0.0.1:#{port}",
        "token" => context.admin,
        "reader" => context.reader,
        "scope" => context.scope,
        "now" => context.now
      })
    )

    File.chmod!(path, 0o600)
    python = Path.expand("../../_build/openapi-venv/bin/python")
    script = Path.expand("../../scripts/http_consumer.py")

    assert File.exists?(python),
           "Install scripts/requirements-openapi.txt into _build/openapi-venv"

    {output, status} = System.cmd(python, [script, path], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "HTTP_CONSUMER_PASS"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert %{requests: 0, streams: 0} = Capacity.counts(capacity)
    File.rm!(path)
  end

  test "instances use distinct listeners and stores; invalid exposure and configuration fail closed" do
    first = service()
    second = service()
    a = start_supervised!(Supervisor.child_spec({Server, options(first)}, id: :a))
    b = start_supervised!(Supervisor.child_spec({Server, options(second)}, id: :b))
    assert {:ok, {_, port_a}} = Server.listener_info(a)
    assert {:ok, {_, port_b}} = Server.listener_info(b)
    refute port_a == port_b
    assert {:ok, store_a} = Server.child(a, :store)
    assert {:ok, store_b} = Server.child(b, :store)
    refute store_a == store_b
    assert {:ok, %{"writable" => true}} = Store.readiness(Store.handle(store_a))
    assert {:ok, %{"writable" => true}} = Store.readiness(Store.handle(store_b))

    for change <- [
          [ip: {0, 0, 0, 0}],
          [port: -1],
          [public_origin: "http://user:pass@example.test"],
          [exposure: :proxy, public_origin: "http://example.test"],
          [exposure: :tls],
          [request_timeout: 5001],
          [stream_lifetime: 300_001],
          [poll_interval: 0],
          [store_options: [fault: fn _ -> :ok end]],
          [unknown: true]
        ] do
      assert {:error, :invalid_configuration} =
               Server.start_link(Keyword.merge(options(first), change))
    end

    assert {:error, :invalid_configuration} = Server.start_link([])
    assert {:error, :invalid_configuration} = Server.start_link(nil)
  end

  defp options(context),
    do: [
      directory: context.directory,
      credentials: context.credentials,
      ip: {127, 0, 0, 1},
      port: 0,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> context.now end,
      poll_interval: 25
    ]
end
