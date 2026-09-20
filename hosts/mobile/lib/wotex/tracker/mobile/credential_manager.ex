defmodule Wotex.Tracker.Mobile.CredentialManager do
  @moduledoc """
  Binds device-only credential custody to volatile UI sessions and cache identity.

  The bearer credential exists only in this process, the volatile UI session
  store and the native secure-store call. Its inspected/status state is always
  redacted. Cached projections remain non-authoritative.
  """

  use GenServer
  alias Wotex.Tracker.Mobile.{Cache, NotificationRegistration}
  alias Wotex.Tracker.UI.Sessions

  @schema "wtr.mobile-credential.v1"
  @account_schema "wtr.mobile-account.v1"
  @maximum_time 9_007_199_254_740_991
  @keys ~w(name sessions cache origin secure_store clock notification_registration)a

  @doc "Starts one mobile credential/cache lifecycle owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with {:ok, state, server_options} <- configuration(options) do
      GenServer.start_link(__MODULE__, state, server_options)
    end
  end

  def start_link(_), do: {:error, :invalid_configuration}

  @doc false
  @spec retain(GenServer.server(), map()) :: :ok | {:error, :unavailable}
  def retain(server, credential), do: call(server, {:retain, credential})

  @doc false
  @spec release(GenServer.server(), map()) :: :ok | {:error, :unavailable}
  def release(server, credential), do: call(server, {:release, credential})

  @doc "Returns the restored volatile browser-session identifier, when present."
  @spec browser_session(GenServer.server()) :: {:ok, String.t()} | :none
  def browser_session(server) do
    GenServer.call(server, :browser_session)
  catch
    :exit, _ -> :none
  end

  @doc "Reports only non-secret lifecycle state."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> %{credential: false, session: false, storage: :unavailable}
  end

  @doc false
  @spec put_projection(GenServer.server(), atom(), String.t(), map(), boolean(), integer()) ::
          :ok | {:error, atom()}
  def put_projection(server, kind, key, projection, complete, now),
    do: call(server, {:put_projection, kind, key, projection, complete, now})

  @doc false
  @spec read_projection(GenServer.server(), atom(), String.t(), integer()) ::
          {:ok, map()} | {:error, atom()}
  def read_projection(server, kind, key, now),
    do: call(server, {:read_projection, kind, key, now})

  @doc false
  @spec offline_identity(GenServer.server(), String.t(), integer()) ::
          {:ok, map()} | {:error, :unavailable}
  def offline_identity(server, scope, now), do: call(server, {:offline_identity, scope, now})

  @doc false
  @spec notification_context(GenServer.server()) ::
          {:ok, %{session_id: String.t(), endpoint_id: String.t()}} | {:error, :unavailable}
  def notification_context(server), do: call(server, :notification_context)

  @impl true
  def init(state), do: {:ok, state, {:continue, :restore}}

  @impl true
  def handle_continue(:restore, state) do
    {:noreply, restore(state)}
  end

  @impl true
  def handle_call(:browser_session, _from, state) do
    state = ensure_session(state)
    result = if is_binary(state.session_id), do: {:ok, state.session_id}, else: :none
    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    result = %{
      credential: state.credential?,
      session: is_binary(state.session_id),
      storage: state.storage
    }

    {:reply, result, state}
  end

  def handle_call({:retain, credential}, _from, state) do
    case retain_credential(state, credential) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:release, _credential}, _from, state) do
    case clear(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, state} -> {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:put_projection, kind, key, projection, complete, now}, _from, state) do
    result =
      if is_map(state.account),
        do: Cache.put(state.cache, state.account, kind, key, projection, now, complete, now),
        else: {:error, :account_mismatch}

    {:reply, result, state}
  catch
    :exit, _ -> {:reply, {:error, :cache_unavailable}, state}
  end

  def handle_call({:read_projection, kind, key, now}, _from, state) do
    result =
      if is_map(state.account),
        do: Cache.read(state.cache, state.account, kind, key, now),
        else: {:error, :account_mismatch}

    {:reply, result, state}
  catch
    :exit, _ -> {:reply, {:error, :cache_unavailable}, state}
  end

  def handle_call({:offline_identity, scope, now}, _from, state) do
    result =
      with true <- state.credential?,
           %{"scope" => ^scope, "expires_at" => expires} <- state.access,
           true <- is_integer(now) and now < expires do
        {:ok,
         %{
           "scope" => scope,
           "can_enroll" => false,
           "can_ingest" => false,
           "can_read_raw" => false,
           "can_manage_queries" => false,
           "can_interact" => false,
           "_offline" => true
         }}
      else
        _ -> {:error, :unavailable}
      end

    {:reply, result, state}
  end

  def handle_call(:notification_context, _from, state) do
    result =
      with true <- state.credential?,
           session_id when is_binary(session_id) <- state.session_id,
           installation_id when is_binary(installation_id) <- state.installation_id do
        {:ok,
         %{
           session_id: session_id,
           endpoint_id: notification_endpoint_id(installation_id)
         }}
      else
        _ -> {:error, :unavailable}
      end

    {:reply, result, state}
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:log, [])
  end

  defp configuration(options) do
    name = Keyword.get(options, :name)
    sessions = Keyword.get(options, :sessions)
    cache = Keyword.get(options, :cache)
    origin = Keyword.get(options, :origin)
    secure_store = Keyword.get(options, :secure_store)
    clock = Keyword.get(options, :clock)
    notification_registration = Keyword.get(options, :notification_registration)

    if valid_options?(options) and
         Enum.all?([
           valid_server?(sessions),
           valid_server?(cache),
           canonical_origin?(origin),
           storage?(secure_store),
           is_function(clock, 0),
           valid_name?(name),
           optional_server?(notification_registration)
         ]) do
      state = %{
        sessions: sessions,
        cache: cache,
        origin: origin,
        secure_store: secure_store,
        clock: clock,
        notification_registration: notification_registration,
        installation_id: nil,
        credential?: false,
        session_id: nil,
        account: nil,
        access: nil,
        storage: :ready
      }

      {:ok, state, if(name, do: [name: name], else: [])}
    else
      {:error, :invalid_configuration}
    end
  end

  defp restore(state) do
    with {:ok, state} <- installation(state),
         {:ok, envelope} <- fetch(state, :credential),
         {:ok, stored} <- decode(envelope, state),
         {:ok, account} <- bind(state, stored.access) do
      restore_session(%{state | account: account, access: stored.access}, stored)
    else
      {:error, :not_found} -> purge_without_credential(state)
      {:error, :expired} -> cleared(state)
      {:error, :invalid_data} -> cleared(state)
      {:error, :unavailable} -> %{state | storage: :unavailable}
      {:error, :cache_unavailable} -> %{state | storage: :unavailable}
    end
  end

  defp restore_session(state, stored) do
    case Sessions.restore(state.sessions, stored.token, stored.scope) do
      {:ok, %{"id" => id, "access" => access}} ->
        credential = %{
          token: stored.token,
          scope: stored.scope,
          access: access,
          session_id: id
        }

        case retain_credential(state, credential) do
          {:ok, state} ->
            state

          {:error, state} ->
            Sessions.discard(state.sessions, id)
            state
        end

      {:error, %{"code" => "unauthorized"}} ->
        cleared(state)

      {:error, %{"code" => "storage_unavailable"}} ->
        restore_cached_session(state, stored)

      {:error, _} ->
        %{state | credential?: true, session_id: nil, storage: :ready}
    end
  end

  defp retain_credential(state, credential) do
    with {:ok, state} <- installation(state),
         {:ok, stored} <- credential(credential, state),
         {:ok, encoded} <- Jason.encode(stored.envelope),
         :ok <- put(state, :credential, encoded),
         {:ok, account} <- bind(state, stored.access) do
      state =
        %{
          state
          | credential?: true,
            session_id: credential.session_id,
            account: account,
            access: stored.access,
            storage: :ready
        }

      _ = NotificationRegistration.retry(state.notification_registration)
      {:ok, state}
    else
      _ -> rollback(state)
    end
  end

  defp credential(
         %{token: token, scope: scope, access: access, session_id: session_id},
         state
       )
       when is_binary(token) and byte_size(token) in 1..256 and is_binary(scope) and
              byte_size(scope) in 1..128 and is_binary(session_id) do
    with true <- canonical_session_id?(session_id),
         {:ok, access} <- access(access, scope, state.clock.()) do
      envelope =
        Map.merge(access, %{"schema" => @schema, "origin" => state.origin, "token" => token})

      {:ok, %{envelope: envelope, access: access}}
    end
  end

  defp credential(_, _), do: {:error, :invalid_data}

  defp decode(encoded, state) do
    with {:ok, envelope} <- Jason.decode(encoded),
         %{
           "schema" => @schema,
           "origin" => origin,
           "token" => token,
           "scope" => scope,
           "credential_id" => credential,
           "principal" => principal,
           "expires_at" => expires
         } <- envelope,
         true <- map_size(envelope) == 7 and origin == state.origin,
         true <- is_binary(token) and byte_size(token) in 1..256,
         {:ok, access} <-
           access(
             %{
               "scope" => scope,
               "credential_id" => credential,
               "principal" => principal,
               "expires_at" => expires
             },
             scope,
             state.clock.()
           ) do
      {:ok, %{token: token, scope: scope, access: access}}
    else
      {:error, :expired} -> {:error, :expired}
      _ -> {:error, :invalid_data}
    end
  rescue
    _ -> {:error, :invalid_data}
  end

  defp access(
         %{
           "scope" => scope,
           "credential_id" => credential,
           "principal" => principal,
           "expires_at" => expires
         } = access,
         expected_scope,
         now
       )
       when map_size(access) == 4 do
    cond do
      not valid_access_fields?(scope, credential, principal, expires, expected_scope) ->
        {:error, :invalid_data}

      expires not in 0..@maximum_time ->
        {:error, :invalid_data}

      expires <= now ->
        {:error, :expired}

      true ->
        {:ok, access}
    end
  end

  defp access(_, _, _), do: {:error, :invalid_data}

  defp installation(%{installation_id: id} = state) when is_binary(id), do: {:ok, state}

  defp installation(state) do
    case fetch(state, :installation_id) do
      {:ok, id} ->
        if installation_id?(id),
          do: {:ok, %{state | installation_id: id, storage: :ready}},
          else: replace_installation(state)

      {:error, :not_found} ->
        create_installation(state)

      {:error, :unavailable} = error ->
        error
    end
  end

  defp replace_installation(state) do
    with :ok <- delete(state, :credential),
         :ok <- delete(state, :installation_id),
         :ok <- purge(state) do
      create_installation(%{
        state
        | credential?: false,
          session_id: nil,
          account: nil,
          access: nil
      })
    else
      _ -> {:error, :unavailable}
    end
  end

  defp create_installation(state) do
    id = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    case put(state, :installation_id, id) do
      :ok -> {:ok, %{state | installation_id: id, storage: :ready}}
      _ -> {:error, :unavailable}
    end
  end

  defp installation_id?(id) do
    case Base.url_decode64(id, padding: false) do
      {:ok, decoded} ->
        byte_size(decoded) == 32 and Base.url_encode64(decoded, padding: false) == id

      :error ->
        false
    end
  end

  defp canonical_session_id?(id) do
    case Base.url_decode64(id, padding: false) do
      {:ok, decoded} ->
        byte_size(decoded) == 32 and Base.url_encode64(decoded, padding: false) == id

      :error ->
        false
    end
  end

  defp ensure_session(%{session_id: id} = state) when is_binary(id) do
    case Sessions.list(state.sessions, id) do
      {:ok, _} -> state
      _ -> restore(%{state | session_id: nil})
    end
  end

  defp ensure_session(%{credential?: true} = state), do: restore(state)
  defp ensure_session(state), do: state

  defp bind(state, access) do
    account = %{
      "schema" => @account_schema,
      "origin" => state.origin,
      "principal" => access["principal"],
      "scope" => access["scope"],
      "credential_id" => access["credential_id"],
      "installation_id" => state.installation_id,
      "expires_at" => access["expires_at"]
    }

    case Cache.bind(state.cache, account, state.clock.()) do
      :ok -> {:ok, account}
      error -> error
    end
  catch
    :exit, _ -> {:error, :cache_unavailable}
  end

  defp rollback(state) do
    _ = delete(state, :credential)
    _ = purge(state)

    {:error,
     %{
       state
       | credential?: false,
         session_id: nil,
         account: nil,
         access: nil,
         storage: :unavailable
     }}
  end

  defp clear(state) do
    with :ok <- delete(state, :credential),
         :ok <- purge(state) do
      {:ok,
       %{
         state
         | credential?: false,
           session_id: nil,
           account: nil,
           access: nil,
           storage: :ready
       }}
    else
      _ -> {:error, %{state | storage: :unavailable}}
    end
  end

  defp cleared(state) do
    case clear(state) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  defp purge_without_credential(state) do
    case purge(state) do
      :ok ->
        %{state | credential?: false, session_id: nil, account: nil, access: nil, storage: :ready}

      _ ->
        %{
          state
          | credential?: false,
            session_id: nil,
            account: nil,
            access: nil,
            storage: :unavailable
        }
    end
  end

  defp purge(state) do
    Cache.purge(state.cache)
  catch
    :exit, _ -> {:error, :cache_unavailable}
  end

  defp restore_cached_session(state, stored) do
    case Sessions.restore_cached(state.sessions, stored.token, stored.scope, stored.access) do
      {:ok, %{"id" => id}} ->
        %{
          state
          | credential?: true,
            session_id: id,
            access: stored.access,
            storage: :ready
        }

      _ ->
        %{state | credential?: true, session_id: nil, storage: :ready}
    end
  end

  defp fetch(state, key), do: storage_call(state.secure_store, :fetch, [key])
  defp put(state, key, value), do: storage_call(state.secure_store, :put, [key, value])
  defp delete(state, key), do: storage_call(state.secure_store, :delete, [key])

  defp storage_call({module, context}, function, arguments) do
    apply(module, function, arguments ++ [context])
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp valid_options?(options) do
    Keyword.keyword?(options) and length(options) == map_size(Map.new(options)) and
      Keyword.keys(options) -- @keys == []
  end

  defp valid_name?(name), do: is_nil(name) or is_atom(name)

  defp valid_access_fields?(scope, credential, principal, expires, expected_scope) do
    scope == expected_scope and is_integer(expires) and
      Enum.all?([scope, credential, principal], fn value ->
        is_binary(value) and byte_size(value) in 1..256
      end)
  end

  defp valid_server?(server), do: is_pid(server) or is_atom(server) or is_tuple(server)
  defp optional_server?(nil), do: true
  defp optional_server?(server), do: valid_server?(server)

  defp notification_endpoint_id(installation_id) do
    digest = :crypto.hash(:sha256, "wotex-ios-notification-v1:" <> installation_id)
    "ios-" <> Base.url_encode64(digest, padding: false)
  end

  defp storage?({module, _}) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :fetch, 2) and
      function_exported?(module, :put, 3) and function_exported?(module, :delete, 2)
  end

  defp storage?(_), do: false

  defp canonical_origin?(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
      uri.path in [nil, ""] and URI.to_string(uri) == origin
  end

  defp canonical_origin?(_), do: false
end
