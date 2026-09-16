defmodule Wotex.Tracker.UI.DashboardIndexLive do
  @moduledoc "Bounded read-only browsing of saved query definitions."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, page: nil, error: nil)}

  @impl true
  def handle_params(_, _, socket), do: {:noreply, load(socket, %{})}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket, %{})}

  def handle_event("next", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor),
      do: {:noreply, load(socket, %{"cursor" => cursor})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <p class="eyebrow">Saved analytics</p>
      <div class="heading">
        <div>
          <h1>Dashboards</h1>
          <p>Saved query definitions are rerun under your current read access.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <a :if={@identity["can_manage_queries"]} href="/dashboards/compare">
        Compare saved queries
      </a>
      <section :if={@page} aria-label="Saved dashboards">
        <div :if={@page["items"] == []} class="empty">
          <h2>No saved dashboards on this page</h2>
          <p>Explore an asset's measurement history to build a query.</p>
          <a href="/">Open assets</a>
        </div>
        <div class="cards">
          <article :for={row <- @page["items"]} class="card">
            <p class="eyebrow">{window_label(row["value"]["window"])}</p>
            <h2><a href={Presenter.dashboard_path(row["id"])}>{row["value"]["title"]}</a></h2>
            <p>
              {Presenter.label(row["value"]["query"]["measurement"])} · {row["value"]["visualization"][
                "type"
              ]} view
            </p>
            <p class="identifier">{row["id"]}</p>
          </article>
        </div>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    case Auth.request(socket, :list, %{"resource" => "saved_queries", "params" => params}) do
      {:ok, page} -> assign(socket, page: page, error: nil)
      {:error, error} -> assign(socket, page: nil, error: error)
    end
  end

  defp window_label("absolute"), do: "Fixed incident window"
  defp window_label(%{"kind" => "rolling"}), do: "Rolling window"
  defp window_label(_), do: "Saved window"
end
