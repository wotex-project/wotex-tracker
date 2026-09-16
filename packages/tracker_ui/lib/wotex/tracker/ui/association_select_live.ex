defmodule Wotex.Tracker.UI.AssociationSelectLive do
  @moduledoc "Selects a retained observation for an existing authorized asset."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket), do: {:ok, assign(socket, id: nil, asset: nil, page: nil, error: nil)}

  @impl true
  def handle_params(%{"id" => id}, _, socket),
    do: {:noreply, socket |> assign(id: id, asset: nil, page: nil) |> load(%{})}

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
      <a :if={@id} href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Setup · later observation</p>
      <div class="heading">
        <div>
          <h1>
            {if @asset,
              do: "Choose an observation for " <> @asset["title"],
              else: "Choose an observation"}
          </h1>
          <p>Review retained evidence before confirming a new association.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <p :if={@asset && !@identity["can_enroll"]} class="notice">
        This credential can inspect observations but cannot change an asset association.
      </p>
      <section :if={@asset && @page} aria-label="Observations">
        <div :if={@page["items"] == []} class="empty">
          <h2>No observations on this page</h2>
          <p>Import a capture in Setup, then return to this asset.</p>
          <a class="button" href="/setup">Open setup</a>
        </div>
        <div class="cards">
          <article :for={row <- @page["items"]} class="card">
            <p class="eyebrow">{row["value"]["ingress"]}</p>
            <h2>
              <a href={Presenter.association_path(@id, row["id"])}>Inspect observation</a>
            </h2>
            <p>{Presenter.timestamp(row["value"]["observed_at"])}</p>
            <p class="identifier">{row["id"]}</p>
          </article>
        </div>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
    </main>
    """
  end

  defp load(socket, params) do
    case Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}) do
      {:ok, %{"value" => asset}} ->
        case Auth.request(socket, :list, %{"resource" => "observations", "params" => params}) do
          {:ok, page} ->
            assign(socket, asset: asset, page: page, error: nil)

          {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
            assign(socket, asset: nil, page: nil, error: error)

          {:error, error} ->
            assign(socket, asset: asset, error: error)
        end

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        assign(socket, asset: nil, page: nil, error: error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end
end
