defmodule Wotex.Tracker.Service.Credentials do
  @moduledoc """
  Explicit host credential configuration containing hashes, never bearer tokens.

  A host supplies a stable instance identifier, 32 random secret bytes, and at
  most 32 entries. Each entry pins its principal, SHA-256 token digest, expiry
  and exact scope/permission grants. There is no ambient configuration, default
  credential, clock read or application process. Access proofs bind the current
  credential digest and instance; replacing a digest invalidates old access.

  Reauthorization consumes the latest configuration. The service must also
  check durable revocation at admission and delivery, inside the store transaction
  for mutations. These pure values do not themselves implement revocation storage.
  """

  alias Wotex.Tracker.Service.{Access, Codec}

  @permissions ~w(read ingest enroll raw admin interact)
  @derive {Inspect, only: [:instance_id]}
  @enforce_keys [:instance_id, :secret_key, :entries]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{instance_id: String.t(), secret_key: binary(), entries: [map()]}

  @doc "Admits a finite, explicit set of hashed credentials and exact scope grants."
  @spec new(term()) :: {:ok, t()} | {:error, :invalid_credentials}
  def new(%{instance_id: instance, secret_key: key, entries: entries} = input)
      when map_size(input) == 3 do
    with true <- Codec.id?(instance) and is_binary(key) and byte_size(key) == 32,
         true <- bounded?(entries, 32) and entries != [],
         true <- Enum.all?(entries, &entry?/1),
         true <- unique?(entries, :id) and unique?(entries, :token_sha256) do
      {:ok, struct!(__MODULE__, input)}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def new(_), do: {:error, :invalid_credentials}

  @doc "Re-admits host configuration without exposing its opaque fields to other modules."
  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_credentials}
  def validate(%__MODULE__{} = credentials), do: new(Map.from_struct(credentials))
  def validate(_), do: {:error, :invalid_credentials}

  @doc "Returns the non-secret stable host identity used to bind sessions and cursors."
  @spec instance_id(t()) :: String.t()
  def instance_id(%__MODULE__{instance_id: instance}), do: instance

  @doc false
  @spec scopes(t()) :: [String.t()]
  def scopes(%__MODULE__{entries: entries}),
    do: entries |> Enum.flat_map(&Map.keys(&1.grants)) |> Enum.uniq() |> Enum.sort()

  @doc "Generates a 256-bit bearer token; the host must deliver/store it confidentially."
  @spec generate_token() :: String.t()
  def generate_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  @doc "Computes the configuration digest of a canonical 256-bit bearer token."
  @spec token_digest(term()) :: {:ok, String.t()} | {:error, :invalid_token}
  def token_digest(token) do
    if token?(token), do: {:ok, hash(token)}, else: {:error, :invalid_token}
  end

  @doc false
  @spec configured?(t(), term(), term(), term()) :: boolean()
  def configured?(%__MODULE__{} = credentials, token, scope, permission) do
    with true <- token?(token) and Codec.id?(scope) and permission in @permissions,
         digest = hash(token),
         entry when not is_nil(entry) <-
           Enum.find(credentials.entries, &equal?(&1.token_sha256, digest)) do
      permission in Map.get(entry.grants, scope, [])
    else
      _ -> false
    end
  end

  def configured?(_, _, _, _), do: false

  @doc """
  Lists, in ID order, the configured credentials granting any permission in one scope.

  Each item carries the credential ID, principal, that scope's sorted permissions
  and expiry. Token digests, other scopes' grants and the secret key are omitted.
  """
  @spec inventory(t(), term()) :: [map()]
  def inventory(%__MODULE__{entries: entries}, scope) do
    entries
    |> Enum.filter(&Map.has_key?(&1.grants, scope))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(
      &%{
        id: &1.id,
        principal: &1.principal,
        permissions: Enum.sort(Map.fetch!(&1.grants, scope)),
        expires_at: &1.expires_at
      }
    )
  end

  @doc "Authenticates an ephemeral token for exactly one scope and permission at explicit time."
  @spec authenticate(t(), term(), term(), term(), term()) :: {:ok, Access.t()} | {:error, atom()}
  def authenticate(%__MODULE__{} = credentials, token, scope, permission, now) do
    with true <- token?(token) and Codec.id?(scope) and Codec.time?(now),
         digest = hash(token),
         entry when not is_nil(entry) <-
           Enum.find(credentials.entries, &equal?(&1.token_sha256, digest)),
         :ok <- grants(entry, scope, permission, now) do
      data = %{
        credential_id: entry.id,
        principal: entry.principal,
        scope: scope,
        expires_at: entry.expires_at
      }

      {:ok, struct!(Access, Map.put(data, :proof, proof(credentials, entry, data)))}
    else
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Rechecks proof, current grants and expiry; old snapshots never grant new permissions."
  @spec reauthorize(term(), term(), term(), term()) :: :ok | {:error, atom()}
  def reauthorize(%__MODULE__{} = credentials, %Access{} = access, permission, now) do
    with true <- access?(access) and Codec.time?(now),
         entry when not is_nil(entry) <-
           Enum.find(credentials.entries, &(&1.id == access.credential_id)),
         true <- entry.principal == access.principal and now < access.expires_at,
         true <-
           equal?(
             access.proof,
             proof(credentials, entry, Map.from_struct(access) |> Map.delete(:proof))
           ),
         :ok <- grants(entry, access.scope, permission, now) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  def reauthorize(_, _, _, _), do: {:error, :unauthorized}

  @doc "Derives a purpose-specific private host key without exposing the master in inspection."
  @spec derive_key(t(), :cursor | :pseudonym | :notification) :: binary()
  def derive_key(%__MODULE__{secret_key: key, instance_id: instance}, purpose)
      when purpose in [:cursor, :pseudonym, :notification],
      do:
        :crypto.mac(
          :hmac,
          :sha256,
          key,
          Codec.encode!(%{
            "instance" => instance,
            "purpose" => Atom.to_string(purpose),
            "version" => "1"
          })
        )

  defp entry?(
         %{
           id: id,
           principal: principal,
           token_sha256: digest,
           grants: grants,
           expires_at: expires
         } = entry
       )
       when map_size(entry) == 5 do
    Codec.id?(id) and Codec.id?(principal) and digest?(digest) and Codec.time?(expires) and
      is_map(grants) and not is_struct(grants) and map_size(grants) in 1..16 and
      Enum.all?(grants, &grant?/1)
  end

  defp entry?(_), do: false

  defp grant?({scope, permissions}) do
    Codec.id?(scope) and bounded?(permissions, 6) and permissions != [] and
      Enum.all?(permissions, &(&1 in @permissions)) and Enum.uniq(permissions) == permissions
  end

  defp grants(entry, scope, permission, now) do
    cond do
      now >= entry.expires_at ->
        {:error, :unauthorized}

      permission not in @permissions or permission not in Map.get(entry.grants, scope, []) ->
        {:error, :forbidden}

      true ->
        :ok
    end
  end

  defp proof(credentials, entry, data) do
    payload =
      data
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("credential_digest", entry.token_sha256)
      |> Map.put("instance", credentials.instance_id)

    :crypto.mac(:hmac, :sha256, credentials.secret_key, ["wtr.access.v1:", Codec.encode!(payload)])
  end

  defp access?(access) do
    Enum.all?([access.credential_id, access.principal, access.scope], &Codec.id?/1) and
      Codec.time?(access.expires_at) and is_binary(access.proof) and byte_size(access.proof) == 32
  end

  defp token?(token) when is_binary(token) and byte_size(token) == 43 do
    case Base.url_decode64(token, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == token

      _ ->
        false
    end
  end

  defp token?(_), do: false
  defp hash(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  defp equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp equal?(_, _), do: false

  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: match?({:ok, _}, Base.decode16(digest, case: :lower))

  defp digest?(_), do: false

  defp unique?(entries, key),
    do: entries |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() |> length() == length(entries)

  defp bounded?([], _), do: true
  defp bounded?([_ | rest], remaining) when remaining > 0, do: bounded?(rest, remaining - 1)
  defp bounded?(_, _), do: false
end
