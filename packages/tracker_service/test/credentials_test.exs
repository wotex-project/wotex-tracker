defmodule Wotex.Tracker.Service.CredentialsTest do
  @moduledoc false
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Service.{Credentials, Cursor}

  setup do
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    entry = %{
      id: "key-1",
      principal: "owner",
      token_sha256: digest,
      grants: %{"workshop" => ["read", "ingest"]},
      expires_at: 1000
    }

    input = %{
      instance_id: "instance-1",
      secret_key: :crypto.strong_rand_bytes(32),
      entries: [entry]
    }

    {:ok, credentials} = Credentials.new(input)
    %{token: token, entry: entry, input: input, credentials: credentials}
  end

  test "ephemeral tokens create redacted proofs bound to exact scope and permissions", context do
    assert byte_size(context.token) == 43
    assert Credentials.instance_id(context.credentials) == "instance-1"
    assert {:ok, _} = Credentials.validate(context.credentials)
    assert {:error, :invalid_credentials} = Credentials.validate(nil)
    assert {:error, :unauthorized} = Credentials.reauthorize(nil, nil, "read", 1)

    assert {:ok, access} =
             Credentials.authenticate(context.credentials, context.token, "workshop", "read", 1)

    assert :ok = Credentials.reauthorize(context.credentials, access, "ingest", 999)
    assert {:error, :forbidden} = Credentials.reauthorize(context.credentials, access, "raw", 1)

    assert {:error, :unauthorized} =
             Credentials.reauthorize(context.credentials, access, "read", 1000)

    assert {:error, :unauthorized} =
             Credentials.authenticate(
               context.credentials,
               context.token,
               "workshop",
               "read",
               1000
             )

    assert {:error, :forbidden} =
             Credentials.authenticate(context.credentials, context.token, "other", "read", 1)

    assert {:error, :forbidden} =
             Credentials.authenticate(context.credentials, context.token, "workshop", "admin", 1)

    assert {:error, :forbidden} =
             Credentials.authenticate(context.credentials, context.token, "workshop", :read, 1)

    assert {:error, :unauthorized} =
             Credentials.authenticate(
               context.credentials,
               Credentials.generate_token(),
               "workshop",
               "read",
               1
             )

    for token <- ["bad", nil, String.duplicate("=", 43)] do
      assert {:error, :invalid_token} = Credentials.token_digest(token)

      assert {:error, :unauthorized} =
               Credentials.authenticate(context.credentials, token, "workshop", "read", 1)
    end

    refute inspect(context.credentials) =~ context.token
    refute inspect(context.credentials) =~ context.entry.token_sha256
    refute inspect(context.credentials) =~ Base.encode16(context.input.secret_key)
    refute inspect(access) =~ Base.encode16(access.proof)
  end

  test "forging bindings or replacing credential hashes invalidates old proofs", context do
    {:ok, access} =
      Credentials.authenticate(context.credentials, context.token, "workshop", "read", 1)

    for changes <- [
          %{principal: "other"},
          %{scope: "other"},
          %{credential_id: "missing"},
          %{expires_at: 2000},
          %{proof: <<0::256>>},
          %{proof: "bad"},
          %{principal: nil}
        ] do
      assert {:error, :unauthorized} =
               Credentials.reauthorize(context.credentials, struct(access, changes), "read", 1)
    end

    assert {:error, :unauthorized} = Credentials.reauthorize(context.credentials, nil, "read", 1)
    {:ok, replacement_digest} = Credentials.generate_token() |> Credentials.token_digest()

    {:ok, changed} =
      Credentials.new(%{
        context.input
        | entries: [%{context.entry | token_sha256: replacement_digest}]
      })

    assert {:error, :unauthorized} = Credentials.reauthorize(changed, access, "read", 1)

    {:ok, reduced} =
      Credentials.new(%{
        context.input
        | entries: [%{context.entry | grants: %{"workshop" => ["ingest"]}}]
      })

    assert {:error, :forbidden} = Credentials.reauthorize(reduced, access, "read", 1)
    {:ok, other_instance} = Credentials.new(%{context.input | instance_id: "other-instance"})
    assert {:error, :unauthorized} = Credentials.reauthorize(other_instance, access, "read", 1)
    key = Credentials.derive_key(context.credentials, :cursor)
    refute key == Credentials.derive_key(context.credentials, :pseudonym)
    refute key == Credentials.derive_key(other_instance, :cursor)
    # Possession of a valid cursor cannot restore a removed permission.
    binding = %{instance: "instance-1", principal: "owner", scope: "workshop", purpose: "page"}
    data = %{"kind" => "state", "generation" => "1", "after" => "", "limit" => 10}
    {:ok, cursor} = Cursor.issue(key, binding, data, 1)
    assert {:ok, ^data} = Cursor.open(key, binding, cursor, 2)
    assert {:error, :forbidden} = Credentials.reauthorize(reduced, access, "read", 2)
  end

  test "configuration bounds reject malformed entries, duplicate identity and unsupported grants",
       context do
    for input <- [
          nil,
          %{},
          %{context.input | secret_key: "short"},
          %{context.input | instance_id: ""},
          %{context.input | entries: []},
          %{context.input | entries: List.duplicate(context.entry, 33)},
          %{context.input | entries: [context.entry, context.entry]},
          Map.put(context.input, :extra, true)
        ] do
      assert {:error, :invalid_credentials} = Credentials.new(input)
    end

    for entry <- [
          nil,
          %{},
          %{context.entry | id: nil},
          %{context.entry | token_sha256: "bad"},
          %{context.entry | token_sha256: String.duplicate("G", 64)},
          %{context.entry | expires_at: -1},
          %{context.entry | grants: %{}},
          %{context.entry | grants: %{"workshop" => ["read", "read"]}},
          %{context.entry | grants: %{"workshop" => ["custom"]}},
          %{context.entry | grants: %{"workshop" => []}},
          %{context.entry | grants: %{"workshop" => ["read" | :improper]}}
        ] do
      assert {:error, :invalid_credentials} = Credentials.new(%{context.input | entries: [entry]})
    end
  end
end
