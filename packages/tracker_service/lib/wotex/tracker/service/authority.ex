defmodule Wotex.Tracker.Service.Authority do
  @moduledoc false

  alias Wotex.Tracker.Service.{Access, Codec, Credentials, SQL}

  # A real host supplies its clock at the storage boundary so queued requests
  # cannot keep an expired authorization alive using their admission timestamp.
  def now(%{clock: nil}, fallback), do: fallback

  def now(%{clock: clock}, _fallback) do
    value = clock.()
    if Codec.time?(value), do: value, else: throw({:storage, :storage_unavailable})
  end

  def fresh!(nil, %{authority: nil}, _now), do: :ok

  def fresh!(credentials, update, now) do
    # BEGIN IMMEDIATE excludes another revocation writer. Recheck expiration,
    # without mistaking this transaction's intentional self-revocation for a
    # revocation that preceded admission.
    Enum.each(permissions(update), fn permission ->
      case Credentials.reauthorize(credentials, update.authority, permission, now) do
        :ok -> :ok
        {:error, reason} -> throw({:storage, reason})
      end
    end)
  end

  def mutation!(_db, nil, %{authority: nil}), do: :ok

  def mutation!(db, credentials, update) do
    case update.authority do
      %Access{principal: principal} when principal == update.principal ->
        Enum.each(
          permissions(update),
          &check!(db, credentials, update.authority, update.scope, &1, update.now)
        )

      _ ->
        throw({:storage, :unauthorized})
    end
  end

  def check!(
        db,
        credentials,
        %Access{scope: scope} = access,
        scope,
        permission,
        now
      ) do
    case Credentials.reauthorize(credentials, access, permission, now) do
      :ok ->
        case SQL.rows!(
               db,
               "SELECT 1 FROM records WHERE scope=? AND kind='access' AND id=? LIMIT 1",
               [scope, access.credential_id]
             ) do
          [] -> :ok
          _ -> throw({:storage, :unauthorized})
        end

      {:error, reason} ->
        throw({:storage, reason})
    end
  end

  def check!(_, _, _, _, _, _), do: throw({:storage, :unauthorized})

  def valid?(nil), do: true

  def valid?(%Access{} = access) do
    Enum.all?([access.credential_id, access.principal, access.scope], &Codec.id?/1) and
      Codec.time?(access.expires_at) and is_binary(access.proof) and byte_size(access.proof) == 32
  end

  def valid?(_), do: false

  def projection(nil), do: nil

  def projection(access) do
    %{
      "credential_id" => access.credential_id,
      "principal" => access.principal,
      "scope" => access.scope,
      "expires_at" => access.expires_at,
      "proof" => Base.encode64(access.proof)
    }
  end

  defp permissions(update) do
    record_permissions =
      Enum.map(update.records, fn record ->
        case record.kind do
          kind when kind in ~w(access policies saved_queries) -> "admin"
          kind when kind in ~w(enrollments things) -> "enroll"
          kind when kind in ~w(state evidence) -> derivative_permission(update, record.id)
          _ -> "ingest"
        end
      end)

    permissions =
      if(update.observation, do: ["ingest"], else: []) ++
        if(update.publication, do: ["enroll"], else: []) ++ record_permissions

    if permissions == [], do: ["admin"], else: Enum.uniq(permissions)
  end

  defp derivative_permission(update, id) do
    if Enum.any?(update.records, &(&1.kind == "things" and &1.id == id and not is_nil(&1.value))),
      do: "enroll",
      else: "ingest"
  end
end
