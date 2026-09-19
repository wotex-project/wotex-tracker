defmodule Wotex.Tracker.Service.ForwardQueueTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Exqlite.Sqlite3
  alias Wotex.Tracker.Service.{Codec, ForwardItem, Store}
  alias Wotex.Tracker.TransportCandidate

  test "reliable overflow rejects while lossy overflow leaves a durable drop receipt" do
    first = item("first")
    bytes = byte_size(Codec.encode!(ForwardItem.document(first)))
    {store, _} = store(forward_max_items: 1)

    assert {:ok, queued} = Store.enqueue_forward(store, first)
    assert queued["status"] == "pending"
    assert queued["disposition"] == "queued"
    assert queued["queue_identity"] == first.identity
    assert queued["size_bytes"] == bytes
    assert Store.enqueue_forward(store, first) == {:ok, queued}

    changed = item("first", payload: %{"temperature" => 24.4})
    assert {:error, :forward_conflict} = Store.enqueue_forward(store, changed)

    assert {:error, :queue_full} = Store.enqueue_forward(store, item("reliable-overflow"))

    lossy = item("lossy-overflow", source: :lossy)
    assert {:ok, dropped} = Store.enqueue_forward(store, lossy)
    assert dropped["status"] == "discarded"
    assert dropped["disposition"] == "dropped"
    assert dropped["reason"] == "overflow"
    assert Store.forward_status(store, "workshop", lossy.id) == {:ok, dropped}

    other_scope = item("independent", scope: "other")
    assert {:ok, %{"disposition" => "queued"}} = Store.enqueue_forward(store, other_scope)

    {byte_limited, _} = store(forward_max_items: 2, forward_max_bytes: bytes + 10)
    assert {:ok, _} = Store.enqueue_forward(byte_limited, first)
    assert {:error, :queue_full} = Store.enqueue_forward(byte_limited, item("byte-overflow"))
  end

  test "claims use admitted time and ID order with durable retry and attempt exhaustion" do
    {store, directory} = store(forward_max_attempts: 2, forward_max_age_ms: 1_000)
    assert {:ok, _} = Store.enqueue_forward(store, item("b"))
    assert {:ok, _} = Store.enqueue_forward(store, item("a"))
    assert {:ok, _} = Store.enqueue_forward(store, item("later", admitted_at: now() + 11))

    assert {:ok, first} = Store.claim_forward(store, "workshop", now(), 2, 10)
    assert Enum.map(first["items"], & &1["id"]) == ["a", "b"]
    assert Enum.map(first["items"], & &1["attempt"]) == [1, 1]
    assert Enum.all?(first["items"], &(&1["retry_at"] == now() + 10))

    assert {:ok, %{"items" => []}} =
             Store.claim_forward(store, "workshop", now() + 9, 100, 10)

    GenServer.stop(store.pid)

    {reopened, _} =
      store(
        directory: directory,
        forward_max_attempts: 8,
        forward_max_age_ms: 2_000
      )

    assert {:ok, second} = Store.claim_forward(reopened, "workshop", now() + 10, 2, 10)

    assert Enum.map(second["items"], &{&1["id"], &1["attempt"], &1["maximum_attempts"]}) == [
             {"a", 2, 2},
             {"b", 2, 2}
           ]

    assert {:ok, %{"items" => [later]}} =
             Store.claim_forward(reopened, "workshop", now() + 11, 100, 10)

    assert later["id"] == "later"

    assert {:ok, %{"items" => []}} =
             Store.claim_forward(reopened, "workshop", now() + 20, 100, 10)

    for id <- ~w(a b) do
      assert {:ok, receipt} = Store.forward_status(reopened, "workshop", id)
      assert receipt["status"] == "discarded"
      assert receipt["reason"] == "attempts_exhausted"
      assert receipt["attempts"] == 2
    end
  end

  test "expiry is exact and later items are never delivered around an expired predecessor" do
    {store, _} = store(forward_max_age_ms: 10)
    assert {:ok, _} = Store.enqueue_forward(store, item("expired"))
    assert {:ok, _} = Store.enqueue_forward(store, item("live", admitted_at: now() + 1))

    assert {:ok, claim} = Store.claim_forward(store, "workshop", now() + 10, 10, 5)
    assert Enum.map(claim["items"], & &1["id"]) == ["live"]

    assert {:ok, expired} = Store.forward_status(store, "workshop", "expired")
    assert expired["status"] == "discarded"
    assert expired["reason"] == "expired"
    assert expired["attempts"] == 0
  end

  test "independent writers serialize claims without leasing the same item" do
    {first, directory} = store()
    {second, _} = store(directory: directory)
    assert {:ok, _} = Store.enqueue_forward(first, item("only"))

    claims =
      [first, second]
      |> Enum.map(fn store ->
        Task.async(fn -> Store.claim_forward(store, "workshop", now(), 1, 100) end)
      end)
      |> Task.await_many()

    assert Enum.sort(Enum.map(claims, fn {:ok, result} -> length(result["items"]) end)) == [0, 1]

    assert {:ok, receipt} = Store.forward_status(first, "workshop", "only")
    assert receipt["attempts"] == 1
  end

  test "completion requires a claim, exact item identity and the declared acknowledgement layer" do
    {store, _} = store()
    item = item("acknowledged", acknowledgement: :durable_admission)
    assert {:ok, _} = Store.enqueue_forward(store, item)
    completion = completion(:acknowledged, :durable_admission)

    assert {:error, :forward_not_claimed} =
             Store.complete_forward(store, item.scope, item.id, item.identity, completion)

    assert {:ok, %{"items" => [_]}} =
             Store.claim_forward(store, item.scope, now(), 1, 10)

    assert {:error, :acknowledgement_mismatch} =
             Store.complete_forward(
               store,
               item.scope,
               item.id,
               item.identity,
               completion(:acknowledged, :network)
             )

    assert {:error, :acknowledgement_mismatch} =
             Store.complete_forward(
               store,
               item.scope,
               item.id,
               item.identity,
               %{completion | at: now() - 1}
             )

    assert {:error, :forward_conflict} =
             Store.complete_forward(store, item.scope, item.id, "wrong", completion)

    assert {:ok, delivered} =
             Store.complete_forward(store, item.scope, item.id, item.identity, completion)

    assert delivered["status"] == "delivered"
    assert delivered["disposition"] == "delivered"

    assert delivered["completion"] == %{
             "status" => "acknowledged",
             "layer" => "durable_admission",
             "at" => now() + 1,
             "reference" => "server-admission-1"
           }

    assert Store.complete_forward(store, item.scope, item.id, item.identity, completion) ==
             {:ok, delivered}

    assert {:error, :forward_conflict} =
             Store.complete_forward(
               store,
               item.scope,
               item.id,
               item.identity,
               %{completion | reference: "changed"}
             )

    sent = item("sent", acknowledgement: :none)
    assert {:ok, _} = Store.enqueue_forward(store, sent)
    assert {:ok, _} = Store.claim_forward(store, sent.scope, now(), 1, 10)

    assert {:ok, %{"completion" => %{"status" => "sent", "layer" => "none"}}} =
             Store.complete_forward(
               store,
               sent.scope,
               sent.id,
               sent.identity,
               completion(:sent, :none)
             )
  end

  test "notification claims are isolated and explicit discards require the exact claimed item" do
    {store, _} = store()
    ordinary = item("ordinary")

    notification =
      item("notification",
        bearer: "push",
        protocol: "apns",
        candidate: "endpoint@revision",
        payload: %{"schema" => "wtr.notification-reference.v1", "event_ref" => "alert-1"},
        source: :lossy,
        acknowledgement: :application
      )

    assert {:ok, _} = Store.enqueue_forward(store, ordinary)
    assert {:ok, _} = Store.enqueue_forward(store, notification)

    assert {:ok, %{"items" => [claimed]}} =
             Store.claim_notifications(store, "workshop", now(), 10, 100)

    assert claimed["id"] == notification.id
    assert claimed["attempt"] == 1

    assert {:ok, %{"items" => [%{"id" => "ordinary"}]}} =
             Store.claim_forward(store, "workshop", now(), 10, 100)

    assert {:error, :forward_conflict} =
             Store.discard_forward(
               store,
               notification.scope,
               notification.id,
               ordinary.identity,
               "provider_rejected",
               now() + 1
             )

    assert {:ok, discarded} =
             Store.discard_forward(
               store,
               notification.scope,
               notification.id,
               notification.identity,
               "provider_rejected",
               now() + 1
             )

    assert discarded["status"] == "discarded"
    assert discarded["reason"] == "provider_rejected"
    assert discarded["settled_at"] == now() + 1

    assert {:ok, ^discarded} =
             Store.discard_forward(
               store,
               notification.scope,
               notification.id,
               notification.identity,
               "provider_rejected",
               now() + 2
             )

    assert {:error, :forward_conflict} =
             Store.discard_forward(
               store,
               notification.scope,
               notification.id,
               notification.identity,
               "invalid_token",
               now() + 2
             )
  end

  test "discard admission is closed and an unclaimed item remains pending" do
    {store, _} = store()
    pending = item("pending-discard")
    assert {:ok, _} = Store.enqueue_forward(store, pending)

    assert {:error, :forward_not_claimed} =
             Store.discard_forward(
               store,
               pending.scope,
               pending.id,
               pending.identity,
               "endpoint_missing",
               now()
             )

    assert {:error, :invalid_query} =
             Store.claim_notifications(store, "", now(), 1, 1)

    assert {:error, :invalid_query} =
             Store.discard_forward(
               store,
               pending.scope,
               pending.id,
               pending.identity,
               "invented_reason",
               now()
             )

    assert {:ok, %{"status" => "pending"}} =
             Store.forward_status(store, pending.scope, pending.id)

    assert {:error, :not_found} =
             Store.discard_forward(
               store,
               pending.scope,
               "missing",
               pending.identity,
               "endpoint_missing",
               now()
             )

    assert {:error, :invalid_query} = Store.notification_endpoint(store, "", "endpoint")
  end

  test "discard cannot replace delivery or predate queue admission" do
    {store, _} = store()
    delivered = item("already-delivered")
    assert {:ok, _} = Store.enqueue_forward(store, delivered)
    assert {:ok, %{"items" => [_]}} = Store.claim_forward(store, delivered.scope, now(), 1, 1)

    assert {:ok, _} =
             Store.complete_forward(
               store,
               delivered.scope,
               delivered.id,
               delivered.identity,
               completion(:acknowledged, :durable_admission)
             )

    assert {:error, :forward_conflict} =
             Store.discard_forward(
               store,
               delivered.scope,
               delivered.id,
               delivered.identity,
               "provider_rejected",
               now() + 2
             )

    future = item("future-discard", admitted_at: now() + 10)
    assert {:ok, _} = Store.enqueue_forward(store, future)

    assert {:ok, %{"items" => [_]}} =
             Store.claim_forward(store, future.scope, now() + 10, 1, 1)

    assert {:error, :invalid_forward_discard} =
             Store.discard_forward(
               store,
               future.scope,
               future.id,
               future.identity,
               "provider_rejected",
               now()
             )
  end

  test "terminal cleanup is explicit, scoped and bounded by settlement time" do
    {store, _} = store(forward_max_items: 1)
    lossy = item("dropped", source: :lossy)
    assert {:ok, _} = Store.enqueue_forward(store, item("pending"))
    assert {:ok, _} = Store.enqueue_forward(store, lossy)

    assert {:ok, %{"removed" => 0}} =
             Store.cleanup_forward(store, "workshop", now() - 1)

    assert {:ok, %{"removed" => 1}} = Store.cleanup_forward(store, "workshop", now())
    assert {:error, :not_found} = Store.forward_status(store, "workshop", lossy.id)
    assert {:ok, %{"status" => "pending"}} = Store.forward_status(store, "workshop", "pending")
    assert {:ok, %{"removed" => 0}} = Store.cleanup_forward(store, "other", now())
  end

  test "schema one upgrades transactionally and existing state remains readable" do
    directory = directory()
    path = Path.join(directory, "tracker.db")
    {:ok, db} = Sqlite3.open(path)
    schema = File.read!(Application.app_dir(:wotex_tracker_service, "priv/schema/1.sql"))
    :ok = Sqlite3.execute(db, schema)
    :ok = Sqlite3.execute(db, "INSERT INTO scopes VALUES('existing',3)")
    :ok = Sqlite3.close(db)
    :ok = File.chmod(path, 0o600)

    {store, _} = store(directory: directory)
    assert {:ok, %{"schema" => "7"}} = Store.readiness(store)
    assert {:ok, _} = Store.enqueue_forward(store, item("migrated"))
    assert {:ok, %{"generation" => "3"}} = Store.snapshot(store, query(%{scope: "existing"}))
  end

  test "queue commits roll back before commit and remain discoverable after lost acknowledgement" do
    {before_commit, _} =
      store(fault: fn phase -> if phase == :forward_before_commit, do: :abort, else: :ok end)

    item = item("before")
    assert {:error, :injected_failure} = Store.enqueue_forward(before_commit, item)
    assert {:error, :not_found} = Store.forward_status(before_commit, item.scope, item.id)

    {after_commit, _} =
      store(fault: fn phase -> if phase == :forward_after_commit, do: :abort, else: :ok end)

    committed = item("after")
    assert {:error, :unknown} = Store.enqueue_forward(after_commit, committed)
    assert {:ok, receipt} = Store.forward_status(after_commit, committed.scope, committed.id)
    assert receipt["queue_identity"] == committed.identity
    assert receipt["status"] == "pending"
  end

  test "item, completion and query admission is closed and bounded" do
    assert ForwardItem.acknowledgement_layers() == TransportCandidate.acknowledgement_layers()
    original = item("valid")
    assert {:ok, ^original} = ForwardItem.validate(original)
    assert {:error, :forward_conflict} = ForwardItem.validate(%{original | bearer: "wifi"})
    assert {:error, _} = ForwardItem.new(Map.put(item_input("extra"), :extra, true))
    assert {:error, _} = ForwardItem.new(%{item_input("atom") | payload: %{bad: true}})
    assert {:error, _} = ForwardItem.new(%{item_input("source") | source: :unknown})
    assert {:error, _} = ForwardItem.validate(:invalid)

    {store, _} = store()
    assert {:error, :invalid_forward_item} = Store.enqueue_forward(store, :invalid)
    assert {:error, :invalid_query} = Store.claim_forward(store, "", now(), 1, 1)
    assert {:error, :invalid_query} = Store.claim_forward(store, "workshop", now(), 0, 1)
    assert {:error, :invalid_query} = Store.claim_forward(store, "workshop", now(), 1, 0)
    assert {:error, :invalid_query} = Store.forward_status(store, "", "id")
    assert {:error, :invalid_query} = Store.cleanup_forward(store, "workshop", -1)

    assert {:error, :invalid_query} =
             Store.complete_forward(store, "workshop", "id", "identity", %{})
  end

  defp now, do: 1_700_000_000_000

  defp item(id, options \\ []) do
    {:ok, value} = ForwardItem.new(item_input(id, options))
    value
  end

  defp item_input(id, options \\ []),
    do: %{
      scope: Keyword.get(options, :scope, "workshop"),
      id: id,
      candidate_id: Keyword.get(options, :candidate, "cellular"),
      bearer: Keyword.get(options, :bearer, "lte-m"),
      application_protocol: Keyword.get(options, :protocol, "fixture-protocol"),
      payload: Keyword.get(options, :payload, %{"temperature" => 24.3}),
      source: Keyword.get(options, :source, :reliable),
      admitted_at: Keyword.get(options, :admitted_at, now()),
      required_acknowledgement: Keyword.get(options, :acknowledgement, :durable_admission)
    }

  defp completion(status, layer),
    do: %{
      status: status,
      layer: layer,
      at: now() + 1,
      reference: "server-admission-1"
    }
end
