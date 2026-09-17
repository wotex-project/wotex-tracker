defmodule Wotex.Tracker.Service.CredentialInventoryTest do
  @moduledoc false

  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Credentials, Identifier, Store}

  @fields ~w(credential_id current expires_at permissions principal revocation schema status)

  setup do
    now = 1_700_000_000_000
    tokens = Map.new(~w(admin reader short elsewhere), &{&1, Credentials.generate_token()})

    entry = fn id, principal, grants, expires_at ->
      {:ok, digest} = Credentials.token_digest(tokens[id])

      %{
        id: id,
        principal: principal,
        token_sha256: digest,
        grants: grants,
        expires_at: expires_at
      }
    end

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "inventory-fixture",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          entry.("reader", "viewer", %{"workshop" => ~w(read)}, now + 1_000_000),
          entry.(
            "admin",
            "owner",
            %{"workshop" => ~w(read admin), "garage" => ~w(read)},
            now + 1_000_000
          ),
          entry.("short", "visitor", %{"workshop" => ~w(read)}, now + 10),
          entry.("elsewhere", "neighbour", %{"garage" => ~w(admin)}, now + 1_000_000)
        ]
      })

    {store, _} = store(credentials: credentials)

    {:ok, service} =
      Service.new(%{store: store, credentials: credentials, base_url: "http://127.0.0.1:45678"})

    %{service: service, store: store, credentials: credentials, tokens: tokens, now: now}
  end

  test "administrators list only this scope's credentials without token digests", c do
    assert {:ok, %{"generation" => "0", "items" => items}} =
             Service.credentials(c.service, c.tokens["admin"], "workshop", c.now)

    assert Enum.map(
             items,
             &{&1["credential_id"], &1["principal"], &1["permissions"], &1["status"],
              &1["current"]}
           ) == [
             {"admin", "owner", ["admin", "read"], "active", true},
             {"reader", "viewer", ["read"], "active", false},
             {"short", "visitor", ["read"], "active", false}
           ]

    assert Enum.all?(items, &(Enum.sort(Map.keys(&1)) == @fields))
    assert Enum.all?(items, &(&1["schema"] == "wtr.credential.v1" and is_nil(&1["revocation"])))
    assert Enum.find(items, &(&1["credential_id"] == "short"))["expires_at"] == c.now + 10

    assert {:ok, %{"items" => later}} =
             Service.credentials(c.service, c.tokens["admin"], "workshop", c.now + 10)

    assert Enum.find(later, &(&1["credential_id"] == "short"))["status"] == "expired"

    assert {:ok, %{"items" => garage}} =
             Service.credentials(c.service, c.tokens["elsewhere"], "garage", c.now)

    assert Enum.map(garage, &{&1["credential_id"], &1["permissions"], &1["current"]}) == [
             {"admin", ["read"], false},
             {"elsewhere", ["admin"], true}
           ]

    assert {:error, %{"code" => "forbidden"}} =
             Service.credentials(c.service, c.tokens["reader"], "workshop", c.now)

    assert {:error, %{"code" => "forbidden"}} =
             Service.credentials(c.service, c.tokens["admin"], "garage", c.now)

    assert {:error, %{"code" => "unauthorized"}} =
             Service.credentials(c.service, "invalid", "workshop", c.now)
  end

  test "a committed revocation is listed and precedes expiry", c do
    revoke = fn id, generation, now ->
      Service.revoke(
        c.service,
        c.tokens["admin"],
        "workshop",
        Identifier.uuid(),
        %{"credential_id" => id, "expected_generation" => generation},
        now
      )
    end

    assert {:ok, %{"outcome" => "committed", "generation" => "1"}} =
             revoke.("reader", "0", c.now + 5)

    assert {:ok, %{"outcome" => "committed", "generation" => "2"}} =
             revoke.("short", "1", c.now + 6)

    assert {:ok, %{"generation" => "2", "items" => items}} =
             Service.credentials(c.service, c.tokens["admin"], "workshop", c.now + 20)

    assert Enum.map(items, &{&1["credential_id"], &1["status"]}) == [
             {"admin", "active"},
             {"reader", "revoked"},
             {"short", "revoked"}
           ]

    assert Enum.find(items, &(&1["credential_id"] == "reader"))["revocation"] == %{
             "at" => c.now + 5,
             "by" => "owner",
             "generation" => "1"
           }

    assert {:error, %{"code" => "unauthorized"}} =
             Service.list(c.service, c.tokens["reader"], "workshop", "things", %{}, c.now + 20)

    assert {:ok, %{"items" => garage}} =
             Service.credentials(c.service, c.tokens["elsewhere"], "garage", c.now + 20)

    assert Enum.all?(garage, &(&1["status"] == "active"))
  end

  test "revocation reads reject unbounded or malformed credential IDs", c do
    {:ok, access} = Service.authorize(c.service, c.tokens["admin"], "workshop", "admin", c.now)

    assert {:ok, %{"generation" => "0", "items" => []}} =
             Store.authorized_revocations(c.store, access, [], c.now)

    assert {:error, :invalid_query} = Store.authorized_revocations(c.store, access, [""], c.now)
    assert {:error, :invalid_query} = Store.authorized_revocations(c.store, access, nil, c.now)

    ids = Enum.map(1..33, &"credential-#{&1}")
    assert {:error, :invalid_query} = Store.authorized_revocations(c.store, access, ids, c.now)
    assert Credentials.inventory(c.credentials, "unknown") == []
  end
end
