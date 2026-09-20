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
