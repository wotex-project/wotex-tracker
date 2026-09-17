defmodule Wotex.Tracker.Service.Cursor do
  @moduledoc """
  Authenticated encrypted resource, event and analytics cursors with explicit
  time and binding.

  AES-256-GCM keeps internal sort keys and observation identifiers out of URLs.
  Authentication binds instance, principal, scope and purpose. A valid cursor is
  not authorization; the service rechecks current grants on every read/delivery.
  Key rotation or a different instance invalidates old cursors. There is no
  fallback to the latest page on invalid or expired input.
  """

  alias Wotex.Tracker.Service.Codec

  @retention 604_800_000

  @doc "Issues a cursor with a fresh nonce and seven-day maximum lifetime."
  @spec issue(binary(), map(), map(), integer()) :: {:ok, String.t()} | {:error, atom()}
  def issue(key, binding, data, now) do
    with true <-
           key?(key) and binding?(binding) and data?(data) and purpose?(binding, data) and
             time?(now),
         {:ok, plaintext} <-
           Codec.encode(
             %{
               "schema" => "wtr.cursor.v1",
               "data" => data,
               "issued_at" => now,
               "expires_at" => now + @retention
             },
             2048
           ) do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad(binding), true)

      {:ok, "wtrc1." <> Base.url_encode64(nonce <> tag <> ciphertext, padding: false)}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  @doc "Authenticates, decrypts and checks an exact caller/scope/purpose binding."
  @spec open(binary(), map(), term(), integer()) :: {:ok, map()} | {:error, atom()}
  def open(key, binding, "wtrc1." <> token, now) when byte_size(token) in 1..4090 do
    with true <- key?(key) and binding?(binding) and time?(now),
         {:ok, <<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>> = decoded} <-
           Base.url_decode64(token, padding: false),
         true <- Base.url_encode64(decoded, padding: false) == token,
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad(binding),
             tag,
             false
           ),
         {:ok, payload} <- Codec.decode(plaintext) do
      payload(payload, binding, now)
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def open(_, _, _, _), do: {:error, :invalid_cursor}

  defp payload(
         %{
           "schema" => "wtr.cursor.v1",
           "data" => data,
           "issued_at" => issued,
           "expires_at" => expires
         } = payload,
         binding,
         now
       )
       when map_size(payload) == 4 do
    cond do
      not (data?(data) and purpose?(binding, data) and time?(issued) and is_integer(expires) and
             expires == issued + @retention and issued <= now) ->
        {:error, :invalid_cursor}

      now >= expires ->
        {:error, :cursor_expired}

      true ->
        {:ok, data}
    end
  end

  defp payload(_, _, _), do: {:error, :invalid_cursor}

  defp binding?(
         %{instance: instance, principal: principal, scope: scope, purpose: purpose} = binding
       )
       when map_size(binding) == 4,
       do:
         Enum.all?([instance, principal, scope], &Codec.id?/1) and
           purpose in ["page", "events", "history", "property", "analytics"]

  defp binding?(_), do: false

  defp data?(
         %{"kind" => kind, "generation" => generation, "after" => after_id, "limit" => limit} =
           data
       )
       when map_size(data) == 4 do
    kind in ~w(observations resolutions evidence enrollments things state policies saved_queries rules alerts) and
      match?({:ok, _}, Codec.generation(generation)) and (after_id == "" or Codec.id?(after_id)) and
      is_integer(limit) and limit in 1..100
  end

  defp data?(
         %{
           "kind" => "events",
           "generation" => generation,
           "after" => cursor,
           "snapshot_generation" => snapshot,
           "limit" => limit
         } = data
       )
       when map_size(data) == 5 do
    match?({:ok, _}, Codec.generation(generation)) and match?({:ok, _}, Codec.generation(cursor)) and
      (is_nil(snapshot) or match?({:ok, _}, Codec.generation(snapshot))) and is_integer(limit) and
      limit in 1..100
  end

  defp data?(
         %{
           "kind" => "history",
           "resource" => resource,
           "id" => id,
           "generation" => generation,
           "after" => position,
           "limit" => limit
         } = data
       )
       when map_size(data) == 6 do
    resource in ~w(observations resolutions evidence enrollments things state saved_queries rules policies alerts) and
      Codec.id?(id) and
      match?({:ok, _}, Codec.generation(generation)) and
      match?({:ok, _}, Codec.generation(position)) and
      is_integer(limit) and limit in 1..100
  end

  defp data?(
         %{
           "kind" => "property",
           "thing_id" => thing,
           "property" => name,
           "generation" => generation,
           "after" => position,
           "snapshot_generation" => snapshot
         } = data
       )
       when map_size(data) == 6 do
    Codec.id?(thing) and Codec.id?(name) and
      match?({:ok, _}, Codec.generation(generation)) and
      match?({:ok, _}, Codec.generation(position)) and
      (is_nil(snapshot) or match?({:ok, _}, Codec.generation(snapshot)))
  end

  defp data?(
         %{
           "kind" => "analytics",
           "generation" => generation,
           "query_identity" => identity,
           "page_size" => page_size,
           "page_index" => page_index
         } = data
       )
       when map_size(data) == 5 do
    match?({:ok, _}, Codec.generation(generation)) and Codec.id?(identity) and
      is_integer(page_size) and page_size in 1..1_000 and is_integer(page_index) and
      page_index in 1..999
  end

  defp data?(_), do: false
  defp purpose?(%{purpose: "events"}, data), do: data["kind"] == "events"
  defp purpose?(%{purpose: "history"}, data), do: data["kind"] == "history"
  defp purpose?(%{purpose: "property"}, data), do: data["kind"] == "property"
  defp purpose?(%{purpose: "analytics"}, data), do: data["kind"] == "analytics"

  defp purpose?(%{purpose: "page"}, data),
    do: data["kind"] not in ["events", "history", "property", "analytics"]

  defp key?(key), do: is_binary(key) and byte_size(key) == 32
  defp time?(now), do: Codec.time?(now) and now <= 9_007_199_254_740_991 - @retention

  defp aad(binding),
    do: [
      "wtr.cursor.v1:",
      Codec.encode!(Map.new(binding, fn {key, value} -> {Atom.to_string(key), value} end))
    ]
end
