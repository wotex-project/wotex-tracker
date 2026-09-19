defmodule Wotex.Tracker.Service.NotificationEndpointTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures

  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Credentials, Identifier, NotificationEndpoint, Store}

  test "registration encrypts tokens and exposes only a principal-owned public projection" do
    c = service()

    {:ok, %{"stream_cursor" => stream}} =
      Service.list(c.service, c.reader, c.scope, "things", %{}, c.now)

    request = register_request("phone", "apns-token-one", "0")

    assert {:error, %{"code" => "invalid_request"}} =
             Service.notification_endpoint(c.service, c.admin, c.scope, "", c.now)

    assert {:error, %{"code" => "not_found"}} =
             Service.unregister_notification_endpoint(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "phone", "expected_generation" => "0"},
               c.now
             )

    for invalid <- [
          %{},
          %{"id" => "", "expected_generation" => "0"},
          %{"id" => "phone", "expected_generation" => "00"},
          %{"id" => "phone", "expected_generation" => "0", "extra" => true}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               Service.unregister_notification_endpoint(
                 c.service,
                 c.admin,
                 c.scope,
                 Identifier.uuid(),
                 invalid,
                 c.now
               )
    end

    assert {:error, %{"code" => "forbidden"}} =
             register(c, c.reader, Identifier.uuid(), request, c.now)

    for invalid <- [
          %{},
          Map.put(request, "extra", true),
          %{request | "id" => ""},
          %{request | "provider" => "fcm"},
          %{request | "environment" => "preview"},
          %{request | "token" => "bad\ntoken"},
          %{request | "token" => String.duplicate("x", 4_097)},
          %{request | "expected_generation" => "00"}
        ] do
      assert {:error, %{"code" => "invalid_request"}} =
               register(c, c.admin, Identifier.uuid(), invalid, c.now)
    end

    assert {:error, %{"code" => "conflict"}} =
             register(
               c,
               c.admin,
               Identifier.uuid(),
               %{request | "expected_generation" => "1"},
               c.now
             )

    operation = Identifier.uuid()

    assert {:ok, %{"generation" => "1", "data" => data} = receipt} =
             register(c, c.admin, operation, request, c.now)

    assert data == %{"endpoint_id" => "phone", "action" => "registered"}
    refute inspect(receipt) =~ request["token"]
    assert {:ok, ^receipt} = register(c, c.admin, operation, request, c.now + 1)

    assert {:error, %{"code" => "forbidden"}} =
             Service.notification_endpoints(c.service, c.reader, c.scope, c.now + 1)

    assert {:ok, %{"generation" => "1", "items" => [item]}} =
             Service.notification_endpoints(c.service, c.admin, c.scope, c.now + 1)

    assert item["id"] == "phone"
    assert item["generation"] == "1"

    assert item["value"] == %{
             "schema" => "wtr.notification-endpoint.v1",
             "id" => "phone",
             "provider" => "apns",
             "app_id" => "org.wotex.tracker",
             "environment" => "sandbox",
             "revision" => "notification-endpoint-1",
             "created_at" => c.now,
             "updated_at" => c.now
           }

    refute Map.has_key?(item["value"], "token")

    assert {:ok, %{"value" => item_value}} =
             Service.notification_endpoint(c.service, c.admin, c.scope, "phone", c.now + 1)

    assert item_value == item["value"]

    assert {:ok, %{"items" => [stored_item]}} =
             Store.snapshot(c.store, %{
               scope: c.scope,
               kind: "notification_endpoints",
               generation: nil,
               after: "",
               limit: 10
             })

    stored = stored_item["value"]
    assert stored["secret"] =~ "wtrn1."
    refute inspect(stored) =~ request["token"]
    refute stored_item["id"] == "phone"

    assert {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now + 1)

    assert {:error, :invalid_cursor} =
             NotificationEndpoint.list(c.service, access, "2", c.now + 1)

    assert {:ok, "apns-token-one"} =
             NotificationEndpoint.token(c.service, access, "phone", stored)

    assert {:error, :storage_unavailable} =
             NotificationEndpoint.token(c.service, access, "other", stored)

    assert {:error, :storage_unavailable} =
             NotificationEndpoint.token(
               c.service,
               access,
               "phone",
               Map.put(stored, "secret", "wtrn1.invalid")
             )

    assert {:error, :storage_unavailable} =
             NotificationEndpoint.token(
               c.service,
               access,
               "phone",
               Map.put(stored, "secret", "invalid")
             )

    assert {:ok, %{"items" => [%{"event" => event}]}} =
             Service.events(c.service, c.reader, c.scope, stream, c.now + 1)

    assert event["type"] == "notification_endpoint.changed"
    assert event["data"]["action"] == "registered"
    assert String.starts_with?(event["data"]["id"], "wtr1_")
    refute inspect(event) =~ "phone"
    refute inspect(event) =~ request["token"]
  end

  test "token rotation preserves binding and unregistering leaves a tombstone" do
    c = service()

    assert {:ok, %{"generation" => "1"}} =
             register(
               c,
               c.admin,
               Identifier.uuid(),
               register_request("phone", "first-token", "0"),
               c.now
             )

    changed_binding =
      register_request("phone", "second-token", "1")
      |> Map.put("environment", "production")

    assert {:error, %{"code" => "conflict"}} =
             register(c, c.admin, Identifier.uuid(), changed_binding, c.now + 1)

    assert {:ok, %{"generation" => "2"}} =
             register(
               c,
               c.admin,
               Identifier.uuid(),
               register_request("phone", "second-token", "1"),
               c.now + 2
             )

    assert {:ok, %{"items" => [%{"value" => rotated}]}} =
             Service.notification_endpoints(c.service, c.admin, c.scope, c.now + 2)

    assert rotated["created_at"] == c.now
    assert rotated["updated_at"] == c.now + 2
    assert rotated["revision"] == "notification-endpoint-2"

    assert {:ok, %{"items" => [%{"value" => stored}]}} =
             Store.snapshot(c.store, %{
               scope: c.scope,
               kind: "notification_endpoints",
               generation: nil,
               after: "",
               limit: 10
             })

    assert {:ok, access} = Service.authorize(c.service, c.admin, c.scope, "admin", c.now + 2)
    assert {:ok, "second-token"} = NotificationEndpoint.token(c.service, access, "phone", stored)

    assert {:error, %{"code" => "conflict"}} =
             Service.unregister_notification_endpoint(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "phone", "expected_generation" => "1"},
               c.now + 3
             )

    assert {:ok, %{"generation" => "3", "data" => data}} =
             Service.unregister_notification_endpoint(
               c.service,
               c.admin,
               c.scope,
               Identifier.uuid(),
               %{"id" => "phone", "expected_generation" => "2"},
               c.now + 3
             )

    assert data == %{"endpoint_id" => "phone", "action" => "unregistered"}

    assert {:ok, %{"items" => []}} =
             Service.notification_endpoints(c.service, c.admin, c.scope, c.now + 3)

    assert {:error, %{"code" => "not_found"}} =
             Service.notification_endpoint(c.service, c.admin, c.scope, "phone", c.now + 3)

    {reopened, _directory} = store(directory: c.directory, credentials: c.credentials)
    service = %{c.service | store: reopened}

    assert {:ok, %{"items" => []}} =
             Service.notification_endpoints(service, c.admin, c.scope, c.now + 4)
  end

  test "endpoint inventories are bounded and isolated by principal" do
    now = 1_700_000_000_000
    first = Credentials.generate_token()
    second = Credentials.generate_token()
    {:ok, first_digest} = Credentials.token_digest(first)
    {:ok, second_digest} = Credentials.token_digest(second)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "notification-principals",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "first",
            principal: "owner-one",
            token_sha256: first_digest,
            grants: %{"workshop" => ~w(read admin)},
            expires_at: now + 1_000_000
          },
          %{
            id: "second",
            principal: "owner-two",
            token_sha256: second_digest,
            grants: %{"workshop" => ~w(read admin)},
            expires_at: now + 1_000_000
          }
        ]
      })

    {store, _directory} = store(credentials: credentials)

    {:ok, service} =
      Service.new(%{store: store, credentials: credentials, base_url: "http://127.0.0.1:45678"})

    for index <- 1..8 do
      generation = Integer.to_string(index - 1)

      assert {:ok, %{"generation" => expected}} =
               Service.register_notification_endpoint(
                 service,
                 first,
                 "workshop",
                 Identifier.uuid(),
                 register_request("phone-#{index}", "token-#{index}", generation),
                 now + index
               )

      assert expected == Integer.to_string(index)
    end

    assert {:error, %{"code" => "capacity_exceeded"}} =
             Service.register_notification_endpoint(
               service,
               first,
               "workshop",
               Identifier.uuid(),
               register_request("phone-9", "token-9", "8"),
               now + 9
             )

    assert {:ok, %{"generation" => "9"}} =
             Service.register_notification_endpoint(
               service,
               second,
               "workshop",
               Identifier.uuid(),
               register_request("phone-1", "other-token", "8"),
               now + 9
             )

    assert {:ok, %{"items" => first_items}} =
             Service.notification_endpoints(service, first, "workshop", now + 10)

    assert length(first_items) == 8

    assert {:ok, %{"items" => [%{"id" => "phone-1", "value" => second_public}]}} =
             Service.notification_endpoints(service, second, "workshop", now + 10)

    assert second_public["updated_at"] == now + 9

    assert {:ok, %{"value" => first_public}} =
             Service.notification_endpoint(service, first, "workshop", "phone-1", now + 10)

    refute first_public["updated_at"] == second_public["updated_at"]
  end

  defp register(c, token, operation, request, now),
    do:
      Service.register_notification_endpoint(
        c.service,
        token,
        c.scope,
        operation,
        request,
        now
      )

  defp register_request(id, token, generation),
    do: %{
      "id" => id,
      "provider" => "apns",
      "app_id" => "org.wotex.tracker",
      "environment" => "sandbox",
      "token" => token,
      "expected_generation" => generation
    }
end
