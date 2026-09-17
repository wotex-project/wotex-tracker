defmodule Wotex.Tracker.UI.AlertIndexLive do
  @moduledoc """
  Lists recorded rule alerts, newest first, under current read authority.

  Each page comes from the service `alerts` projection and keeps a bounded path
  through earlier pages. An alert is a recorded deterministic event: this list
  does not send notifications, acknowledge alerts or request physical Actions.
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
      <a href="/protection">← Tracking rules</a>
      <p class="eyebrow">Protection</p>
      <div class="heading">
        <div>
          <h1>Alerts</h1>
          <p>
            Recorded rule events, newest first. Alerts are not delivered as notifications here, and
            none of them requests or performs a physical Action.
          </p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@page} aria-label="Alerts">
        <div :if={@page["items"] == []} class="empty">
          <h2>No alerts on this page</h2>
          <p>Alerts appear when a tracking rule records a change.</p>
        </div>
        <div class="cards">
          <article :for={row <- @page["items"]} class="card">
            <p class="eyebrow">{Presenter.rule_kind(row["value"]["rule"]["kind"])}</p>
            <h2>
              <a href={Presenter.alert_path(row["id"])}>
                {Presenter.alert_kind(row["value"]["event"]["kind"])}
              </a>
            </h2>
            <p>{Presenter.alert_state(row["value"])}</p>
            <p class="muted">
              Rule {row["value"]["rule"]["id"]} · recorded {Presenter.timestamp(%{
                "value" => row["value"]["created_at"]
              })}
            </p>
          </article>
        </div>
        <button :if={@page_back != []} class="secondary" phx-click="previous">Previous page</button>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    case Auth.request(socket, :list, %{"resource" => "alerts", "params" => params}) do
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
