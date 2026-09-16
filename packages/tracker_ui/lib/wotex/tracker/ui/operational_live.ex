defmodule Wotex.Tracker.UI.OperationalLive do
  @moduledoc "Host-only, authorized pages of volatile operational measurements."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.OperationalTelemetry
  alias Wotex.Tracker.UI.{Auth, OperationalChart, Presenter}

  @contracts OperationalTelemetry.contracts()
  @events Enum.map(@contracts, & &1.name)
  @back_limit 32

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       enabled: socket.endpoint.config(:tracker_ui)[:operational_history] == true,
       events: @events,
       event: nil,
       metric: nil,
       metric_choices: [],
       chart: nil,
       page: nil,
       page_request: nil,
       page_back: [],
       error: nil
     )}
  end

  @impl true
  def handle_params(_, _, socket), do: {:noreply, first_page(socket)}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, first_page(socket)}

  def handle_event("filter", %{"filter" => %{"event" => event}}, socket)
      when event == "all" or event in @events do
    next = socket |> assign(event: if(event == "all", do: nil, else: event)) |> first_page()

    {:noreply,
     if(next.assigns.error && next.assigns.page,
       do: assign(next, event: socket.assigns.event),
       else: next
     )}
  end

  def handle_event("filter", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("metric", %{"metric" => %{"name" => name}}, socket) do
    choices = socket.assigns.metric_choices

    cond do
      not socket.assigns.identity["can_manage_queries"] ->
        {:noreply, load(socket, socket.assigns.page_request)}

      socket.assigns.page && Enum.any?(choices, fn {key, _} -> key == name end) ->
        {:noreply,
         assign(socket,
           metric: name,
           chart: OperationalChart.project(socket.assigns.page, name),
           error: nil
         )}

      true ->
        {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("next", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_map(cursor) do
    request = %{"event" => socket.assigns.event, "cursor" => cursor}
    next = load(socket, request)

    if next.assigns.page_request == request do
      back = [socket.assigns.page_request | socket.assigns.page_back]
      {:noreply, assign(next, page_back: Enum.take(back, @back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous", _, %{assigns: %{page_back: [request | rest]}} = socket) do
    previous = load(socket, request)

    cond do
      previous.assigns.page_request != request ->
        {:noreply, previous}

      not same_snapshot?(previous.assigns.page, socket.assigns.page) ->
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
      <a href="/">← All assets</a>
      <p class="eyebrow">Host operations</p>
      <div class="heading">
        <div>
          <h1>Operational history</h1>
          <p>Recent local service and browser measurements. This history is volatile and expires.</p>
        </div>
        <button
          :if={@enabled && @identity["can_manage_queries"]}
          class="secondary"
          phx-click="refresh"
        >Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@enabled && @identity["can_manage_queries"]} class="panel">
        <.form for={%{}} id="operational-filter" phx-submit="filter">
          <label for="operational-event">Event</label>
          <select id="operational-event" name="filter[event]">
            <option value="all" selected={is_nil(@event)}>All events</option>
            <option :for={event <- @events} value={event} selected={@event == event}>{event}</option>
          </select>
          <button type="submit">Apply filter</button>
        </.form>
        <p :if={@page} class="muted">
          Collector epoch <code>{@page["epoch"]}</code>
          · captured {Presenter.timestamp(%{"value" => @page["captured_at"]})}.
          Page ends at sequence {@page["through"]}; later samples require Refresh.
        </p>
        <div :if={@page}>
          <.form for={%{}} id="operational-metric" phx-change="metric">
            <label for="metric-name">Plot measurement</label>
            <select id="metric-name" name="metric[name]">
              <option :for={{name, unit} <- @metric_choices} value={name} selected={name == @metric}>
                {name} ({unit})
              </option>
            </select>
          </.form>
          <figure :if={@chart} class="history-chart">
            <svg
              viewBox="0 0 1000 300"
              role="img"
              aria-label={"Discrete #{@metric} samples on this operational page; exact values follow in the table"}
            >
              <line x1="56" y1="260" x2="944" y2="260" class="chart-axis" />
              <circle
                :for={point <- @chart.points}
                cx={point.x}
                cy={point.y}
                r="5"
                class="chart-point"
              >
                <title>
                  {point.event} · {Presenter.timestamp(%{"value" => point.observed_at})} · {point.value}
                </title>
              </circle>
            </svg>
            <figcaption>
              {@metric} ranges from {@chart.minimum} to {@chart.maximum} on this page.
              Marks follow record order, not elapsed-time spacing. No values are inferred between samples.
              Use the table for exact values and times.
            </figcaption>
          </figure>
          <p :if={is_nil(@chart)}>No retained values for this measurement on this page.</p>
        </div>
        <p :if={@page && @page["samples"] == []}>No retained samples on this page.</p>
        <div :if={@page && @page["samples"] != []} class="table-scroll">
          <table>
            <caption>Retained operational samples</caption>
            <thead>
              <tr>
                <th scope="col">Recorded UTC</th><th scope="col">Event</th><th scope="col">
                  Measurements
                </th><th scope="col">Categories</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={sample <- @page["samples"]}>
                <td>{Presenter.timestamp(%{"value" => sample["observed_at"]})}</td>
                <td><code>{sample["event"]}</code></td>
                <td>
                  <span :for={{key, value} <- Enum.sort(sample["measurements"])}>{key}: {value}</span>
                </td>
                <td>
                  <span :for={{key, value} <- Enum.sort(sample["metadata"])}>{key}: {value}</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div :if={@page} class="chart-controls" role="group" aria-label="Operational pages">
          <button :if={@page_back != []} class="secondary" phx-click="previous">Previous page</button>
          <button :if={is_map(@page["cursor"])} class="secondary" phx-click="next">Next page</button>
        </div>
      </section>
    </main>
    """
  end

  defp first_page(socket) do
    next = load(socket, %{"event" => socket.assigns.event, "cursor" => nil})

    if is_nil(next.assigns.error) and is_map(next.assigns.page),
      do: assign(next, page_back: []),
      else: next
  end

  defp load(%{assigns: %{enabled: false}} = socket, _),
    do:
      assign(socket, page: nil, chart: nil, page_request: nil, error: %{"code" => "unsupported"})

  defp load(%{assigns: %{identity: %{"can_manage_queries" => false}}} = socket, _),
    do: assign(socket, page: nil, chart: nil, page_request: nil, error: %{"code" => "forbidden"})

  defp load(socket, request) do
    case Auth.request(socket, :operational_history, request) do
      {:ok, page} ->
        if valid_page?(page) do
          choices = metric_choices(socket.assigns.event)
          metric = choose_metric(socket.assigns.metric, choices, page)

          assign(socket,
            page: page,
            page_request: request,
            metric_choices: choices,
            metric: metric,
            chart: OperationalChart.project(page, metric),
            error: nil
          )
        else
          assign(socket,
            page: nil,
            chart: nil,
            page_request: nil,
            page_back: [],
            error: %{"code" => "storage_unavailable"}
          )
        end

      {:error, %{"code" => code} = error}
      when code in ~w(forbidden unauthorized invalid_cursor cursor_expired) ->
        assign(socket, page: nil, chart: nil, page_request: nil, page_back: [], error: error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp valid_page?(%{
         "schema" => "wtr.operational-page.v1",
         "epoch" => epoch,
         "through" => through,
         "captured_at" => captured,
         "samples" => samples,
         "cursor" => cursor
       }) do
    is_binary(epoch) and is_integer(through) and is_integer(captured) and
      is_list(samples) and length(samples) <= 25 and
      Enum.all?(samples, &valid_sample?/1) and
      (is_nil(cursor) or is_map(cursor))
  end

  defp valid_page?(_), do: false

  defp valid_sample?(%{
         "event" => event,
         "observed_at" => observed,
         "measurements" => measurements,
         "metadata" => metadata
       }),
       do: event in @events and is_integer(observed) and is_map(measurements) and is_map(metadata)

  defp valid_sample?(_), do: false

  defp same_snapshot?(left, right),
    do: left["epoch"] == right["epoch"] and left["through"] == right["through"]

  defp metric_choices(event) do
    @contracts
    |> Enum.filter(&(is_nil(event) or &1.name == event))
    |> Enum.flat_map(fn contract ->
      Enum.map(contract.measurements, fn {name, unit} ->
        {Atom.to_string(name), Atom.to_string(unit)}
      end)
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp choose_metric(current, choices, page) do
    names = Enum.map(choices, &elem(&1, 0))

    if current in names do
      current
    else
      Enum.find(names, fn name ->
        Enum.any?(page["samples"], &is_integer(&1["measurements"][name]))
      end) || hd(names)
    end
  end
end
