defmodule Wotex.Tracker.Service.AccessAuditTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Credentials, SQL, Store}

  @entry_fields ~w(activity credential_id occurred_at permission principal schema)
  @page_fields ~w(coverage_started_at cursor items maximum_entries retention_ms snapshot truncated)

  setup do
    service()
  end

  test "administrators inspect token-free successful authorization decisions", c do
    assert {:ok, %{"items" => []}} =
             Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    assert {:error, %{"code" => "forbidden"}} =
             Service.access_audit(c.service, c.reader, c.scope, %{}, c.now + 1)

    assert {:error, %{"code" => "unauthorized"}} =
             Service.access_audit(c.service, "not-a-token", c.scope, %{}, c.now + 1)

    assert {:ok, page} = Service.access_audit(c.service, c.admin, c.scope, %{}, c.now + 2)
    assert Enum.sort(Map.keys(page)) == @page_fields
    assert page["coverage_started_at"] == c.now
    assert page["retention_ms"] == 2_592_000_000
    assert page["maximum_entries"] == 10_000
    assert page["truncated"] == false
    assert page["cursor"] == nil

    assert [audit, read] = page["items"]
    assert Enum.all?([audit, read], &(Enum.sort(Map.keys(&1)) == @entry_fields))

    assert audit == %{
             "schema" => "wtr.access-audit-entry.v1",
             "credential_id" => "admin",
             "principal" => "owner",
             "permission" => "admin",
             "activity" => "access_audit",
             "occurred_at" => c.now + 2
           }

    assert read["credential_id"] == "reader"
    assert read["principal"] == "viewer"
    assert read["permission"] == "read"
    assert read["activity"] == "list"
    assert read["occurred_at"] == c.now
    refute inspect(page) =~ c.admin
    refute inspect(page) =~ c.reader
  end

  test "pagination is snapshot-bound and rejects cursor changes", c do
    for {activity, offset} <- [{"first", 0}, {"second", 1}, {"third", 2}] do
      assert {:ok, _} =
               Service.authorize(c.service, c.admin, c.scope, "read", activity, c.now + offset)
    end

    assert {:ok, first} =
             Service.access_audit(c.service, c.admin, c.scope, %{"limit" => 2}, c.now + 3)

    assert Enum.map(first["items"], & &1["activity"]) == ["access_audit", "third"]
    assert is_binary(first["cursor"])

    assert {:ok, second} =
             Service.access_audit(
               c.service,
               c.admin,
               c.scope,
               %{"limit" => 2, "cursor" => first["cursor"]},
               c.now + 4
             )

    assert Enum.map(second["items"], & &1["activity"]) == ["second", "first"]
    assert second["snapshot"] == first["snapshot"]
    assert second["cursor"] == nil

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.access_audit(
               c.service,
               c.admin,
               c.scope,
               %{"limit" => 3, "cursor" => first["cursor"]},
               c.now + 5
             )

    assert {:error, %{"code" => "invalid_request"}} =
             Service.access_audit(c.service, c.admin, c.scope, %{"limit" => 0}, c.now + 5)
  end

  test "audit rows persist across restart without changing domain generation", c do
    assert {:ok, _} = Service.access(c.service, c.admin, c.scope, c.now)
    GenServer.stop(c.store.pid)

    {store, _} = store(directory: c.directory, credentials: c.credentials)

    {:ok, service} =
      Service.new(%{
        store: store,
        credentials: c.credentials,
        base_url: "http://127.0.0.1:45678"
      })

    assert {:ok, %{"generation" => "0"}} =
             Service.list(service, c.admin, c.scope, "things", %{"limit" => 1}, c.now + 1)

    assert {:ok, %{"items" => items}} =
             Service.access_audit(service, c.admin, c.scope, %{}, c.now + 2)

    assert Enum.map(items, & &1["activity"]) == ["access_audit", "list", "access"]
  end

  test "the fixed retention boundary discards expired entries and reports truncation" do
    now = 1_700_000_000_000
    retention = 2_592_000_000
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "audit-retention-fixture",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "administrator",
            principal: "owner",
            token_sha256: digest,
            grants: %{"workshop" => ~w(read admin)},
            expires_at: now + retention + 10_000
          }
        ]
      })

    {store, _directory} = store(credentials: credentials)

    {:ok, service} =
      Service.new(%{
        store: store,
        credentials: credentials,
        base_url: "http://127.0.0.1:45678"
      })

    assert {:ok, _} = Service.authorize(service, token, "workshop", "read", "old", now)

    assert {:ok, _} =
             Service.authorize(
               service,
               token,
               "workshop",
               "read",
               "boundary",
               now + retention
             )

    assert {:ok, page} =
             Service.access_audit(service, token, "workshop", %{}, now + retention + 1)

    assert Enum.map(page["items"], & &1["activity"]) == ["access_audit", "boundary"]
    assert page["coverage_started_at"] == now
    assert page["truncated"] == true

    assert {:ok, %{"generation" => "0"}} =
             Service.list(service, token, "workshop", "things", %{}, now + retention + 2)
  end

  test "the privileged page rejects malformed and future snapshots", c do
    assert {:ok, access} =
             Credentials.authenticate(c.credentials, c.admin, c.scope, "admin", c.now)

    query = %{scope: c.scope, snapshot: nil, before: nil, limit: 1}

    assert {:ok,
            %{
              "snapshot" => "0",
              "items" => [],
              "coverage_started_at" => 0,
              "truncated" => false
            }} = Store.authorized_access_audit(c.store, access, query, c.now)

    assert {:error, :invalid_cursor} =
             Store.authorized_access_audit(c.store, access, %{query | snapshot: "1"}, c.now)

    assert {:error, :invalid_query} =
             Store.authorized_access_audit(c.store, access, %{}, c.now)

    assert {:error, :invalid_query} =
             Store.authorized_access_audit(c.store, nil, query, c.now)
  end

  test "the per-scope capacity removes the oldest row and sets truncation", c do
    {:ok, db} = Sqlite3.open(Path.join(c.directory, "tracker.db"))
    :ok = Sqlite3.execute(db, "BEGIN IMMEDIATE")

    SQL.rows!(db, "INSERT INTO access_audit_state VALUES(?,?,0)", [c.scope, c.now])

    SQL.rows!(
      db,
      """
      WITH RECURSIVE entries(value) AS (
        VALUES(1) UNION ALL SELECT value + 1 FROM entries WHERE value < 10000
      )
      INSERT INTO access_audit(scope,credential_id,principal,permission,activity,occurred_at)
      SELECT 'workshop','admin','owner','read','seed',? FROM entries
      """,
      [c.now]
    )

    :ok = Sqlite3.execute(db, "COMMIT")
    :ok = Sqlite3.close(db)

    assert {:ok, _} =
             Service.authorize(
               c.service,
               c.admin,
               c.scope,
               "read",
               "capacity_boundary",
               c.now + 1
             )

    assert {:ok, page} =
             Service.access_audit(c.service, c.admin, c.scope, %{"limit" => 1}, c.now + 2)

    assert [%{"activity" => "access_audit"}] = page["items"]
    assert page["truncated"] == true

    {:ok, db} = Sqlite3.open(Path.join(c.directory, "tracker.db"))

    assert [[10_000]] =
             SQL.rows!(db, "SELECT count(*) FROM access_audit WHERE scope=?", [c.scope])

    :ok = Sqlite3.close(db)
  end
end
