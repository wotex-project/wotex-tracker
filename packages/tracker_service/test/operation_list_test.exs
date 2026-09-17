defmodule Wotex.Tracker.Service.OperationListTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.Identifier

  @retention 604_800_000

  test "a caller pages its own unexpired receipts newest first within one snapshot" do
    c = service()
    import_operation = Identifier.uuid()

    {:ok, imported} =
      Service.submit(c.service, c.admin, c.scope, import_operation, import_request(), c.now)

    enroll_operation = Identifier.uuid()

    {:ok, enrolled} =
      Service.enroll(
        c.service,
        c.admin,
        c.scope,
        enroll_operation,
        %{
          "observation_id" => imported["data"]["observation_id"],
          "title" => "Workshop sensor",
          "owner_confirmed" => true,
          "expected_generation" => "1"
        },
        c.now + 10
      )

    assert {:ok, %{"generation" => "2", "items" => [first], "cursor" => cursor}} =
             operations(c, c.admin, %{"limit" => 1}, c.now + 20)

    assert first == %{
             "operation_id" => enroll_operation,
             "generation" => "2",
             "recorded_at" => c.now + 10,
             "expires_at" => c.now + 10 + @retention,
             "receipt" => enrolled
           }

    {:ok, _} =
      Service.materialize(
        c.service,
        c.admin,
        c.scope,
        Identifier.uuid(),
        %{"thing_id" => enrolled["data"]["thing_id"], "expected_generation" => "2"},
        c.now + 30
      )

    assert {:ok, %{"generation" => "2", "items" => [second], "cursor" => next}} =
             operations(c, c.admin, %{"cursor" => cursor}, c.now + 40)

    assert %{"operation_id" => ^import_operation, "generation" => "1", "receipt" => ^imported} =
             second

    assert {:ok, %{"items" => [], "cursor" => nil}} =
             operations(c, c.admin, %{"cursor" => next}, c.now + 40)

    assert {:ok, %{"generation" => "3", "items" => newest}} =
             operations(c, c.admin, %{}, c.now + 40)

    assert Enum.map(newest, & &1["generation"]) == ["3", "2", "1"]
    assert {:ok, %{"items" => []}} = operations(c, c.reader, %{}, c.now + 40)

    assert {:ok, %{"items" => [%{"generation" => "3"}]}} =
             operations(c, c.admin, %{}, c.now + 10 + @retention)

    for params <- [
          %{"cursor" => cursor, "limit" => 2},
          %{"cursor" => "wtrc1.invalid"}
        ] do
      assert {:error, %{"code" => "invalid_cursor"}} = operations(c, c.admin, params, c.now + 40)
    end

    assert {:error, %{"code" => "invalid_cursor"}} =
             operations(c, c.reader, %{"cursor" => cursor}, c.now + 40)

    {:ok, %{"cursor" => page_cursor}} =
      Service.list(c.service, c.admin, c.scope, "observations", %{"limit" => 1}, c.now + 40)

    assert {:error, %{"code" => "invalid_cursor"}} =
             operations(c, c.admin, %{"cursor" => page_cursor}, c.now + 40)

    for params <- [%{"limit" => 0}, %{"limit" => "1"}, %{"other" => 1}, nil] do
      assert {:error, %{"code" => "invalid_request"}} = operations(c, c.admin, params, c.now)
    end

    assert {:error, %{"code" => "unauthorized"}} = operations(c, "invalid", %{}, c.now)
  end

  defp operations(c, token, params, now),
    do: Service.operations(c.service, token, c.scope, params, now)
end
