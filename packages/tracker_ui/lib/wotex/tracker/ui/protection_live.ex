defmodule Wotex.Tracker.UI.ProtectionLive do
  @moduledoc """
  Lists the committed status of deterministic tracking rules.

  Each page is fetched through the authorized service `rules` projection. The
  screen keeps a bounded path through earlier cursor pages and reloads them under
  current authority. It does not configure, arm, evaluate or acknowledge a rule,
  and it never receives the private evidence behind a status.
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
      <p class="eyebrow">Protection</p>
      <div class="heading">
        <div>
          <h1>Tracking rules</h1>
          <p>
            Status is the service's latest committed deterministic evaluation. It is not live
            device connectivity. This page cannot change, arm or acknowledge a rule.
          </p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@page} aria-label="Tracking rules">
        <div :if={@page["items"] == []} class="empty">
          <h2>No rule status on this page</h2>
          <p>
            A host has not committed any rule evaluation for this scope. Sensor-only assets can
            remain useful without position, motion or battery rules.
          </p>
        </div>
        <div class="cards">
          <article :for={row <- @page["items"]} class="card">
            <p class="eyebrow">{Presenter.rule_kind(row["value"]["kind"])}</p>
            <h2>
              <a href={Presenter.rule_path(row["id"])}>{row["value"]["rule"]["id"]}</a>
            </h2>
            <p class="reading">{Presenter.rule_status(row["value"]["status"])}</p>
            <p class="muted">
              Revision {row["value"]["rule"]["revision"]} · committed generation {row["generation"]}
            </p>
            <.rule_details status={row["value"]} />
          </article>
        </div>
        <button :if={@page_back != []} class="secondary" phx-click="previous">Previous page</button>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    case Auth.request(socket, :list, %{"resource" => "rules", "params" => params}) do
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
end
