defmodule Wotex.Tracker.UI.AccessLive do
  @moduledoc """
  Shows the browser's service access, the scope's credentials and administrator revocation.

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
  alias Wotex.Tracker.Service.Identifier
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
         other_closed: false
       )}

  @impl true
  def handle_params(params, _, socket),
    do:
      {:noreply,
       socket
       |> load()
       |> activate_other(params["credential"], params["operation"])
       |> recover_other()}

  @impl true
  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> clear_revoke() |> load()}

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
          session using it in this scope and cannot be undone. Individual accesses are not recorded.
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

    load_credentials(socket)
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
