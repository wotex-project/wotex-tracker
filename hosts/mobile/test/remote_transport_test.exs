defmodule Wotex.Tracker.Mobile.RemoteTransportTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.Mobile.{DNS, RemoteTransport}

  defmodule Resolver do
    def resolve(agent, host) do
      Agent.get_and_update(agent, fn state ->
        {state.result, %{state | hosts: [host | state.hosts]}}
      end)
    end
  end

  defmodule Transport do
    def request(agent, authority, request) do
      Agent.update(agent, &Map.put(&1, :request, {authority, request}))

      case Agent.get(agent, & &1.transport_result) do
        :raise -> raise "private transport failure"
        result -> result
      end
    end
  end

  defmodule ResolverOutcomes do
    def resolve("address"), do: {:ok, {127, 0, 0, 1}}
    def resolve("missing"), do: {:error, :nxdomain}
    def resolve("unsupported"), do: :unsupported
    def resolve("tuple"), do: {:unexpected, :value}
    def resolve("raise"), do: raise("resolver failure")
    def resolve("throw"), do: throw(:resolver_failure)
  end

  test "resolves a hostname before preserving the exact transport request" do
    agent = start_supervised!({Agent, fn -> state() end})
    context = context(agent)
    authority = %{scheme: :https, host: "service.example", port: 443}
    request = %{method: "GET", path: "/fixed", headers: [], body: "", timeout_ms: 1_000}

    assert {:ok, 200, [], "ok"} = RemoteTransport.request(context, authority, request)
    assert ["service.example"] = Agent.get(agent, & &1.hosts)
    assert {^authority, ^request} = Agent.get(agent, & &1.request)
  end

  test "numeric authorities skip DNS while resolver and transport failures are contained" do
    agent = start_supervised!({Agent, fn -> state() end})
    request = %{method: "GET", path: "/", headers: [], body: "", timeout_ms: 100}
    numeric = %{scheme: :https, host: "127.0.0.1", port: 443}

    assert {:ok, 200, [], "ok"} = RemoteTransport.request(context(agent), numeric, request)
    assert [] = Agent.get(agent, & &1.hosts)

    Agent.update(agent, &%{&1 | result: {:error, :nxdomain}, request: nil})

    assert {:error, :unavailable} =
             RemoteTransport.request(
               context(agent),
               %{numeric | host: "missing.example"},
               request
             )

    assert is_nil(Agent.get(agent, & &1.request))

    Agent.update(agent, &%{&1 | result: :ok, transport_result: :raise})

    assert {:error, :unavailable} =
             RemoteTransport.request(
               context(agent),
               %{numeric | host: "service.example"},
               request
             )

    assert {:error, :unavailable} = RemoteTransport.request(%{}, numeric, request)
    assert {:error, :unavailable} = RemoteTransport.request(context(agent), %{}, request)

    missing_resolver = put_in(context(agent), [:resolver], {__MODULE__.MissingResolver, nil})

    assert {:error, :unavailable} =
             RemoteTransport.request(
               missing_resolver,
               %{numeric | host: "service.example"},
               request
             )
  end

  test "contains every device resolver outcome" do
    assert :ok = DNS.resolve(nil, "localhost")
    assert :ok = DNS.resolve(ResolverOutcomes, "address")
    assert {:error, :nxdomain} = DNS.resolve(ResolverOutcomes, "missing")
    assert {:error, :resolver_unavailable} = DNS.resolve(ResolverOutcomes, "unsupported")
    assert {:error, :resolver_unavailable} = DNS.resolve(ResolverOutcomes, "tuple")
    assert {:error, :resolver_unavailable} = DNS.resolve(ResolverOutcomes, "raise")
    assert {:error, :resolver_unavailable} = DNS.resolve(ResolverOutcomes, "throw")
  end

  defp state do
    %{result: :ok, hosts: [], request: nil, transport_result: {:ok, 200, [], "ok"}}
  end

  defp context(agent) do
    %{resolver: {Resolver, agent}, transport: {Transport, agent}}
  end
end
