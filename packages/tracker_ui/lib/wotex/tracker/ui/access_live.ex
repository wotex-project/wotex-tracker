defmodule Wotex.Tracker.UI.AccessLive do
  @moduledoc "Read-only inspection of the current authorized browser access."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, access: nil, error: nil)}

  @impl true
  def handle_params(_, _, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}
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
end
