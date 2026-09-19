defmodule Wotex.Tracker.Mobile.CredentialManagerTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.Mobile.{Cache, CredentialManager}
  alias Wotex.Tracker.UI.Sessions

  @now 1_000
  @origin "https://service.example"

  defmodule Store do
    def fetch(key, agent) do
      Agent.get(agent, fn state ->
        case {failed?(state, :fetch), Map.fetch(state.values, key)} do
          {true, _} -> {:error, :unavailable}
          {false, {:ok, value}} -> {:ok, value}
          {false, :error} -> {:error, :not_found}
        end
      end)
    end

    def put(key, value, agent) do
      Agent.get_and_update(agent, fn state ->
        if failed?(state, :put) do
          {{:error, :unavailable}, state}
        else
          {:ok, put_in(state.values[key], value)}
        end
      end)
    end

    def delete(key, agent) do
      Agent.get_and_update(agent, fn state ->
        if failed?(state, :delete) do
          {{:error, :unavailable}, state}
        else
          {:ok, update_in(state.values, &Map.delete(&1, key))}
        end
      end)
    end

    defp failed?(state, operation), do: state.failure in [:all, operation]
  end

  defmodule Client do
    @behaviour Wotex.Tracker.UI.Client

    @impl true
    def request(agent, token, scope, :session_context, %{}, _now) do
      Agent.get_and_update(agent, fn state ->
        result =
          case state.mode do
            :ok ->
              {:ok,
               %{
                 "identity" => %{"scope" => scope},
                 "access" => access(scope)
               }}

            :offline ->
              {:error, %{"code" => "storage_unavailable"}}

            :unauthorized ->
              {:error, %{"code" => "unauthorized"}}

            {:reply, reply} ->
              reply
          end

        {result, %{state | calls: [{token, scope} | state.calls]}}
      end)
    end

    def request(_, _, _, _, _, _), do: {:error, %{"code" => "unsupported"}}

    defp access(scope) do
      %{
        "scope" => scope,
        "credential_id" => "phone",
        "principal" => "owner",
        "expires_at" => 10_000
      }
    end
  end

  defmodule RaisingStore do
    def fetch(_, _), do: raise("private secure-store failure")
    def put(_, _, _), do: raise("private secure-store failure")
    def delete(_, _), do: raise("private secure-store failure")
  end

  defmodule ThrowingStore do
    def fetch(_, _), do: throw(:private_secure_store_failure)
    def put(_, _, _), do: throw(:private_secure_store_failure)
    def delete(_, _), do: throw(:private_secure_store_failure)
  end

  setup do
    directory =
      Path.expand("_build/test/credential-manager/#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf(directory) end)

    store = start_supervised!({Agent, fn -> %{values: %{}, failure: nil} end})

    client =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> %{mode: :ok, calls: []} end}, id: :client)
      )

    cache = start_supervised!({Cache, directory: directory})

    sessions =
      start_supervised!({Sessions, client: {Client, client}, clock: fn -> @now end, capacity: 8})

    %{cache: cache, client: client, directory: directory, sessions: sessions, store: store}
  end

  test "retains one bounded credential, binds its account and clears both atomically", c do
    manager = start_manager(c)
    credential = credential("retained-token")

    assert %{credential: false, session: false, storage: :ready} =
             CredentialManager.status(manager)

    assert :ok = CredentialManager.retain(manager, credential)
    assert {:ok, browser_session} = CredentialManager.browser_session(manager)
    assert canonical_id?(browser_session)
    assert %{credential: true, session: true, storage: :ready} = CredentialManager.status(manager)

    values = Agent.get(c.store, & &1.values)

    assert %{"schema" => "wtr.mobile-credential.v1", "token" => "retained-token"} =
             Jason.decode!(values.credential)

    account = account(values.installation_id)
    assert {:ok, %{"entries" => 0, "expires_at" => 10_000}} = Cache.status(c.cache, account, @now)

    inspected = inspect(:sys.get_status(manager))
    refute inspected =~ "retained-token"
    refute inspected =~ values.credential

    assert :ok = CredentialManager.release(manager, credential)

    assert %{credential: false, session: false, storage: :ready} =
             CredentialManager.status(manager)

    refute Map.has_key?(Agent.get(c.store, & &1.values), :credential)
    assert {:error, :account_mismatch} = Cache.status(c.cache, account, @now)
  end

  test "restores after restart, preserves offline cache binding and clears revoked access", c do
    manager = start_manager(c)
    credential = credential("restart-token")
    assert :ok = CredentialManager.retain(manager, credential)
    installation = Agent.get(c.store, & &1.values.installation_id)
    assert :ok = stop_supervised(CredentialManager)

    Agent.update(c.client, &%{&1 | mode: :offline})
    manager = start_manager(c)

    assert %{credential: true, session: false, storage: :ready} =
             CredentialManager.status(manager)

    assert {:ok, %{"entries" => 0}} = Cache.status(c.cache, account(installation), @now)
    assert :none = CredentialManager.browser_session(manager)

    Agent.update(c.client, &%{&1 | mode: :ok})
    assert {:ok, restored} = CredentialManager.browser_session(manager)
    assert restored != credential.session_id
    assert canonical_id?(restored)
    assert :ok = stop_supervised(CredentialManager)

    Agent.update(c.client, &%{&1 | mode: :unauthorized})
    manager = start_manager(c)

    assert %{credential: false, session: false, storage: :ready} =
             CredentialManager.status(manager)

    refute Map.has_key?(Agent.get(c.store, & &1.values), :credential)
    assert {:error, :account_mismatch} = Cache.status(c.cache, account(installation), @now)
  end

  test "purges corrupt, expired and foreign-origin secure envelopes", c do
    manager = start_manager(c)
    assert %{storage: :ready} = CredentialManager.status(manager)
    installation = Agent.get(c.store, & &1.values.installation_id)
    assert :ok = stop_supervised(CredentialManager)

    envelopes = [
      "not-json",
      Jason.encode!(envelope(%{"expires_at" => @now})),
      Jason.encode!(envelope(%{"origin" => "https://other.example"})),
      Jason.encode!(Map.put(envelope(), "unexpected", true))
    ]

    for encoded <- envelopes do
      Agent.update(c.store, &put_in(&1.values[:credential], encoded))
      manager = start_manager(c)

      assert %{credential: false, session: false} = CredentialManager.status(manager)
      refute Map.has_key?(Agent.get(c.store, & &1.values), :credential)
      assert {:error, :account_mismatch} = Cache.status(c.cache, account(installation), @now)
      assert :ok = stop_supervised(CredentialManager)
    end
  end

  test "contains secure-store and dead-cache failures without issuing a session", c do
    manager = start_manager(c)
    credential = credential("failure-token")
    Agent.update(c.store, &%{&1 | failure: :put})

    assert {:error, :unavailable} = CredentialManager.retain(manager, credential)

    assert %{credential: false, session: false, storage: :unavailable} =
             CredentialManager.status(manager)

    Agent.update(c.store, &%{&1 | failure: nil})
    assert :ok = CredentialManager.retain(manager, credential)
    Agent.update(c.store, &%{&1 | failure: :delete})

    assert {:error, :unavailable} = CredentialManager.release(manager, credential)

    assert %{credential: true, session: true, storage: :unavailable} =
             CredentialManager.status(manager)

    Agent.update(c.store, &%{&1 | failure: nil})
    assert :ok = CredentialManager.release(manager, credential)
    assert :ok = stop_supervised(Cache)

    assert {:error, :unavailable} =
             CredentialManager.retain(manager, credential("cache-failure-token"))

    assert Process.alive?(manager)
    refute Map.has_key?(Agent.get(c.store, & &1.values), :credential)
  end

  test "contains startup, restoration and secure-store callback failures", c do
    Agent.update(c.store, &%{&1 | failure: :fetch})
    manager = start_manager(c)
    assert %{storage: :unavailable} = CredentialManager.status(manager)
    assert :ok = stop_supervised(CredentialManager)

    Agent.update(c.store, fn state -> %{state | failure: :put, values: %{}} end)
    manager = start_manager(c)
    assert %{storage: :unavailable} = CredentialManager.status(manager)
    assert :ok = stop_supervised(CredentialManager)

    for module <- [RaisingStore, ThrowingStore] do
      manager = start_manager(c, secure_store: {module, nil})
      assert %{storage: :unavailable} = CredentialManager.status(manager)
      assert :ok = stop_supervised(CredentialManager)
    end

    Agent.update(c.store, fn state -> %{state | failure: nil, values: %{}} end)
    manager = start_manager(c)
    assert :ok = CredentialManager.retain(manager, credential("restore-write-failure"))
    assert :ok = stop_supervised(CredentialManager)
    Agent.update(c.store, &%{&1 | failure: :put})
    manager = start_manager(c)

    assert %{credential: false, session: false, storage: :unavailable} =
             CredentialManager.status(manager)

    refute Map.has_key?(Agent.get(c.store, & &1.values), :credential)
  end

  test "rotates malformed installation identity and contains cleanup failures", c do
    Agent.update(c.store, &put_in(&1.values[:installation_id], "%%%"))
    manager = start_manager(c)
    assert %{storage: :ready} = CredentialManager.status(manager)

    replacement = Agent.get(c.store, & &1.values.installation_id)
    assert replacement != "%%%"
    assert canonical_id?(replacement)
    assert :ok = stop_supervised(CredentialManager)

    Agent.update(c.store, fn state ->
      state
      |> put_in([:values, :credential], "not-json")
      |> Map.put(:failure, :delete)
    end)

    manager = start_manager(c)
    assert %{storage: :unavailable} = CredentialManager.status(manager)
    assert :ok = stop_supervised(CredentialManager)

    Agent.update(c.store, fn state -> %{state | failure: nil, values: %{}} end)
    assert :ok = stop_supervised(Cache)
    manager = start_manager(c)

    assert %{credential: false, session: false, storage: :unavailable} =
             CredentialManager.status(manager)
  end

  test "rejects malformed configuration and credentials", c do
    for options <- [
          nil,
          [],
          [sessions: c.sessions, cache: c.cache, origin: @origin, secure_store: {Store, c.store}],
          manager_options(c) ++ [unexpected: true],
          Keyword.put(manager_options(c), :origin, "http://service.example"),
          Keyword.put(manager_options(c), :secure_store, {String, nil}),
          Keyword.put(manager_options(c), :clock, :invalid)
        ] do
      assert {:error, :invalid_configuration} = CredentialManager.start_link(options)
    end

    manager = start_manager(c)

    for malformed <- [
          %{},
          %{credential("token") | session_id: "not-canonical"},
          %{credential("token") | token: String.duplicate("x", 257)},
          put_in(credential("token"), [:access, "expires_at"], @now),
          put_in(credential("token"), [:access, "scope"], "other"),
          put_in(credential("token"), [:access, "expires_at"], 9_007_199_254_740_992),
          %{credential("token") | access: %{}}
        ] do
      assert {:error, :unavailable} = CredentialManager.retain(manager, malformed)
    end

    assert :none = CredentialManager.browser_session(:missing_manager)
    assert %{storage: :unavailable} = CredentialManager.status(:missing_manager)
    assert {:error, :unavailable} = CredentialManager.retain(:missing_manager, credential("x"))
  end

  defp start_manager(c) do
    start_manager(c, [])
  end

  defp start_manager(c, overrides) do
    start_supervised!({CredentialManager, Keyword.merge(manager_options(c), overrides)})
  end

  defp manager_options(c) do
    [
      sessions: c.sessions,
      cache: c.cache,
      origin: @origin,
      secure_store: {Store, c.store},
      clock: fn -> @now end
    ]
  end

  defp credential(token) do
    %{
      token: token,
      scope: "bikes",
      access: access(),
      session_id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }
  end

  defp access do
    %{
      "scope" => "bikes",
      "credential_id" => "phone",
      "principal" => "owner",
      "expires_at" => 10_000
    }
  end

  defp envelope(overrides \\ %{}) do
    Map.merge(
      Map.merge(access(), %{
        "schema" => "wtr.mobile-credential.v1",
        "origin" => @origin,
        "token" => "stored-token"
      }),
      overrides
    )
  end

  defp account(installation) do
    Map.merge(access(), %{
      "schema" => "wtr.mobile-account.v1",
      "origin" => @origin,
      "installation_id" => installation
    })
  end

  defp canonical_id?(id) do
    match?({:ok, <<_::256>>}, Base.url_decode64(id, padding: false))
  end
end
