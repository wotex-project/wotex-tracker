defmodule Wotex.Tracker.Mobile.ClientTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.Mobile.{Cache, Client, CredentialManager}
  alias Wotex.Tracker.UI.Remote

  @now 1_000
  @scope "bikes"
  @token "private-mobile-token"

  defmodule Store do
    def fetch(key, agent) do
      Agent.get(agent, fn values ->
        case Map.fetch(values, key) do
          {:ok, value} -> {:ok, value}
          :error -> {:error, :not_found}
        end
      end)
    end

    def put(key, value, agent), do: Agent.update(agent, &Map.put(&1, key, value))
    def delete(key, agent), do: Agent.update(agent, &Map.delete(&1, key))
  end

  defmodule Transport do
    @behaviour Wotex.Tracker.UI.RemoteTransport

    @impl true
    def request(agent, _authority, request) do
      Agent.get_and_update(agent, fn state ->
        result = respond(state, request)
        {result, %{state | requests: [request | state.requests]}}
      end)
    end

    defp respond(%{mode: :offline}, _request), do: {:error, :offline}

    defp respond(%{mode: :unauthorized}, _request) do
      json(401, %{
        "schema" => "wtr.response.v1",
        "error" => %{"code" => "unauthorized"}
      })
    end

    defp respond(%{data: data}, request) do
      projection = if String.ends_with?(request.path, "/access"), do: access(), else: data
      json(200, %{"schema" => "wtr.response.v1", "data" => projection})
    end

    defp json(status, document),
      do: {:ok, status, [{"content-type", "application/json"}], Jason.encode!(document)}

    defp access do
      %{
        "schema" => "wtr.access.v1",
        "credential_id" => "phone",
        "principal" => "owner",
        "scope" => "bikes",
        "permissions" => ["read"],
        "expires_at" => 10_000
      }
    end
  end

  defmodule RaisingRegistry do
    def whereis_name(_), do: raise("private registry failure")
  end

  defmodule ThrowingRegistry do
    def whereis_name(_), do: throw(:private_registry_failure)
  end

  setup do
    directory = Path.expand("_build/test/mobile-client/#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf(directory) end)

    store = start_supervised!({Agent, fn -> %{} end})

    transport =
      start_supervised!(
        Supervisor.child_spec(
          {Agent, fn -> %{mode: :online, data: %{}, requests: []} end},
          id: :transport
        )
      )

    cache = start_supervised!({Cache, directory: directory})

    manager =
      start_supervised!(
        {CredentialManager,
         sessions: self(),
         cache: cache,
         origin: "https://service.example",
         secure_store: {Store, store},
         clock: fn -> @now end}
      )

    assert %{storage: :ready} = CredentialManager.status(manager)
    assert :ok = CredentialManager.retain(manager, credential())

    {:ok, remote} =
      Remote.new(origin: "https://service.example", transport: {Transport, transport})

    %{client: Client.new(remote, manager), manager: manager, transport: transport}
  end

  test "synchronizes each closed projection class and labels exact offline fallbacks", c do
    cases = [
      {:overview, :list, %{"resource" => "enrollments", "params" => %{}},
       %{"generation" => "1", "items" => [], "cursor" => "next"}},
      {:history, :history, %{"resource" => "state", "id" => "asset", "params" => %{}},
       %{"generation" => "2", "items" => [], "cursor" => nil}},
      {:dashboard, :analytics, %{"query" => %{"schema" => "wtr.query.v1"}},
       %{"identity" => "query-result", "series" => []}},
      {:map, :route_history, %{"request" => %{"schema" => "wtr.route-page-request.v1"}},
       %{"identity" => "route-page", "cursor" => nil}}
    ]

    for {kind, action, arguments, projection} <- cases do
      set(c.transport, :online, projection)
      assert {:ok, ^projection} = request(c.client, action, arguments, @now)
      set(c.transport, :offline, %{})

      assert {:ok, %{"_offline" => metadata} = cached} =
               request(c.client, action, arguments, @now + 1)

      assert Map.drop(cached, ["_offline"]) == projection
      assert metadata["source"] == "offline_cache"
      assert metadata["synchronized_at"] == @now
      assert metadata["age_ms"] == 1
      assert metadata["expires_at"] == 10_000
      assert metadata["complete"] == projection["cursor"] in [nil, false]
      assert kind in [:overview, :history, :dashboard, :map]
    end
  end

  test "uses conservative offline identity and never falls back for another key or mutation", c do
    page = %{"generation" => "1", "items" => [], "cursor" => nil}
    arguments = %{"resource" => "enrollments", "params" => %{}}
    set(c.transport, :online, page)
    assert {:ok, ^page} = request(c.client, :list, arguments)
    set(c.transport, :offline, %{})

    assert {:ok,
            %{
              "scope" => @scope,
              "can_enroll" => false,
              "can_ingest" => false,
              "can_read_raw" => false,
              "can_manage_queries" => false,
              "can_interact" => false,
              "_offline" => true
            }} = request(c.client, :authorize, %{})

    assert {:error, %{"code" => "storage_unavailable"}} =
             request(c.client, :list, %{
               "resource" => "enrollments",
               "params" => %{"cursor" => "other"}
             })

    operation = "00000000-0000-4000-8000-000000000000"

    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} =
             request(c.client, :submit, %{"operation" => operation, "request" => %{}})

    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} =
             request(c.client, :invoke_action, %{
               "thing" => "bike",
               "name" => "refresh",
               "operation" => operation,
               "request" => %{"expected_generation" => "4", "input" => 5}
             })

    assert {:error, %{"code" => "storage_unavailable"}} =
             request(c.client, :action_status, %{"operation" => operation})

    assert {:error, %{"code" => "storage_unavailable"}} =
             request(c.client, :raw_observation, %{"id" => "capture"})

    refute inspect(c.client) =~ @token
  end

  test "remote denial overrides an existing cache and invalid client input stays closed", c do
    page = %{"generation" => "1", "items" => [], "cursor" => nil}
    arguments = %{"resource" => "enrollments", "params" => %{}}
    set(c.transport, :online, page)
    assert {:ok, ^page} = request(c.client, :list, arguments)
    set(c.transport, :unauthorized, %{})

    assert {:error, %{"code" => "unauthorized"}} = request(c.client, :list, arguments)

    assert {:error, %{"code" => "invalid_request"}} =
             Client.request(:invalid, @token, @scope, :list, arguments, @now)
  end

  test "covers every declared overview and dashboard cache route", c do
    cases = [
      {:get, %{"resource" => "saved_queries", "id" => "query"}},
      {:thing_rules, %{"thing" => "bike"}}
    ]

    for {action, arguments} <- cases do
      projection = %{"identity" => Atom.to_string(action)}
      set(c.transport, :online, projection)
      assert {:ok, ^projection} = request(c.client, action, arguments)
      set(c.transport, :offline, %{})
      assert {:ok, %{"_offline" => _}} = request(c.client, action, arguments, @now + 2)
    end

    set(c.transport, :offline, %{})

    assert {:error, %{"code" => "storage_unavailable"}} =
             Client.request(c.client, @token, "other-scope", :authorize, %{}, @now + 1)
  end

  test "contains unavailable caches and credential callbacks", c do
    projection = %{"generation" => "1", "items" => [], "cursor" => nil}
    arguments = %{"resource" => "enrollments", "params" => %{}}
    assert :ok = stop_supervised(Cache)

    set(c.transport, :online, projection)
    assert {:ok, ^projection} = request(c.client, :list, arguments)
    set(c.transport, :offline, %{})

    assert {:error, %{"code" => "storage_unavailable"}} =
             request(c.client, :list, arguments)

    for registry <- [RaisingRegistry, ThrowingRegistry] do
      set(c.transport, :online, projection)
      client = %{c.client | credentials: {:via, registry, :missing}}

      assert {:error, %{"code" => "storage_unavailable"}} =
               request(client, :list, arguments)
    end
  end

  defp request(client, action, arguments, now \\ @now + 1) do
    Client.request(client, @token, @scope, action, arguments, now)
  end

  defp set(agent, mode, data), do: Agent.update(agent, &%{&1 | mode: mode, data: data})

  defp credential do
    %{
      token: @token,
      scope: @scope,
      access: %{
        "scope" => @scope,
        "credential_id" => "phone",
        "principal" => "owner",
        "expires_at" => 10_000
      },
      session_id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }
  end
end
