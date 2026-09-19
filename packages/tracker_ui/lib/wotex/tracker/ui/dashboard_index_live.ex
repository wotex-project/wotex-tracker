defmodule Wotex.Tracker.UI.DashboardIndexLive do
  @moduledoc """
  Lists saved query definitions available to the current reader.

  Each page is fetched through the authorized service. The screen keeps a
  bounded path through earlier cursor pages and reloads them under current
  authority. Opening a definition runs it in `Wotex.Tracker.UI.DashboardLive`;
  listing alone does not execute or change a saved query.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @page_back_limit 32

  @impl true
  def mount(_, _, socket),
    do: {:ok, assign(socket, page: nil, page_params: nil, page_back: [], error: nil)}

  @impl true
  def handle_params(_, _, socket), do: {:noreply, first_page(socket)}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, first_page(socket)}

  def handle_event("next", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    next = load(socket, %{"cursor" => cursor})

    if next.assigns.page_params == %{"cursor" => cursor} do
      back = [socket.assigns.page_params | socket.assigns.page_back]
      {:noreply, assign(next, page_back: Enum.take(back, @page_back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous", _, %{assigns: %{page_back: [params | rest]}} = socket) do
    previous = load(socket, params)

    cond do
      previous.assigns.page_params != params ->
        {:noreply, previous}

      previous.assigns.page["generation"] != socket.assigns.page["generation"] ->
        {:noreply, assign(socket, error: %{"code" => "conflict"})}

      true ->
        {:noreply, assign(previous, page_back: rest)}
    end
  end

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
      <.offline_status projection={@page} />
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
        <button :if={@page_back != []} class="secondary" phx-click="previous">Previous page</button>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    case Auth.request(socket, :list, %{"resource" => "saved_queries", "params" => params}) do
      {:ok, page} ->
        assign(socket, page: page, page_params: params, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        assign(socket, page: nil, page_params: nil, page_back: [], error: error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp first_page(socket) do
    first = load(socket, %{})
    if first.assigns.page_params == %{}, do: assign(first, page_back: []), else: first
  end

  defp window_label("absolute"), do: "Fixed incident window"
  defp window_label(%{"kind" => "rolling"}), do: "Rolling window"
  defp window_label(_), do: "Saved window"
end
