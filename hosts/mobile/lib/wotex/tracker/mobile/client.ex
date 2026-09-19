defmodule Wotex.Tracker.Mobile.Client do
  @moduledoc """
  Adds bounded account-isolated offline reads to the shared remote UI client.

  Remote authorization remains authoritative. Successful closed read
  projections refresh the local cache; only a service-unavailable read may fall
  back to the exact cached request. Mutations, raw evidence, access management
  and operation recovery never use this cache.
  """

  @behaviour Wotex.Tracker.UI.Client
  alias Wotex.Tracker.Mobile.CredentialManager
  alias Wotex.Tracker.UI.Remote

  @derive {Inspect, only: []}
  @enforce_keys [:remote, :credentials]
  defstruct @enforce_keys

  @type t :: %__MODULE__{remote: Remote.t(), credentials: GenServer.server()}

  @doc "Builds the mobile-only presentation client composition."
  @spec new(Remote.t(), GenServer.server()) :: t()
  def new(%Remote{} = remote, credentials) do
    %__MODULE__{remote: remote, credentials: credentials}
  end

  @impl true
  def request(%__MODULE__{} = client, token, scope, action, arguments, now) do
    result = Remote.request(client.remote, token, scope, action, arguments, now)

    case {result, projection(action, arguments)} do
      {{:ok, value}, {kind, key}} when is_map(value) ->
        _ =
          CredentialManager.put_projection(
            client.credentials,
            kind,
            key,
            value,
            complete?(value),
            now
          )

        result

      {{:error, %{"code" => "storage_unavailable"}}, {kind, key}} ->
        cached(client.credentials, kind, key, now, result)

      {{:error, %{"code" => "storage_unavailable"}}, :identity} ->
        offline_identity(client.credentials, scope, now, result)

      _ ->
        result
    end
  rescue
    _ -> {:error, %{"code" => "storage_unavailable"}}
  catch
    _, _ -> {:error, %{"code" => "storage_unavailable"}}
  end

  def request(_, _, _, _, _, _), do: {:error, %{"code" => "invalid_request"}}

  defp cached(credentials, kind, key, now, fallback) do
    case CredentialManager.read_projection(credentials, kind, key, now) do
      {:ok, %{"projection" => projection} = envelope} when is_map(projection) ->
        {:ok,
         Map.put(
           projection,
           "_offline",
           Map.take(envelope, ~w(source synchronized_at age_ms complete expires_at))
         )}

      _ ->
        fallback
    end
  end

  defp offline_identity(credentials, scope, now, fallback) do
    case CredentialManager.offline_identity(credentials, scope, now) do
      {:ok, identity} -> {:ok, identity}
      _ -> fallback
    end
  end

  defp projection(:authorize, arguments) when map_size(arguments) == 0, do: :identity

  defp projection(:list, %{"resource" => resource} = arguments)
       when resource in ~w(enrollments state saved_queries) and map_size(arguments) in 1..2,
       do: {resource_kind(resource), key(:list, arguments)}

  defp projection(:get, %{"resource" => resource} = arguments)
       when resource in ~w(enrollments state things saved_queries) and map_size(arguments) == 2,
       do: {resource_kind(resource), key(:get, arguments)}

  defp projection(action, arguments)
       when action in [:thing_rules, :arming, :read_property] and is_map(arguments),
       do: {:overview, key(action, arguments)}

  defp projection(action, arguments)
       when action in [:history, :thing_trips, :trip_summary] and is_map(arguments),
       do: {:history, key(action, arguments)}

  defp projection(action, arguments)
       when action in [:analytics, :execute_saved_query] and is_map(arguments),
       do: {:dashboard, key(action, arguments)}

  defp projection(:route_history, arguments) when is_map(arguments),
    do: {:map, key(:route_history, arguments)}

  defp projection(_, _), do: nil

  defp resource_kind("saved_queries"), do: :dashboard
  defp resource_kind(_), do: :overview

  defp key(action, arguments) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({action, arguments}, [:deterministic]))
    Atom.to_string(action) <> ":" <> Base.url_encode64(digest, padding: false)
  end

  defp complete?(%{"cursor" => cursor}), do: is_nil(cursor)
  defp complete?(_), do: true
end
