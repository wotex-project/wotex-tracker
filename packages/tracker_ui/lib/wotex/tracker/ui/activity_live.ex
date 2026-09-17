defmodule Wotex.Tracker.UI.ActivityLive do
  @moduledoc """
  Lists the changes committed with this browser's credential in the last seven days.

  Pages come from the service's own-receipt listing, newest first, under current
  read authority, with a bounded path back through earlier pages. Each receipt is
  described from its committed data and links to the record it changed. The list
  helps recover work after an operation reference was lost; it never repeats an
  operation, and a change missing here had not committed when the page loaded.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @page_size 10
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
    <main id="main" class="workspace narrow">
      <p class="eyebrow">Recovery</p>
      <div class="heading">
        <div>
          <h1>Recent changes</h1>
          <p>
            Changes committed with your credential in this scope during the last seven days, newest
            first. A change missing here had not committed when this page loaded; check its operation
            reference before trying again.
          </p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@page} aria-label="Committed changes">
        <p :if={@page["items"] == []}>No committed changes on this page.</p>
        <table :if={@page["items"] != []}>
          <caption>Committed changes at scope version {@page["generation"]}</caption>
          <thead>
            <tr>
              <th scope="col">Change</th><th scope="col">Recorded</th><th scope="col">Version</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @page["items"]}>
              <td>
                <.change data={item["receipt"]["data"]} />
                <span class="identifier">Operation {item["operation_id"]}</span>
              </td>
              <td>{Presenter.timestamp(%{"value" => item["recorded_at"]})}</td>
              <td>{item["generation"]}</td>
            </tr>
          </tbody>
        </table>
        <button :if={@page_back != []} class="secondary" phx-click="previous">Newer changes</button>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Older changes</button>
      </section>
    </main>
    """
  end

  attr(:data, :any, required: true)

  defp change(%{data: %{"observation_id" => id} = data} = assigns) when map_size(data) == 1 do
    assigns = assign(assigns, id: id)

    ~H"""
    <a href={Presenter.path(:observation, @id)}>Imported observation</a>
    """
  end

  defp change(%{data: %{"thing_id" => id, "action" => "unenrolled"}} = assigns) do
    assigns = assign(assigns, id: id)

    ~H"""
    Removed asset <span class="identifier">{@id}</span>
    """
  end

  defp change(%{data: %{"thing_id" => id} = data} = assigns) do
    label =
      cond do
        Map.has_key?(data, "materialisation_id") -> "Provisioned asset"
        Map.has_key?(data, "association_id") -> "Associated an observation with an asset"
        true -> "Enrolled asset"
      end

    assigns = assign(assigns, id: id, label: label)

    ~H"""
    <a href={Presenter.path(:asset, @id)}>{@label}</a>
    """
  end

  defp change(%{data: %{"query_id" => id, "action" => "saved"}} = assigns) do
    assigns = assign(assigns, id: id)

    ~H"""
    <a href={Presenter.dashboard_path(@id)}>Saved dashboard</a>
    """
  end

  defp change(%{data: %{"query_id" => id, "action" => "deleted"}} = assigns) do
    assigns = assign(assigns, id: id)

    ~H"""
    Deleted dashboard <span class="identifier">{@id}</span>
    """
  end

  defp change(%{data: %{"policy_id" => id, "action" => action}} = assigns) do
    assigns = assign(assigns, id: id, action: action)

    ~H"""
    {if @action == "saved", do: "Saved rule definition", else: "Deleted rule definition"}
    <span class="identifier">{@id}</span>
    """
  end

  defp change(%{data: %{"alert_id" => id}} = assigns) do
    assigns = assign(assigns, id: id)

    ~H"""
    <a href={Presenter.alert_path(@id)}>Acknowledged alert</a>
    """
  end

  defp change(%{data: %{"credential_id" => id}} = assigns) do
    assigns = assign(assigns, id: id)

    ~H"""
    Revoked credential <span class="identifier">{@id}</span>
    """
  end

  defp change(assigns) do
    ~H"""
    Committed change
    """
  end

  defp load(socket, params) do
    case Auth.request(socket, :operations, %{"params" => params}) do
      {:ok, %{"items" => items} = page} when is_list(items) ->
        assign(socket, page: page, page_params: params, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        assign(socket, page: nil, page_params: nil, page_back: [], error: error)

      {:error, error} ->
        assign(socket, error: error)

      _ ->
        assign(socket, error: %{"code" => "storage_unavailable"})
    end
  end

  defp first_page(socket) do
    params = %{"limit" => @page_size}
    first = load(socket, params)
    if first.assigns.page_params == params, do: assign(first, page_back: []), else: first
  end
end
