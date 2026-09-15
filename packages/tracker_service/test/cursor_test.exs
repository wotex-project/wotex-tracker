defmodule Wotex.Tracker.Service.CursorTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Wotex.Tracker.Service.{Codec, Cursor}

  setup do
    %{
      key: :crypto.strong_rand_bytes(32),
      binding: %{instance: "server", principal: "owner", scope: "workshop", purpose: "page"},
      data: %{
        "kind" => "observations",
        "generation" => "1",
        "after" => "private-hardware-identifier",
        "limit" => 25
      }
    }
  end

  property "cursor bytes hide private sort keys and bind every authority field", context do
    check all(now <- integer(0..10_000)) do
      assert {:ok, cursor} = Cursor.issue(context.key, context.binding, context.data, now)
      assert {:ok, restored} = Cursor.open(context.key, context.binding, cursor, now)
      assert restored == context.data
      "wtrc1." <> encoded = cursor
      refute Base.url_decode64!(encoded, padding: false) =~ "private-hardware-identifier"

      for field <- [:instance, :principal, :scope] do
        assert {:error, :invalid_cursor} =
                 Cursor.open(context.key, Map.put(context.binding, field, "other"), cursor, now)
      end

      assert {:error, :invalid_cursor} =
               Cursor.open(context.key, %{context.binding | purpose: "events"}, cursor, now)

      assert {:error, :invalid_cursor} =
               Cursor.open(:crypto.strong_rand_bytes(32), context.binding, cursor, now)

      assert {:error, :cursor_expired} =
               Cursor.open(context.key, context.binding, cursor, now + 604_800_000)
    end
  end

  test "fresh nonces differ; malformed, truncated, tampered and future tokens fail", context do
    {:ok, first} = Cursor.issue(context.key, context.binding, context.data, 10)
    {:ok, second} = Cursor.issue(context.key, context.binding, context.data, 10)
    refute first == second
    assert {:error, :invalid_cursor} = Cursor.open(context.key, context.binding, first, 9)
    "wtrc1." <> encoded = first
    <<byte, rest::binary>> = Base.url_decode64!(encoded, padding: false)

    tampered =
      "wtrc1." <> Base.url_encode64(<<Bitwise.bxor(byte, 1), rest::binary>>, padding: false)

    for token <- [
          nil,
          "",
          "wtrc0.abc",
          "wtrc1.=",
          "wtrc1.YQ",
          first <> "=",
          tampered,
          String.duplicate("x", 4097)
        ] do
      assert {:error, :invalid_cursor} = Cursor.open(context.key, context.binding, token, 10)
    end

    for {key, binding, data, now} <- [
          {"bad", context.binding, context.data, 10},
          {context.key, %{}, context.data, 10},
          {context.key, context.binding, %{}, 10},
          {context.key, context.binding, context.data, -1},
          {context.key, context.binding, %{context.data | "limit" => 101}, 10},
          {context.key, context.binding, %{context.data | "generation" => "01"}, 10}
        ],
        do: assert({:error, :invalid_cursor} = Cursor.issue(key, binding, data, now))
  end

  test "event cursors distinguish snapshot high water from positions within one multi-event generation",
       context do
    binding = %{context.binding | purpose: "events"}

    data = %{
      "kind" => "events",
      "generation" => "2",
      "after" => "5",
      "snapshot_generation" => "2",
      "limit" => 1
    }

    {:ok, cursor} = Cursor.issue(context.key, binding, data, 10)
    assert {:ok, ^data} = Cursor.open(context.key, binding, cursor, 10)
    resumed = %{data | "after" => "6", "snapshot_generation" => nil}
    {:ok, cursor} = Cursor.issue(context.key, binding, resumed, 10)
    assert {:ok, ^resumed} = Cursor.open(context.key, binding, cursor, 10)
    assert {:error, :invalid_cursor} = Cursor.issue(context.key, context.binding, data, 10)

    assert {:error, :invalid_cursor} =
             Cursor.issue(context.key, binding, %{data | "after" => "private-id"}, 10)
  end

  test "authenticated payloads still require the exact versioned shape and expiry contract",
       context do
    base = %{
      "schema" => "wtr.cursor.v1",
      "data" => context.data,
      "issued_at" => 10,
      "expires_at" => 604_800_010
    }

    for payload <- [
          "invalid JSON",
          "{}",
          Codec.encode!(%{base | "expires_at" => 20}),
          Codec.encode!(%{base | "schema" => "wtr.cursor.v2"}),
          Codec.encode!(%{base | "issued_at" => false})
        ] do
      token = encrypt(context.key, context.binding, payload)
      assert {:error, :invalid_cursor} = Cursor.open(context.key, context.binding, token, 10)
    end
  end

  defp encrypt(key, binding, plaintext) do
    nonce = :crypto.strong_rand_bytes(12)

    aad = [
      "wtr.cursor.v1:",
      Codec.encode!(Map.new(binding, fn {key, value} -> {Atom.to_string(key), value} end))
    ]

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

    "wtrc1." <> Base.url_encode64(nonce <> tag <> ciphertext, padding: false)
  end
end
