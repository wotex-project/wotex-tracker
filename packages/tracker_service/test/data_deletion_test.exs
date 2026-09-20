defmodule Wotex.Tracker.Service.DataDeletionTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{DataDeletion, Identifier, Store}

  setup do
    context = service()
    {thing, _td} = materialized(context)
    Map.put(context, :thing, thing)
  end

  test "an administrator inspects consequences and deletes retained domain data", c do
    assert {:error, %{"code" => "forbidden"}} =
             Service.privacy(c.service, c.reader, c.scope, c.now)

    assert {:ok, before} = Service.privacy(c.service, c.admin, c.scope, c.now)
    assert before["schema"] == "wtr.privacy.v1"
    assert before["generation"] == "3"
    assert before["retained"]["observations"] == 1
    assert before["retained"]["record_versions"] > 0
    assert before["retained"]["events"] == 3
    assert before["retained"]["operation_receipts"] == 3
    assert before["last_deletion"] == nil

    assert before["policy"] == %{
             "domain_data" => "retained_until_administrator_deletion",
             "inactivity_retention_ms" => nil,
             "enforcement_interval_ms" => nil,
             "deletion_scope" => "all_retained_domain_data_in_scope",
             "credential_revocations" => "preserved_for_access_control",
             "successful_access_audit" => %{
               "retention_ms" => 2_592_000_000,
               "maximum_entries" => 10_000
             },
             "backups" => "outside_managed_primary_store",
             "offline_exports" => "outside_managed_primary_store",
             "remote_publications" => "outside_managed_primary_store"
           }

    operation = Identifier.uuid()

    request = %{
      "expected_generation" => "3",
      "confirmation" => "delete retained domain data"
    }

    assert {:error, %{"code" => "forbidden", "outcome" => "not_committed"}} =
             Service.delete_domain_data(
               c.service,
               c.reader,
               c.scope,
               Identifier.uuid(),
               request,
               c.now
             )

    for invalid <- [
          %{},
          Map.put(request, "extra", true),
          %{request | "expected_generation" => "03"},
          %{request | "confirmation" => "yes"}
        ] do
      assert {:error, %{"code" => "invalid_request", "outcome" => "not_committed"}} =
               Service.delete_domain_data(
                 c.service,
                 c.admin,
                 c.scope,
                 Identifier.uuid(),
                 invalid,
                 c.now
               )
    end

    assert {:error, %{"code" => "conflict", "outcome" => "not_committed"}} =
             Service.delete_domain_data(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{request | "expected_generation" => "2"},
               c.now
             )

    assert {:ok, %{"stream_cursor" => old_cursor}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now)

    backup_directory = directory()
    backup = Path.join(backup_directory, "tracker.db")
    assert {:ok, _} = Store.backup(c.store, backup)

    assert {:ok, %{"generation" => "4", "data" => data} = receipt} =
             Service.delete_domain_data(
               c.service,
               c.admin,
               c.scope,
               operation,
               request,
               c.now
             )

    assert data["schema"] == "wtr.domain-data-deletion.v1"
    assert data["action"] == "deleted_retained_domain_data"
    assert data["removed"] == before["retained"]
    assert data["preserved"]["credential_revocations"] == 0

    assert data["preserved"]["successful_access_entries"] >=
             before["preserved_on_deletion"]["successful_access_entries"]

    assert data["backups"] == "not_deleted"
    assert data["offline_exports"] == "not_deleted"
    assert data["remote_publications"] == "not_deleted"

    assert {:ok, ^receipt} =
             Service.delete_domain_data(
               c.service,
               c.admin,
               c.scope,
               operation,
               request,
               c.now + 1
             )

    for resource <-
          ~w(observations resolutions evidence state enrollments things saved_queries policies alerts arming owner_presence) do
      assert {:ok, %{"items" => []}} =
               Service.list(c.service, c.admin, c.scope, resource, %{}, c.now)
    end

    assert {:error, %{"code" => "not_found"}} =
             Service.raw_evidence(c.service, c.admin, c.scope, c.thing, c.now)

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.events(c.service, c.admin, c.scope, old_cursor, c.now)

    assert {:ok, []} = Store.scheduled_rules(c.store, 10)

    assert {:error, %{"code" => "not_found"}} =
             Service.operation(c.service, c.admin, c.scope, Identifier.uuid(), c.now)

    assert {:ok, ^receipt} =
             Service.operation(c.service, c.admin, c.scope, operation, c.now)

    assert {:ok, after_delete} = Service.privacy(c.service, c.admin, c.scope, c.now)
    assert after_delete["generation"] == "4"
    assert after_delete["retained"]["observations"] == 0
    assert after_delete["retained"]["record_versions"] == 1
    assert after_delete["retained"]["events"] == 1
    assert after_delete["retained"]["operation_receipts"] == 1
    assert after_delete["last_deletion"]["generation"] == "4"
    assert after_delete["last_deletion"]["cause"] == "administrator"
    assert after_delete["last_deletion"]["removed"] == before["retained"]

    {restored, _} = store(directory: backup_directory)

    assert {:ok, %{"items" => [_]}} =
             Store.snapshot(restored, query(%{kind: "observations"}))
  end

  test "credential revocations and successful access audit survive domain deletion", c do
    assert {:ok, %{"generation" => "4"}} =
             Service.revoke(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "reader", "expected_generation" => "3"},
               c.now
             )

    assert {:ok, before} = Service.privacy(c.service, c.admin, c.scope, c.now)
    assert before["preserved_on_deletion"]["credential_revocations"] == 1
    assert before["preserved_on_deletion"]["successful_access_entries"] > 0

    assert {:ok, %{"generation" => "5"}} =
             Service.delete_domain_data(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{
                 "expected_generation" => "4",
                 "confirmation" => "delete retained domain data"
               },
               c.now
             )

    assert {:ok, privacy} = Service.privacy(c.service, c.admin, c.scope, c.now)
    assert privacy["preserved_on_deletion"]["credential_revocations"] == 1
    assert privacy["preserved_on_deletion"]["successful_access_entries"] > 0

    assert {:ok, %{"items" => credentials}} =
             Service.credentials(c.service, c.admin, c.scope, c.now)

    assert Enum.find(credentials, &(&1["credential_id"] == "reader"))["status"] == "revoked"

    assert {:ok, %{"items" => audit}} =
             Service.access_audit(c.service, c.admin, c.scope, %{"limit" => 100}, c.now)

    assert Enum.any?(audit, &(&1["activity"] == "delete_domain_data"))
  end

  test "configured inactivity retention atomically deletes a quiet domain at the exact boundary" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_700_000_000_000)

    c =
      service(
        domain_inactivity_retention_ms: 1_000,
        retention_check_ms: 60_000,
        clock: fn -> :atomics.get(clock, 1) end
      )

    {thing, _} = materialized(c)

    assert {:ok, %{"generation" => "4"}} =
             Service.revoke(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"credential_id" => "reader", "expected_generation" => "3"},
               c.now
             )

    assert {:ok, %{"stream_cursor" => old_cursor}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now)

    assert {:ok, before} = Service.privacy(c.service, c.admin, c.scope, c.now)

    assert before["policy"] == %{
             "domain_data" => "deleted_after_scope_inactivity",
             "inactivity_retention_ms" => 1_000,
             "enforcement_interval_ms" => 60_000,
             "deletion_scope" => "all_retained_domain_data_in_scope",
             "credential_revocations" => "preserved_for_access_control",
             "successful_access_audit" => %{
               "retention_ms" => 2_592_000_000,
               "maximum_entries" => 10_000
             },
             "backups" => "outside_managed_primary_store",
             "offline_exports" => "outside_managed_primary_store",
             "remote_publications" => "outside_managed_primary_store"
           }

    :atomics.put(clock, 1, c.now + 999)

    assert {:ok, %{"items" => [%{"id" => ^thing}]}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now + 999)

    :atomics.put(clock, 1, c.now + 1_000)

    assert {:ok, privacy} = Service.privacy(c.service, c.admin, c.scope, c.now + 1_000)
    assert privacy["generation"] == "5"
    assert privacy["last_deletion"]["cause"] == "automatic_inactivity"
    assert privacy["last_deletion"]["removed"] == before["retained"]
    assert privacy["retained"]["record_versions"] == 1
    assert privacy["retained"]["events"] == 1
    assert privacy["retained"]["operation_receipts"] == 0
    assert privacy["preserved_on_deletion"]["credential_revocations"] == 1

    assert {:ok, %{"generation" => "5", "items" => []}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now + 1_000)

    assert {:error, %{"code" => "invalid_cursor"}} =
             Service.events(c.service, c.admin, c.scope, old_cursor, c.now + 1_000)

    assert {:ok, %{"items" => credentials}} =
             Service.credentials(c.service, c.admin, c.scope, c.now + 1_000)

    assert Enum.find(credentials, &(&1["credential_id"] == "reader"))["status"] == "revoked"

    :atomics.put(clock, 1, c.now + 2_000)

    assert {:ok, %{"generation" => "5", "items" => []}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now + 2_000)
  end

  test "the periodic store check deletes quiet data without a new service request" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_700_000_000_000)

    c =
      service(
        domain_inactivity_retention_ms: 1_000,
        retention_check_ms: 60_000,
        clock: fn -> :atomics.get(clock, 1) end
      )

    materialized(c)
    :atomics.put(clock, 1, c.now + 1_000)
    send(c.store.pid, :enforce_domain_retention)
    :sys.get_state(c.store.pid)

    assert {:ok, %{"generation" => "4", "items" => []}} =
             Store.snapshot(c.store, query(%{kind: "things"}))

    assert {:ok, privacy} = Service.privacy(c.service, c.admin, c.scope, c.now + 1_000)
    assert privacy["last_deletion"]["cause"] == "automatic_inactivity"
  end

  test "automatic retention rolls back completely when its commit is aborted" do
    clock = :atomics.new(1, [])
    failure = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_700_000_000_000)
    :atomics.put(failure, 1, 1)

    c =
      service(
        domain_inactivity_retention_ms: 1_000,
        retention_check_ms: 60_000,
        clock: fn -> :atomics.get(clock, 1) end,
        fault: fn phase ->
          if phase == :retention_before_commit and :atomics.get(failure, 1) == 1,
            do: :abort,
            else: :ok
        end
      )

    materialized(c)
    :atomics.put(clock, 1, c.now + 1_000)

    assert {:error, %{"code" => "storage_unavailable"}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now + 1_000)

    assert {:ok, %{"generation" => "3", "items" => [_]}} =
             Store.snapshot(c.store, query(%{kind: "things"}))

    :atomics.put(failure, 1, 0)

    assert {:ok, %{"generation" => "4", "items" => []}} =
             Service.list(c.service, c.admin, c.scope, "things", %{}, c.now + 1_000)
  end

  test "failure before deletion commit leaves every domain row intact" do
    {context, operation, result} = faulted_deletion(:before_commit)

    assert {:error,
            %{
              "code" => "storage_unavailable",
              "outcome" => "not_committed",
              "operation_id" => ^operation
            }} = result

    assert {:ok, %{"generation" => "3", "items" => [_]}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "things",
               %{},
               context.now
             )

    assert {:error, %{"code" => "not_found"}} =
             Service.operation(
               context.service,
               context.admin,
               context.scope,
               operation,
               context.now
             )
  end

  test "lost deletion acknowledgement recovers the committed receipt" do
    {context, operation, result} = faulted_deletion(:after_commit)

    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} = result

    assert {:ok, %{"generation" => "4", "items" => []}} =
             Service.list(
               context.service,
               context.admin,
               context.scope,
               "things",
               %{},
               context.now
             )

    assert {:ok, %{"outcome" => "committed", "generation" => "4"}} =
             Service.operation(
               context.service,
               context.admin,
               context.scope,
               operation,
               context.now
             )
  end

  test "low-level deletion boundaries reject malformed callers" do
    assert DataDeletion.confirmation() == "delete retained domain data"
    assert {:error, :invalid_query} = DataDeletion.status(nil, nil, 0, %{})
    assert {:error, :invalid_request} = DataDeletion.delete(nil, nil, nil, nil, nil, nil)
  end

  test "a crash before deletion commit reports an unknown outcome" do
    {_context, operation, result} = faulted_deletion(:before_commit, :crash)
    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} = result
  end

  test "a crash after deletion commit reports an unknown outcome" do
    {_context, operation, result} = faulted_deletion(:after_commit, :crash)
    assert {:ok, %{"outcome" => "unknown", "operation_id" => ^operation}} = result
  end

  defp faulted_deletion(phase, effect \\ :abort) do
    faults = start_supervised!({Agent, fn -> :none end}, id: make_ref())

    context =
      service(
        fault: fn current ->
          if Agent.get(faults, & &1) == current, do: effect, else: :ok
        end
      )

    {_thing, _td} = materialized(context)
    operation = Identifier.uuid()
    Agent.update(faults, fn _ -> phase end)

    result =
      Service.delete_domain_data(
        context.service,
        context.admin,
        context.scope,
        operation,
        %{
          "expected_generation" => "3",
          "confirmation" => "delete retained domain data"
        },
        context.now
      )

    {context, operation, result}
  end
end
