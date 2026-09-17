defmodule Wotex.Tracker.HTTPTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service.{Codec, RuleFixtures, Store}
  alias Wotex.Tracker.Service.HTTP.{Capacity, Server}

  test "an independent HTTP/SSE process executes the authenticated workflow" do
    context = service()
    server = start_supervised!({Server, options(context)})
    assert run_consumer(context, server, %{}) =~ "HTTP_CONSUMER_PASS"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
  end

  test "an independent HTTP process inspects persisted rule status" do
    context = service()
    RuleFixtures.commit_all(context.store, context.scope)
    server = start_supervised!({Server, options(context)})
    output = run_consumer(context, server, %{"mode" => "rules"})
    assert output =~ "HTTP_CONSUMER_PASS openapi=true rule_status=true alerts=true"
    assert {:ok, capacity} = Server.child(server, :capacity)
    assert_capacity_released(capacity)
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

  defp run_consumer(context, server, descriptor) do
    assert {:ok, {{127, 0, 0, 1}, port}} = Server.listener_info(server)
    path = Path.join(context.directory, "client.json")

    File.write!(
      path,
      Codec.encode!(
        Map.merge(descriptor, %{
          "url" => "http://127.0.0.1:#{port}",
          "token" => context.admin,
          "reader" => context.reader,
          "scope" => context.scope,
          "now" => context.now
        })
      )
    )

    File.chmod!(path, 0o600)
    elixir = System.find_executable("elixir") || flunk("Elixir executable is unavailable")
    code_paths = Enum.flat_map(:code.get_path(), fn value -> ["-pa", List.to_string(value)] end)
    script = Path.expand("../../scripts/http_consumer.exs")
    {output, status} = System.cmd(elixir, code_paths ++ [script, path], stderr_to_stdout: true)
    File.rm!(path)
    assert status == 0, output
    output
  end

  defp assert_capacity_released(capacity, attempts \\ 100) do
    case Capacity.counts(capacity) do
      %{requests: 0, streams: 0} ->
        :ok

      counts ->
        assert attempts > 0, "HTTP peer closure retained capacity: #{inspect(counts)}"
        Process.sleep(10)
        assert_capacity_released(capacity, attempts - 1)
    end
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
