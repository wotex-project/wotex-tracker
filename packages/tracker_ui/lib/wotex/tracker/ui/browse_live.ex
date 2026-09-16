defmodule Wotex.Tracker.UI.BrowseLive do
  @moduledoc "Bounded authorized asset and imported-observation browsing."
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
      <p class="eyebrow">Scope · {@identity["scope"]}</p>
      <div class="heading">
        <div>
          <h1>{if @live_action == :assets, do: "Your assets", else: "Set up a tracker"}</h1>
          <p :if={@live_action == :assets}>Inspect retained evidence and continue provisioning.</p>
          <p :if={@live_action == :observations}>
            Choose an imported observation, inspect its evidence and confirm ownership.
          </p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@page} aria-label="Records">
        <div :if={@page["items"] == []} class="empty">
          <h2>
            {if @live_action == :assets,
              do: "No assets on this page",
              else: "No observations on this page"}
          </h2>
          <p :if={@live_action == :assets}>Start with an observation to enroll your first asset.</p>
          <p :if={@live_action == :observations}>
            This service has no observation to show here. Connect an admitted source or import a capture through its machine interface.
          </p>
          <a :if={@live_action == :assets} class="button" href="/setup">Open setup</a>
        </div>
        <div class="cards">
          <article :for={row <- @page["items"]} class="card">
            <p class="eyebrow">
              {if @live_action == :assets, do: "Enrolled asset", else: row["value"]["ingress"]}
            </p>
            <h2>
              <a href={
                Presenter.path(if(@live_action == :assets, do: :asset, else: :observation), row["id"])
              }>
                {if @live_action == :assets, do: row["value"]["title"], else: "Inspect observation"}
              </a>
            </h2>
            <p :if={@live_action == :observations}>
              {Presenter.timestamp(row["value"]["observed_at"])}
            </p>
            <p class="identifier">{row["id"]}</p>
            <p :if={@live_action == :assets} class="muted">
              Ownership confirmed · open for measurements and provisioning
            </p>
          </article>
        </div>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    resource = if socket.assigns.live_action == :assets, do: "enrollments", else: "observations"

    case Auth.request(socket, :list, %{"resource" => resource, "params" => params}) do
      {:ok, page} -> assign(socket, page: page, error: nil)
      {:error, error} -> assign(socket, error: error)
    end
  end
end
