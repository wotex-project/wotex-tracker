defmodule Wotex.Tracker.UI.TripLive do
  @moduledoc """
  Presents one bounded page of exact retained trip lifecycle events.

  Starts, stops and interruptions remain individual service records. The screen
  may identify both endpoints when they occur on the same page, but never joins
  events across a page boundary or invents a distance, route or missing end.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.RuleEventProjection
  alias Wotex.Tracker.UI.{Auth, Presenter, TripExport}

  @back_limit 32
  @limits ~w(25 50 100)
  @trip_kinds ~w(trip.started trip.stopped trip.interrupted)

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       asset: nil,
       state: nil,
       limit: "25",
       limits: @limits,
       params: nil,
       page: nil,
       back: [],
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    socket =
      if socket.assigns.id == id and socket.assigns.asset do
        socket
      else
        socket
        |> assign(id: id, asset: nil, state: nil, params: nil, page: nil, back: [], error: nil)
        |> load()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("set-limit", %{"trip" => %{"limit" => limit}}, socket)
      when limit in @limits do
    {:noreply, first_page(assign(socket, limit: limit))}
  end

  def handle_event("set-limit", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("next-page", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    params = %{"cursor" => cursor}
    next = page(socket, params)

    if next.assigns.params == params do
      back = [socket.assigns.params | socket.assigns.back]
      {:noreply, assign(next, back: Enum.take(back, @back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous-page", _, %{assigns: %{back: [params | rest]}} = socket) do
    previous = page(socket, params)

    cond do
      previous.assigns.params != params ->
        {:noreply, previous}

      previous.assigns.page["generation"] != socket.assigns.page["generation"] ->
        {:noreply, assign(socket, error: %{"code" => "conflict"})}

      true ->
        {:noreply, assign(previous, back: rest)}
    end
  end

  def handle_event(
        "export-page",
        _,
        %{assigns: %{id: id, page: %{} = shown, params: %{} = params}} = socket
      ) do
    with :ok <- TripExport.verify(socket, id, shown, params),
         {:ok, socket} <- TripExport.push(socket, id, shown) do
      {:noreply, socket}
    else
      {:error, %{"code" => code} = error}
      when code in ~w(forbidden unauthorized not_found) ->
        {:noreply, clear(socket, error)}

      {:error, %{"code" => "conflict"} = error} ->
        {:noreply, assign(socket, params: nil, page: nil, back: [], error: error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("export-page", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a :if={@id} href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Movement history · retained lifecycle events</p>
      <div class="heading">
        <div>
          <h1>{if @asset, do: @asset["title"] <> " trips", else: "Asset trips"}</h1>
          <p>Inspect exact recorded trip starts, stops and interruptions, newest first.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh trips</button>
      </div>
      <.notice error={@error} />
      <p :if={@asset && is_nil(@state)} class="notice">
        Provision this asset's Thing before requesting retained trip history.
      </p>
      <section :if={@state} class="panel" aria-labelledby="trip-history-title">
        <h2 id="trip-history-title">Trip event timeline</h2>
        <p>
          Times are displayed in UTC. Each row is a retained rule event, not a reconstructed route
          or final distance summary. Pairing is deliberately limited to events visible on this page.
        </p>
        <.form for={%{}} id="trip-page-size" phx-submit="set-limit">
          <label for="trip-limit">Events per page</label>
          <select id="trip-limit" name="trip[limit]">
            <option :for={limit <- @limits} value={limit} selected={@limit == limit}>{limit}</option>
          </select>
          <button type="submit" phx-disable-with="Loading…">Apply page size</button>
        </.form>
        <p :if={@page} class="muted">
          Committed snapshot {@page["generation"]} · newest retained events first
        </p>
        <div :if={@page && @page["items"] == []} class="empty">
          <h3>No trip events on this page</h3>
          <p>A trip appears only after a motion rule confirms movement.</p>
        </div>
        <ol :if={@page && @page["items"] != []} class="trip-timeline">
          <li :for={row <- @page["items"]}>
            <p class="eyebrow">{trip_phase(row["value"]["event"]["kind"])}</p>
            <h3>{Presenter.alert_kind(row["value"]["event"]["kind"])}</h3>
            <p>
              Effective {event_time(row, "effective_at")} · confirmed {event_time(
                row,
                "confirmed_at"
              )}
            </p>
            <p>{pairing(row, @page["items"])}</p>
            <dl>
              <dt>Reason</dt><dd>{reason(row["value"]["event"]["reason"])}</dd>
              <dt>Trip</dt><dd class="identifier">{row["value"]["event"]["trip_id"]}</dd>
              <dt>Motion rule</dt><dd>
                {row["value"]["rule"]["id"]} · revision {row["value"]["event"][
                  "rule_revision"
                ]}
              </dd>
              <dt>Evaluation</dt><dd>{evaluation(row["value"]["mode"])}</dd>
              <dt>Recorded</dt><dd>
                {Presenter.timestamp(%{
                  "value" => row["value"]["created_at"]
                })}
              </dd>
            </dl>
            <p>
              <a href={Presenter.alert_path(row["id"])}>Inspect the exact recorded alert</a>
            </p>
          </li>
        </ol>
        <p :if={@page} class="notice">
          A start or ending event can be on another page. This view never joins across page
          boundaries and never invents a missing stop.
        </p>
        <div :if={@page} class="chart-controls" role="group" aria-label="Trip event pages">
          <button class="secondary" phx-click="export-page">Export this event page (JSON)</button>
          <button :if={@back != []} class="secondary" phx-click="previous-page">
            Previous event page
          </button>
          <button :if={@page["cursor"]} class="secondary" phx-click="next-page">
            Next event page
          </button>
        </div>
      </section>
    </main>
    """
  end

  defp load(socket) do
    with {:ok, %{"value" => asset}} <-
           Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}),
         {:ok, %{"value" => state}} <-
           Auth.request(socket, :get, %{"resource" => "state", "id" => socket.assigns.id}) do
      socket
      |> assign(asset: asset, state: state, params: nil, page: nil, back: [], error: nil)
      |> first_page()
    else
      {:error, %{"code" => "not_found"}} ->
        unprovisioned_or_missing(socket)

      {:error, error} ->
        clear(socket, error)

      _ ->
        clear(socket, %{"code" => "storage_unavailable"})
    end
  end

  defp unprovisioned_or_missing(socket) do
    case Auth.request(socket, :get, %{
           "resource" => "enrollments",
           "id" => socket.assigns.id
         }) do
      {:ok, %{"value" => asset}} ->
        assign(socket,
          asset: asset,
          state: nil,
          params: nil,
          page: nil,
          back: [],
          error: nil
        )

      {:error, error} ->
        clear(socket, error)

      _ ->
        clear(socket, %{"code" => "storage_unavailable"})
    end
  end

  defp first_page(socket) do
    params = %{"limit" => String.to_integer(socket.assigns.limit)}
    first = page(socket, params)
    if first.assigns.params == params, do: assign(first, back: []), else: first
  end

  defp page(socket, params) do
    case Auth.request(socket, :thing_trips, %{"thing" => socket.assigns.id, "params" => params}) do
      {:ok, page} ->
        if page?(page, socket.assigns.id) do
          assign(socket, params: params, page: page, error: nil)
        else
          assign(socket, error: %{"code" => "storage_unavailable"})
        end

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp page?(
         %{
           "items" => items,
           "generation" => generation,
           "cursor" => cursor,
           "stream_cursor" => stream
         } = page,
         thing
       )
       when map_size(page) == 4 and is_list(items) and length(items) <= 100 and
              is_binary(generation) and (is_nil(cursor) or is_binary(cursor)) and
              is_binary(stream),
       do: Enum.all?(items, &trip_row?(&1, thing))

  defp page?(_, _), do: false

  defp trip_row?(
         %{
           "id" => id,
           "generation" => generation,
           "value" => %{
             "schema" => "wtr.alert.v1",
             "thing_id" => thing,
             "rule" => %{"kind" => "motion", "id" => rule},
             "event" =>
               %{
                 "schema" => "wtr.trip-event.v1",
                 "kind" => kind,
                 "trip_id" => trip,
                 "reason" => reason,
                 "effective_at" => effective_at,
                 "confirmed_at" => confirmed_at,
                 "rule_revision" => revision
               } = event,
             "mode" => mode,
             "created_at" => created_at
           }
         },
         thing
       ) do
    Enum.all?([id, generation, rule, trip, reason, revision], &is_binary/1) and
      Enum.all?([effective_at, confirmed_at, created_at], &is_integer/1) and
      kind in @trip_kinds and mode in ~w(live replay) and public_event?(event)
  end

  defp trip_row?(_, _), do: false

  defp public_event?(event),
    do: Enum.all?(RuleEventProjection.private_fields(), &(not Map.has_key?(event, &1)))

  defp pairing(row, items) do
    event = row["value"]["event"]
    kind = event["kind"]
    trip = event["trip_id"]

    counterpart_kind = if kind == "trip.started", do: :terminal, else: "trip.started"

    counterpart =
      Enum.find(items, fn candidate ->
        other = candidate["value"]["event"]

        other["trip_id"] == trip and
          (other["kind"] == counterpart_kind or
             (counterpart_kind == :terminal and other["kind"] in ~w(trip.stopped trip.interrupted)))
      end)

    case {kind, counterpart} do
      {"trip.started", nil} ->
        "No ending event is visible on this page."

      {"trip.started", other} ->
        "Its #{terminal(other)} event is also visible on this page."

      {_, nil} ->
        "Its start event is not visible on this page."

      {_, start} ->
        elapsed = max(0, event["effective_at"] - start["value"]["event"]["effective_at"])
        "Its start is visible on this page; exact onset-to-ending interval #{elapsed} ms."
    end
  end

  defp terminal(row),
    do: if(row["value"]["event"]["kind"] == "trip.stopped", do: "stop", else: "interruption")

  defp event_time(row, key),
    do: Presenter.timestamp(%{"value" => row["value"]["event"][key]})

  defp trip_phase("trip.started"), do: "Start"
  defp trip_phase("trip.stopped"), do: "Stop"
  defp trip_phase("trip.interrupted"), do: "Interrupted"

  defp evaluation("live"), do: "Live rule evaluation"
  defp evaluation("replay"), do: "Historical replay; no present-time action"

  defp reason(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp clear(socket, error) do
    assign(socket,
      asset: nil,
      state: nil,
      params: nil,
      page: nil,
      back: [],
      error: error
    )
  end
end
