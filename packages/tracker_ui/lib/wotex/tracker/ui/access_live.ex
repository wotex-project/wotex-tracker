defmodule Wotex.Tracker.UI.AccessLive do
  @moduledoc """
  Shows service access, browser sessions, registered notification installations
  and administrator credential revocation and successful-access audit.

  The page displays principal, scope, expiry, and grant categories without
  exposing the bearer token. Administrators also see the service's credential
  inventory for the scope: each configured credential's ID, principal,
  permissions, expiry and revocation status.

  Revoking the current credential requires a fresh credential ID and scope
  generation from the service, a stable operation reference, and explicit
  confirmation. A committed result ends this browser session. An uncertain
  result carries its operation reference to sign-in for later service lookup.

  Revoking another active credential captures the inventory generation and puts
  the credential ID and a fresh operation reference in the page address. A
  committed receipt counts only after the reloaded inventory shows the credential
  revoked; an uncertain result can be checked through the retained reference
  without submitting again.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.{Codec, Identifier}
  alias Wotex.Tracker.UI.{Auth, Presenter}
  alias Wotex.Tracker.UI.Sessions

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         access: nil,
         error: nil,
         revoke_context: nil,
         revoke_operation: nil,
         revoke_error: nil,
         credentials: nil,
         credentials_generation: nil,
         credentials_error: nil,
         other_id: nil,
         other_operation: nil,
         other_generation: nil,
         other_outcome: nil,
         other_error: nil,
         other_closed: false,
         browser_sessions: nil,
         sessions_error: nil,
         endpoints: nil,
         endpoints_generation: nil,
         endpoints_error: nil,
         endpoint_id: nil,
         endpoint_operation: nil,
         endpoint_generation: nil,
         endpoint_outcome: nil,
         endpoint_error: nil,
         endpoint_closed: false,
         access_audit: nil,
         access_audit_error: nil
       )}

  @impl true
  def handle_params(params, _, socket),
    do:
      {:noreply,
       socket
       |> load()
       |> activate_other(params["credential"], params["operation"])
       |> recover_other()
       |> activate_endpoint(params["endpoint"], params["endpoint_operation"])
       |> recover_endpoint()}

  @impl true
  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> clear_revoke() |> load()}

  def handle_event(
        "next-access-audit",
        _,
        %{assigns: %{access_audit: %{"cursor" => cursor}}} = socket
      )
      when is_binary(cursor),
      do: {:noreply, load_access_audit(socket, %{"cursor" => cursor})}

  def handle_event("newest-access-audit", _, socket),
    do: {:noreply, load_access_audit(socket)}

  def handle_event("prepare-revoke", _, socket) do
    if socket.assigns.identity["can_manage_queries"] do
      case Auth.request(socket, :revocation_context) do
        {:ok, %{"credential_id" => id, "expected_generation" => generation} = context}
        when is_binary(id) and is_binary(generation) ->
          {:noreply,
           assign(socket,
             revoke_context: context,
             revoke_operation: Identifier.uuid(),
             revoke_error: nil
           )}

        {:error, error} ->
          {:noreply, assign(clear_revoke(socket), revoke_error: error)}

        _ ->
          {:noreply,
           assign(clear_revoke(socket), revoke_error: %{"code" => "storage_unavailable"})}
      end
    else
      {:noreply, assign(clear_revoke(socket), revoke_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("cancel-revoke", _, socket), do: {:noreply, clear_revoke(socket)}

  def handle_event("confirm-revoke", %{"revoke" => %{"confirmed" => "yes"}}, socket) do
    case {socket.assigns.revoke_context, socket.assigns.revoke_operation} do
      {%{"credential_id" => id, "expected_generation" => generation}, operation}
      when is_binary(operation) ->
        result =
          Auth.request(socket, :revoke, %{
            "operation" => operation,
            "request" => %{"credential_id" => id, "expected_generation" => generation}
          })

        case result do
          {:ok, %{"outcome" => "committed"}} ->
            Sessions.logout(socket.assigns.sessions, socket.assigns.session_id)

            {:noreply,
             socket
             |> put_flash(:info, "Credential revoked. Sign in with a different credential.")
             |> redirect(to: "/sign-in")}

          {:ok, %{"outcome" => "unknown"}} ->
            Sessions.logout(socket.assigns.sessions, socket.assigns.session_id)

            {:noreply,
             socket
             |> put_flash(
               :info,
               "Revocation outcome unknown. Keep operation #{operation} for service lookup before retrying."
             )
             |> redirect(to: "/sign-in")}

          {:error, error} ->
            {:noreply, assign(clear_revoke(socket), revoke_error: error)}

          _ ->
            {:noreply, assign(socket, revoke_error: %{"code" => "storage_unavailable"})}
        end

      _ ->
        {:noreply, assign(socket, revoke_error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("confirm-revoke", _, socket),
    do: {:noreply, assign(socket, revoke_error: %{"code" => "invalid_request"})}

  def handle_event(
        "prepare-revoke-other",
        %{"id" => id},
        %{assigns: %{other_operation: nil, identity: %{"can_manage_queries" => true}}} = socket
      )
      when is_binary(id) do
    socket = load_credentials(socket)

    if revocable?(socket.assigns.credentials, id) do
      socket = assign(socket, other_generation: socket.assigns.credentials_generation)

      {:noreply,
       push_patch(socket,
         to:
           "/access?" <> URI.encode_query(%{"credential" => id, "operation" => Identifier.uuid()})
       )}
    else
      {:noreply, assign(socket, other_error: socket.assigns.credentials_error || conflict())}
    end
  end

  def handle_event("prepare-revoke-other", _, socket),
    do: {:noreply, assign(socket, other_error: %{"code" => "forbidden"})}

  def handle_event(
        "confirm-revoke-other",
        %{"revoke" => %{"confirmed" => "yes"}},
        %{
          assigns: %{
            other_id: id,
            other_operation: operation,
            other_generation: generation,
            other_outcome: nil,
            other_closed: false,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(id) and is_binary(operation) and is_binary(generation) do
    if revocable?(socket.assigns.credentials, id) do
      result =
        Auth.request(socket, :revoke, %{
          "operation" => operation,
          "request" => %{"credential_id" => id, "expected_generation" => generation}
        })

      {:noreply, other_result(socket, result)}
    else
      {:noreply, assign(socket, other_error: conflict(), other_closed: true)}
    end
  end

  def handle_event("confirm-revoke-other", %{"revoke" => %{"confirmed" => "yes"}}, socket),
    do:
      {:noreply,
       if(socket.assigns.other_outcome,
         do: socket,
         else: assign(socket, other_error: %{"code" => "forbidden"})
       )}

  def handle_event("confirm-revoke-other", _, socket),
    do: {:noreply, assign(socket, other_error: %{"code" => "invalid_request"})}

  def handle_event("check-revoke-other", _, socket), do: {:noreply, recover_other(socket)}

  def handle_event("end-session", %{"handle" => handle}, socket) when is_binary(handle) do
    case Sessions.end_session(socket.assigns.sessions, socket.assigns.session_id, handle) do
      :ok ->
        {:noreply, socket |> assign(sessions_error: nil) |> load_browser_sessions()}

      {:error, error} ->
        {:noreply, socket |> load_browser_sessions() |> assign(sessions_error: error)}
    end
  end

  def handle_event(
        "prepare-remove-endpoint",
        %{"id" => id},
        %{
          assigns: %{
            endpoint_operation: nil,
            other_operation: nil,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(id) do
    socket = load_endpoints(socket)

    if removable_endpoint?(socket.assigns.endpoints, id) do
      socket = assign(socket, endpoint_generation: socket.assigns.endpoints_generation)

      {:noreply,
       push_patch(socket,
         to:
           "/access?" <>
             URI.encode_query(%{
               "endpoint" => id,
               "endpoint_operation" => Identifier.uuid()
             })
       )}
    else
      {:noreply, assign(socket, endpoint_error: socket.assigns.endpoints_error || conflict())}
    end
  end

  def handle_event("prepare-remove-endpoint", _, socket),
    do: {:noreply, assign(socket, endpoint_error: %{"code" => "forbidden"})}

  def handle_event(
        "confirm-remove-endpoint",
        %{"endpoint" => %{"confirmed" => "yes"}},
        %{
          assigns: %{
            endpoint_id: id,
            endpoint_operation: operation,
            endpoint_generation: generation,
            endpoint_outcome: nil,
            endpoint_closed: false,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(id) and is_binary(operation) and is_binary(generation) do
    if removable_endpoint?(socket.assigns.endpoints, id) do
      result =
        Auth.request(socket, :unregister_notification_endpoint, %{
          "operation" => operation,
          "request" => %{"id" => id, "expected_generation" => generation}
        })

      {:noreply, endpoint_result(socket, result)}
    else
      {:noreply, assign(socket, endpoint_error: conflict(), endpoint_closed: true)}
    end
  end

  def handle_event(
        "confirm-remove-endpoint",
        %{"endpoint" => %{"confirmed" => "yes"}},
        socket
      ),
      do:
        {:noreply,
         if(socket.assigns.endpoint_outcome,
           do: socket,
           else: assign(socket, endpoint_error: %{"code" => "forbidden"})
         )}

  def handle_event("confirm-remove-endpoint", _, socket),
    do: {:noreply, assign(socket, endpoint_error: %{"code" => "invalid_request"})}

  def handle_event("check-remove-endpoint", _, socket), do: {:noreply, recover_endpoint(socket)}

  def handle_event("cancel-remove-endpoint", _, socket),
    do: {:noreply, push_patch(socket, to: "/access")}

  def handle_event("cancel-revoke-other", _, socket),
    do: {:noreply, push_patch(socket, to: "/access")}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href="/">← All assets</a>
      <p class="eyebrow">Privacy · current access</p>
      <div class="heading">
        <div>
          <h1>Access and session</h1>
          <p>Review the account and service permissions used by this browser session.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh access</button>
      </div>
      <.notice error={@error} />
      <.notice error={@revoke_error} />
      <.notice error={@other_error} />
      <.notice error={@endpoint_error} />
      <section :if={@access} class="panel">
        <h2>Current credential</h2>
        <dl>
          <dt>Principal</dt><dd>{@access["principal"]}</dd>
          <dt>Scope</dt><dd>{@access["scope"]}</dd>
          <dt>Expires</dt><dd>{Presenter.timestamp(%{"value" => @access["expires_at"]})}</dd>
        </dl>
        <table>
          <caption>Current service permissions</caption>
          <thead>
            <tr>
              <th scope="col">Permission</th><th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th scope="row">Read assets</th><td>Allowed</td>
            </tr>
            <tr>
              <th scope="row">Import observations</th><td>{status(@identity["can_ingest"])}</td>
            </tr>
            <tr>
              <th scope="row">Enroll assets</th><td>{status(@identity["can_enroll"])}</td>
            </tr>
            <tr>
              <th scope="row">Export raw evidence</th><td>{status(@identity["can_read_raw"])}</td>
            </tr>
            <tr>
              <th scope="row">Manage queries</th><td>{status(@identity["can_manage_queries"])}</td>
            </tr>
          </tbody>
        </table>
        <p>
          Sign out ends this browser session. The service credential remains valid until it expires
          or an administrator revokes it. The service checks authority again on each operation.
        </p>
      </section>
      <section
        :if={@access && @identity["can_manage_queries"]}
        class="panel"
        aria-labelledby="notification-installations-title"
      >
        <h2 id="notification-installations-title">Notification installations</h2>
        <p>
          Mobile installations registered by this principal for alert notifications. Removing one
          stops future pushes to that installation; canonical alerts remain in the service, and a
          signed-in app may register again.
        </p>
        <.notice error={@endpoints_error} />
        <p :if={is_nil(@endpoints)} role="status">
          Notification installations are unavailable. Refresh access to retry.
        </p>
        <div
          :if={@endpoints}
          class="table-scroll"
          tabindex="0"
          role="region"
          aria-labelledby="notification-installations-title"
        >
          <table>
            <caption>
              {length(@endpoints)} notification installations at scope version {@endpoints_generation}
            </caption>
            <thead>
              <tr>
                <th scope="col">Installation</th><th scope="col">Application</th><th scope="col">
                  Provider
                </th><th scope="col">Registered</th><th scope="col">Last updated</th><th scope="col">
                  Removal
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={endpoint <- @endpoints}>
                <th scope="row">{endpoint["id"]}</th>
                <td>{endpoint["value"]["app_id"]}</td>
                <td>{endpoint_provider(endpoint["value"])}</td>
                <td>{Presenter.timestamp(%{"value" => endpoint["value"]["created_at"]})}</td>
                <td>{Presenter.timestamp(%{"value" => endpoint["value"]["updated_at"]})}</td>
                <td>
                  <button
                    :if={
                      is_nil(@endpoint_operation) && is_nil(@other_operation) &&
                        removable_endpoint?(@endpoints, endpoint["id"])
                    }
                    class="secondary"
                    phx-click="prepare-remove-endpoint"
                    phx-value-id={endpoint["id"]}
                    aria-label={"Prepare to remove notification installation " <> endpoint["id"]}
                  >Remove</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <section :if={@access} class="panel" aria-labelledby="browser-sessions-title">
        <h2 id="browser-sessions-title">Browser sessions with this credential</h2>
        <p>
          Sessions on this server that use the same service credential. Ending one signs that
          browser out; the credential stays valid until it expires or is revoked.
        </p>
        <.notice error={@sessions_error} />
        <p :if={is_nil(@browser_sessions)} role="status">Browser sessions are unavailable.</p>
        <table :if={@browser_sessions}>
          <caption>Browser sessions: {length(@browser_sessions)}</caption>
          <thead>
            <tr>
              <th scope="col">Started</th><th scope="col">Expires</th><th scope="col">Session</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={session <- @browser_sessions}>
              <td>{Presenter.timestamp(%{"value" => session["started_at"]})}</td>
              <td>{Presenter.timestamp(%{"value" => session["expires_at"]})}</td>
              <td>
                <span :if={session["current"]}>This browser</span>
                <button
                  :if={!session["current"]}
                  class="secondary"
                  phx-click="end-session"
                  phx-value-handle={session["handle"]}
                >End session</button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
      <section :if={@access && @identity["can_manage_queries"]} class="panel">
        <h2>Revoke this credential</h2>
        <p>
          Revocation immediately ends every browser and API session using this credential. It cannot
          be undone. Other credentials remain valid.
        </p>
        <button :if={is_nil(@revoke_context)} class="secondary" phx-click="prepare-revoke">
          Prepare revocation
        </button>
        <div :if={@revoke_context}>
          <p>
            Operation reference <code>{@revoke_operation}</code>. Keep it if the result is uncertain.
          </p>
          <.form for={%{}} id="revoke-current" phx-submit="confirm-revoke">
            <label>
              <input type="checkbox" name="revoke[confirmed]" value="yes" />
              I understand this credential will stop working everywhere.
            </label>
            <button type="submit">Confirm revocation</button>
            <button type="button" class="secondary" phx-click="cancel-revoke">Cancel</button>
          </.form>
        </div>
      </section>
      <section
        :if={@access && @identity["can_manage_queries"]}
        class="panel"
        aria-labelledby="scope-credentials-title"
      >
        <h2 id="scope-credentials-title">Credentials in this scope</h2>
        <p>
          The service host configures these credentials. Revoking one ends every browser and API
          session using it in this scope and cannot be undone. Successful service authorization
          decisions are recorded in the access audit below.
        </p>
        <.notice error={@credentials_error} />
        <p :if={is_nil(@credentials)} role="status">
          The credential list is unavailable. Refresh access to retry.
        </p>
        <div
          :if={@credentials}
          class="table-scroll"
          tabindex="0"
          role="region"
          aria-labelledby="scope-credentials-title"
        >
          <table>
            <caption>
              {length(@credentials)} configured credentials at scope version {@credentials_generation}
            </caption>
            <thead>
              <tr>
                <th scope="col">Credential</th><th scope="col">Principal</th><th scope="col">
                  Permissions
                </th><th scope="col">Expires</th><th scope="col">Status</th><th scope="col">
                  Revocation
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={credential <- @credentials}>
                <th scope="row">
                  {credential["credential_id"]}
                  <span :if={credential["current"]} class="identifier">This browser session</span>
                </th>
                <td>{credential["principal"]}</td>
                <td>{Enum.join(credential["permissions"], ", ")}</td>
                <td>{Presenter.timestamp(%{"value" => credential["expires_at"]})}</td>
                <td>{credential_status(credential)}</td>
                <td>
                  <button
                    :if={
                      is_nil(@other_operation) &&
                        revocable?(@credentials, credential["credential_id"])
                    }
                    class="secondary"
                    phx-click="prepare-revoke-other"
                    phx-value-id={credential["credential_id"]}
                    aria-label={"Prepare to revoke credential " <> credential["credential_id"]}
                  >Prepare to revoke</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <section
        :if={@access && @identity["can_manage_queries"]}
        class="panel"
        aria-labelledby="access-audit-title"
      >
        <h2 id="access-audit-title">Successful access audit</h2>
        <p>
          Successful service authorization decisions only. Rejected sign-in attempts are not part
          of this journal. Entries omit bearer credentials, request bodies and resource identifiers.
        </p>
        <.notice error={@access_audit_error} />
        <p :if={is_nil(@access_audit)} role="status">
          The successful access audit is unavailable. Refresh access to retry.
        </p>
        <div :if={@access_audit}>
          <p>
            Coverage began {Presenter.timestamp(%{"value" => @access_audit["coverage_started_at"]})}. The service
            retains at most {@access_audit["maximum_entries"]} decisions per scope for {div(
              @access_audit["retention_ms"],
              86_400_000
            )} days.
          </p>
          <p :if={@access_audit["truncated"]} role="status">
            Older entries have been discarded by the disclosed retention or capacity bound.
          </p>
          <div
            class="table-scroll"
            tabindex="0"
            role="region"
            aria-labelledby="access-audit-title"
          >
            <table>
              <caption>
                {length(@access_audit["items"])} successful decisions at audit snapshot {@access_audit[
                  "snapshot"
                ]}
              </caption>
              <thead>
                <tr>
                  <th scope="col">Time</th><th scope="col">Principal</th><th scope="col">
                    Credential
                  </th><th scope="col">Permission</th><th scope="col">Activity</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @access_audit["items"]}>
                  <td>{Presenter.timestamp(%{"value" => entry["occurred_at"]})}</td>
                  <td>{entry["principal"]}</td>
                  <td>{entry["credential_id"]}</td>
                  <td>{entry["permission"]}</td>
                  <td>{audit_activity(entry["activity"])}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="actions">
            <button
              :if={@access_audit["cursor"]}
              class="secondary"
              phx-click="next-access-audit"
            >Older decisions</button>
            <button class="secondary" phx-click="newest-access-audit">Return to newest</button>
          </div>
        </div>
      </section>
      <section :if={@other_operation} class="operation" aria-labelledby="revoke-other-title">
        <h2 id="revoke-other-title">Revoke credential {@other_id}</h2>
        <p :if={
          is_nil(@other_outcome) && !@other_closed && is_list(@credentials) &&
            !revocable?(@credentials, @other_id)
        }>
          Credential {@other_id} is not an active credential other than this session's, so it
          cannot be revoked here.
        </p>
        <.form
          :if={
            @other_generation && is_nil(@other_outcome) && !@other_closed &&
              revocable?(@credentials, @other_id)
          }
          for={%{}}
          id="revoke-other"
          phx-submit="confirm-revoke-other"
        >
          <label>
            <input type="checkbox" name="revoke[confirmed]" value="yes" />
            I understand credential {@other_id} will stop working everywhere in this scope.
          </label>
          <button type="submit" phx-disable-with="Revoking…">Confirm credential revocation</button>
          <button type="button" class="secondary" phx-click="cancel-revoke-other">
            Cancel revocation
          </button>
        </.form>
        <p :if={@other_outcome} role="status">
          {if @other_outcome["outcome"] == "committed",
            do: "Credential #{@other_id} revoked",
            else: "Revocation outcome unknown"}
        </p>
        <p :if={@other_outcome && @other_outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@other_operation}</p>
        <button class="secondary" phx-click="check-revoke-other">Check operation outcome</button>
        <a href="/access">Return to access</a>
      </section>
      <section
        :if={@endpoint_operation}
        class="operation"
        aria-labelledby="remove-endpoint-title"
      >
        <h2 id="remove-endpoint-title">Remove notification installation {@endpoint_id}</h2>
        <p :if={
          is_nil(@endpoint_outcome) && !@endpoint_closed && is_list(@endpoints) &&
            !removable_endpoint?(@endpoints, @endpoint_id)
        }>
          Installation {@endpoint_id} is no longer registered for this principal, so it cannot be
          removed here.
        </p>
        <.form
          :if={
            @endpoint_generation && is_nil(@endpoint_outcome) && !@endpoint_closed &&
              removable_endpoint?(@endpoints, @endpoint_id)
          }
          for={%{}}
          id="remove-notification-installation"
          phx-submit="confirm-remove-endpoint"
        >
          <label>
            <input type="checkbox" name="endpoint[confirmed]" value="yes" />
            I understand this installation will stop receiving future push notifications.
          </label>
          <button type="submit" phx-disable-with="Removing…">Confirm removal</button>
          <button type="button" class="secondary" phx-click="cancel-remove-endpoint">
            Cancel removal
          </button>
        </.form>
        <p :if={@endpoint_outcome} role="status">
          {if @endpoint_outcome["outcome"] == "committed",
            do: "Notification installation #{@endpoint_id} removed",
            else: "Removal outcome unknown"}
        </p>
        <p :if={@endpoint_outcome && @endpoint_outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@endpoint_operation}</p>
        <button class="secondary" phx-click="check-remove-endpoint">Check operation outcome</button>
        <a href="/access">Return to access</a>
      </section>
    </main>
    """
  end

  defp load(socket) do
    socket =
      case Auth.request(socket, :access) do
        {:ok, %{"principal" => principal, "scope" => scope, "expires_at" => expires} = access}
        when is_binary(principal) and is_binary(scope) and is_integer(expires) ->
          assign(socket, access: access, error: nil)

        {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
          assign(socket, access: nil, error: error)

        {:error, error} ->
          assign(socket, error: error)

        _ ->
          assign(socket, access: nil, error: %{"code" => "storage_unavailable"})
      end

    socket
    |> load_credentials()
    |> load_browser_sessions()
    |> load_endpoints()
    |> load_access_audit()
  end

  defp load_browser_sessions(%{assigns: %{access: nil}} = socket),
    do: assign(socket, browser_sessions: nil)

  defp load_browser_sessions(socket) do
    case Sessions.list(socket.assigns.sessions, socket.assigns.session_id) do
      {:ok, %{"items" => items}} -> assign(socket, browser_sessions: items)
      {:error, error} -> assign(socket, browser_sessions: nil, sessions_error: error)
    end
  end

  defp load_credentials(%{assigns: %{identity: %{"can_manage_queries" => true}}} = socket) do
    case Auth.request(socket, :credentials) do
      {:ok, %{"generation" => generation, "items" => items}}
      when is_binary(generation) and is_list(items) ->
        assign(socket,
          credentials: items,
          credentials_generation: generation,
          credentials_error: nil
        )

      {:error, error} ->
        assign(socket, credentials: nil, credentials_generation: nil, credentials_error: error)

      _ ->
        assign(socket,
          credentials: nil,
          credentials_generation: nil,
          credentials_error: %{"code" => "storage_unavailable"}
        )
    end
  end

  defp load_credentials(socket),
    do: assign(socket, credentials: nil, credentials_generation: nil, credentials_error: nil)

  defp load_endpoints(%{assigns: %{identity: %{"can_manage_queries" => true}}} = socket) do
    case Auth.request(socket, :list, %{"resource" => "notification_endpoints"}) do
      {:ok, %{"generation" => generation, "items" => items}}
      when is_binary(generation) and is_list(items) and length(items) <= 8 ->
        if valid_generation?(generation) and Enum.all?(items, &endpoint?/1) do
          assign(socket,
            endpoints: items,
            endpoints_generation: generation,
            endpoints_error: nil
          )
        else
          invalid_endpoints(socket)
        end

      {:error, error} ->
        assign(socket, endpoints: nil, endpoints_generation: nil, endpoints_error: error)

      _ ->
        invalid_endpoints(socket)
    end
  end

  defp load_endpoints(socket),
    do: assign(socket, endpoints: nil, endpoints_generation: nil, endpoints_error: nil)

  defp load_access_audit(socket, params \\ %{})

  defp load_access_audit(
         %{assigns: %{identity: %{"can_manage_queries" => true}}} = socket,
         params
       ) do
    case Auth.request(socket, :access_audit, %{"params" => params}) do
      {:ok, page} ->
        if access_audit_page?(page) do
          assign(socket, access_audit: page, access_audit_error: nil)
        else
          assign(socket, access_audit_error: %{"code" => "storage_unavailable"})
        end

      {:error, error} ->
        assign(socket, access_audit_error: error)
    end
  end

  defp load_access_audit(socket, _params),
    do: assign(socket, access_audit: nil, access_audit_error: nil)

  defp access_audit_page?(
         %{
           "snapshot" => snapshot,
           "items" => items,
           "cursor" => cursor,
           "coverage_started_at" => coverage,
           "retention_ms" => 2_592_000_000,
           "maximum_entries" => 10_000,
           "truncated" => truncated
         } = page
       )
       when map_size(page) == 7 and is_list(items) and length(items) <= 100 and
              is_boolean(truncated) do
    valid_generation?(snapshot) and Codec.time?(coverage) and audit_cursor?(cursor) and
      Enum.all?(items, &access_audit_entry?/1)
  end

  defp access_audit_page?(_), do: false

  defp access_audit_entry?(
         %{
           "schema" => "wtr.access-audit-entry.v1",
           "credential_id" => credential,
           "principal" => principal,
           "permission" => permission,
           "activity" => activity,
           "occurred_at" => occurred_at
         } = entry
       )
       when map_size(entry) == 6,
       do:
         Codec.id?(credential) and Codec.id?(principal) and
           permission in ~w(admin enroll ingest interact raw read) and Codec.id?(activity) and
           Codec.time?(occurred_at)

  defp access_audit_entry?(_), do: false

  defp audit_cursor?(nil), do: true

  defp audit_cursor?("wtrc1." <> encoded = cursor),
    do: byte_size(cursor) in 8..4096 and encoded != "" and String.valid?(cursor)

  defp audit_cursor?(_), do: false

  defp invalid_endpoints(socket),
    do:
      assign(socket,
        endpoints: nil,
        endpoints_generation: nil,
        endpoints_error: %{"code" => "storage_unavailable"}
      )

  defp endpoint?(%{"id" => id, "generation" => generation, "value" => value} = item)
       when map_size(item) == 3 and is_map(value) and map_size(value) == 8 do
    endpoint_identity?(id, generation, value) and endpoint_delivery?(value) and
      endpoint_times?(value)
  end

  defp endpoint?(_), do: false

  defp endpoint_identity?(id, generation, value),
    do:
      value["schema"] == "wtr.notification-endpoint.v1" and value["id"] == id and
        Codec.id?(id) and valid_generation?(generation) and Codec.id?(value["app_id"]) and
        Codec.id?(value["revision"])

  defp endpoint_delivery?(value),
    do: value["provider"] == "apns" and value["environment"] in ~w(sandbox production)

  defp endpoint_times?(value),
    do:
      Codec.time?(value["created_at"]) and Codec.time?(value["updated_at"]) and
        value["updated_at"] >= value["created_at"]

  defp valid_generation?(value), do: match?({:ok, _}, Codec.generation(value))

  defp endpoint_provider(%{"provider" => "apns", "environment" => environment}),
    do: "APNs · #{environment}"

  defp endpoint_provider(_), do: "Unavailable"

  defp removable_endpoint?(endpoints, id) when is_list(endpoints) and is_binary(id),
    do: Enum.any?(endpoints, &(&1["id"] == id))

  defp removable_endpoint?(_, _), do: false

  defp activate_endpoint(socket, nil, nil),
    do:
      assign(socket,
        endpoint_id: nil,
        endpoint_operation: nil,
        endpoint_generation: nil,
        endpoint_outcome: nil,
        endpoint_error: nil,
        endpoint_closed: false
      )

  defp activate_endpoint(socket, id, operation)
       when is_binary(id) and is_binary(operation) do
    cond do
      not Codec.id?(id) or not Identifier.operation?(operation) ->
        activate_endpoint(socket, nil, nil)
        |> assign(endpoint_error: %{"code" => "invalid_request"})

      socket.assigns.endpoint_operation == operation and socket.assigns.endpoint_id == id ->
        socket

      true ->
        assign(socket,
          endpoint_id: id,
          endpoint_operation: operation,
          endpoint_generation:
            socket.assigns.endpoint_generation || socket.assigns.endpoints_generation,
          endpoint_outcome: nil,
          endpoint_error: nil,
          endpoint_closed: false
        )
    end
  end

  defp activate_endpoint(socket, _, _),
    do:
      activate_endpoint(socket, nil, nil)
      |> assign(endpoint_error: %{"code" => "invalid_request"})

  defp recover_endpoint(%{assigns: %{endpoint_operation: nil}} = socket), do: socket

  defp recover_endpoint(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.endpoint_operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> endpoint_result(socket, result)
    end
  end

  defp endpoint_result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    id = socket.assigns.endpoint_id

    if data == %{"endpoint_id" => id, "action" => "unregistered"} do
      socket = load_endpoints(socket)

      cond do
        is_nil(socket.assigns.endpoints) ->
          assign(socket,
            endpoint_outcome: %{"outcome" => "unknown"},
            endpoint_error: socket.assigns.endpoints_error
          )

        not removable_endpoint?(socket.assigns.endpoints, id) ->
          assign(socket, endpoint_outcome: receipt, endpoint_error: nil)

        true ->
          unrelated_endpoint(socket)
      end
    else
      unrelated_endpoint(socket)
    end
  end

  defp endpoint_result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, endpoint_outcome: receipt, endpoint_error: nil)

  defp endpoint_result(socket, {:ok, _}), do: unrelated_endpoint(socket)

  defp endpoint_result(
         %{assigns: %{endpoint_outcome: %{"outcome" => "committed"}}} = socket,
         {:error, error}
       ),
       do: assign(socket, endpoint_error: error)

  defp endpoint_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, endpoint_error: error, endpoint_closed: true)

  defp endpoint_result(socket, {:error, error}),
    do: assign(socket, endpoint_outcome: %{"outcome" => "unknown"}, endpoint_error: error)

  defp unrelated_endpoint(socket),
    do:
      assign(socket,
        endpoint_outcome: %{"outcome" => "unrelated"},
        endpoint_error: %{"code" => "operation_mismatch"}
      )

  defp activate_other(socket, nil, nil),
    do:
      assign(socket,
        other_id: nil,
        other_operation: nil,
        other_generation: nil,
        other_outcome: nil,
        other_error: nil,
        other_closed: false
      )

  defp activate_other(socket, id, operation) when is_binary(id) and is_binary(operation) do
    cond do
      not Identifier.operation?(operation) ->
        activate_other(socket, nil, nil) |> assign(other_error: %{"code" => "invalid_request"})

      socket.assigns.other_operation == operation and socket.assigns.other_id == id ->
        socket

      true ->
        # A reconnect without a prepared generation uses the inventory just loaded.
        assign(socket,
          other_id: id,
          other_operation: operation,
          other_generation:
            socket.assigns.other_generation || socket.assigns.credentials_generation,
          other_outcome: nil,
          other_error: nil,
          other_closed: false
        )
    end
  end

  defp activate_other(socket, _, _),
    do: activate_other(socket, nil, nil) |> assign(other_error: %{"code" => "invalid_request"})

  defp recover_other(%{assigns: %{other_operation: nil}} = socket), do: socket

  defp recover_other(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.other_operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> other_result(socket, result)
    end
  end

  defp other_result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    id = socket.assigns.other_id

    if data == %{"credential_id" => id} do
      socket = load_credentials(socket)

      cond do
        is_nil(socket.assigns.credentials) ->
          assign(socket,
            other_outcome: %{"outcome" => "unknown"},
            other_error: socket.assigns.credentials_error
          )

        Enum.any?(
          socket.assigns.credentials,
          &(&1["credential_id"] == id and &1["status"] == "revoked")
        ) ->
          assign(socket, other_outcome: receipt, other_error: nil)

        true ->
          unrelated_other(socket)
      end
    else
      unrelated_other(socket)
    end
  end

  defp other_result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, other_outcome: receipt, other_error: nil)

  defp other_result(socket, {:ok, _}), do: unrelated_other(socket)

  # A failed later check cannot make an already verified revocation uncertain.
  defp other_result(
         %{assigns: %{other_outcome: %{"outcome" => "committed"}}} = socket,
         {:error, error}
       ),
       do: assign(socket, other_error: error)

  defp other_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, other_error: error, other_closed: true)

  defp other_result(socket, {:error, error}),
    do: assign(socket, other_outcome: %{"outcome" => "unknown"}, other_error: error)

  defp unrelated_other(socket),
    do:
      assign(socket,
        other_outcome: %{"outcome" => "unrelated"},
        other_error: %{"code" => "operation_mismatch"}
      )

  defp revocable?(credentials, id) when is_list(credentials),
    do:
      Enum.any?(
        credentials,
        &(&1["credential_id"] == id and &1["status"] == "active" and &1["current"] == false)
      )

  defp revocable?(_, _), do: false

  defp credential_status(%{"status" => "revoked", "revocation" => %{"at" => at, "by" => by}}),
    do: "Revoked #{Presenter.timestamp(%{"value" => at})} by #{by}"

  defp credential_status(%{"status" => "expired"}), do: "Expired"
  defp credential_status(%{"status" => "active"}), do: "Active"
  defp credential_status(_), do: "Unknown"

  defp audit_activity(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp conflict, do: %{"code" => "conflict"}

  defp status(true), do: "Allowed"
  defp status(_), do: "Not allowed"

  defp clear_revoke(socket),
    do:
      assign(socket,
        revoke_context: nil,
        revoke_operation: nil,
        revoke_error: nil
      )
end
