defmodule Wotex.Tracker.Service.AuthorityTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service.{Codec, Credentials, Store, Update}

  setup do
    now = 1_700_000_000_000
    {admin, admin_entry} = entry("admin", ~w(read raw ingest enroll admin), now)
    {ingress, ingress_entry} = entry("ingress", ~w(read ingest), now)
    {viewer, viewer_entry} = entry("viewer", ~w(read), now)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "server",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [admin_entry, ingress_entry, viewer_entry]
      })

    {:ok, admin_access} = Credentials.authenticate(credentials, admin, "workshop", "admin", now)
    {:ok, access} = Credentials.authenticate(credentials, ingress, "workshop", "ingest", now)
    {:ok, viewer_access} = Credentials.authenticate(credentials, viewer, "workshop", "read", now)
    {store, directory} = store(credentials: credentials)

    %{
      store: store,
      directory: directory,
      credentials: credentials,
      admin: admin_access,
      access: access,
      viewer: viewer_access,
      ingress: ingress,
      now: now
    }
  end

  test "configured stores require current authority inside commit and read transactions",
       context do
    assert {:error, :unauthorized} = Store.mutate(context.store, update())

    assert {:error, :forbidden} =
             Store.mutate(context.store, update(%{authority: context.viewer}))

    assert {:error, :unauthorized} =
             Store.mutate(
               context.store,
               update(%{authority: context.access, principal: "someone-else"})
             )

    assert {:ok, _} = Store.mutate(context.store, update(%{authority: context.access}))
    assert :ok = Store.authorized(context.store, context.access, "read", context.now)

    assert {:error, :forbidden} =
             Store.authorized(context.store, context.access, "raw", context.now)

    assert {:error, :unauthorized} = Store.authorized(context.store, nil, "read", context.now)

    assert {:ok, %{"items" => [_]}} =
             Store.authorized_snapshot(
               context.store,
               context.access,
               "read",
               query(),
               context.now
             )

    assert {:error, :unauthorized} =
             Store.authorized_snapshot(
               context.store,
               context.access,
               "read",
               query(%{scope: "other"}),
               context.now
             )

    assert {:ok, %{"items" => [_]}} =
             Store.authorized_events(context.store, context.access, replay())

    assert {:error, :invalid_update} = Update.new(update_input(%{authority: %{}}))
    {unconfigured, _} = store()

    assert {:error, :unauthorized} =
             Store.mutate(unconfigured, update(%{authority: context.access}))

    assert {:error, {:invalid_options, _}} =
             start_supervised({Store, directory: directory(), credentials: %{}})
  end

  test "revocation survives restart and rejects replay, historical reads and existing stream deliveries",
       context do
    assert {:ok, _} = Store.mutate(context.store, update(%{authority: context.access}))

    revoke =
      update(%{
        authority: context.admin,
        observation: nil,
        operation_id: "revoke",
        expected_generation: "1",
        records: [%{kind: "access", id: "ingress", value: %{"revoked" => true}}],
        events: [%{"type" => "access.revoked", "data" => %{"credential_id" => "ingress"}}]
      })

    assert {:ok, %{"generation" => "2"}} = Store.mutate(context.store, revoke)

    assert {:error, :unauthorized} =
             Store.authorized(context.store, context.access, "read", context.now)

    assert {:error, :unauthorized} =
             Store.authorized_snapshot(
               context.store,
               context.access,
               "read",
               query(%{generation: "1"}),
               context.now
             )

    assert {:error, :unauthorized} =
             Store.authorized_events(context.store, context.access, replay(%{after: "1"}))

    assert {:error, :unauthorized} =
             Store.mutate(context.store, update(%{authority: context.access}))

    GenServer.stop(context.store.pid)
    {reopened, _} = store(directory: context.directory, credentials: context.credentials)

    assert {:error, :unauthorized} =
             Store.authorized(reopened, context.access, "read", context.now)

    {:ok, other_scope} =
      Credentials.authenticate(context.credentials, context.ingress, "other", "read", context.now)

    assert :ok = Store.authorized(reopened, other_scope, "read", context.now)
    assert :ok = Store.authorized(reopened, context.admin, "read", context.now)
  end

  test "ingress cannot escalate through prepared record kinds, publication intents or event-only mutations",
       context do
    for kind <- ~w(access enrollments things policies saved_queries) do
      update =
        update(%{
          authority: context.access,
          observation: nil,
          records: [%{kind: kind, id: "target", value: %{}}]
        })

      assert {:error, :forbidden} = Store.mutate(context.store, update)
    end

    assert {:error, :forbidden} =
             Store.mutate(
               context.store,
               update(%{authority: context.access, observation: nil, records: []})
             )

    td = "../../test/fixtures/ruuvi/ordinary.td.json" |> File.read!() |> Codec.decode!()

    assert {:error, :forbidden} =
             Store.mutate(
               context.store,
               update(%{
                 authority: context.access,
                 publication: %{thing_id: td["id"], deployment_id: "1", td: td}
               })
             )

    assert {:ok, _} =
             Store.mutate(
               context.store,
               update(%{
                 authority: context.admin,
                 publication: %{thing_id: td["id"], deployment_id: "1", td: td}
               })
             )
  end

  test "a second writer cannot admit a revoked proof even when it was authenticated before revocation",
       context do
    {second, _} = store(directory: context.directory, credentials: context.credentials)
    assert :ok = Store.authorized(second, context.access, "ingest", context.now)

    revoke =
      update(%{
        authority: context.admin,
        observation: nil,
        records: [%{kind: "access", id: "ingress", value: %{"revoked" => true}}]
      })

    assert {:ok, _} = Store.mutate(context.store, revoke)

    assert {:error, :unauthorized} =
             Store.mutate(
               second,
               update(%{
                 authority: context.access,
                 expected_generation: "1",
                 operation_id: "late"
               })
             )

    assert {:error, :not_found} =
             Store.operation(second, "workshop", "operator", "late", context.now)
  end

  defp entry(id, permissions, now) do
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    {token,
     %{
       id: id,
       principal: "operator",
       token_sha256: digest,
       grants: %{"workshop" => permissions, "other" => permissions},
       expires_at: now + 10_000
     }}
  end
end
