defmodule Wotex.Tracker.UI.AccessLive do
  @moduledoc """
  Shows the browser's current service access and permits administrator self-revocation.

  The page displays principal, scope, expiry, and grant categories without
  exposing the bearer token. Revocation requires a fresh credential ID and
  scope generation from the service, a stable operation reference, and explicit
  confirmation. A committed result ends this browser session. An uncertain
  result carries its operation reference to sign-in for later service lookup.
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
         revoke_error: nil
       )}

  @impl true
  def handle_params(_, _, socket), do: {:noreply, load(socket)}

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
    </main>
    """
  end

  defp load(socket) do
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
  end

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
