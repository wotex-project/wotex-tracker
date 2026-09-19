defmodule Wotex.Tracker.UI.OperationalLive do
  @moduledoc """
  Inspects host operational measurements when that host enables the page.

  A current administrative grant is required for each page. Event and metric
  filters select bounded volatile samples inside a closed time window. The
  chart spaces recorded values by elapsed time without connecting them, and
  snapshot-pinned table pages retain the exact values. This is a host
  diagnostic view, not durable asset event history or a public analytics query.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.OperationalTelemetry
  alias Wotex.Tracker.UI.{Auth, OperationalChart, Presenter}

  @contracts OperationalTelemetry.contracts()
  @events Enum.map(@contracts, & &1.name)
  @windows [{"1 minute", 60_000}, {"5 minutes", 300_000}, {"15 minutes", 900_000}]
  @window_values Enum.map(@windows, &elem(&1, 1))
  @back_limit 32

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       enabled: socket.endpoint.config(:tracker_ui)[:operational_history] == true,
       events: @events,
       windows: @windows,
       event: nil,
       window_ms: 300_000,
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

  def handle_event(
        "filter",
        %{"filter" => %{"event" => event, "window_ms" => window}},
        socket
      )
      when event == "all" or event in @events do
    with {window_ms, ""} <- Integer.parse(window),
         true <- window_ms in @window_values do
      next =
        socket
        |> assign(event: if(event == "all", do: nil, else: event), window_ms: window_ms)
        |> first_page()

      {:noreply,
       if(next.assigns.error && next.assigns.page,
         do: assign(next, event: socket.assigns.event, window_ms: socket.assigns.window_ms),
         else: next
       )}
    else
      _ -> {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
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
           chart: OperationalChart.project(socket.assigns.page["window"], name),
           error: nil
         )}

      true ->
        {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("next", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_map(cursor) do
    request = %{
      "event" => socket.assigns.event,
      "cursor" => cursor,
      "window_ms" => socket.assigns.window_ms
    }

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
          <label for="operational-window">Time window</label>
          <select id="operational-window" name="filter[window_ms]">
            <option :for={{label, value} <- @windows} value={value} selected={@window_ms == value}>
              {label}
            </option>
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
              aria-label={"Discrete #{@metric} samples spaced across the selected operational time window; exact values follow in the table pages"}
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
              {@metric} ranges from {@chart.minimum} to {@chart.maximum} between {Presenter.timestamp(
                %{"value" => @chart.from_at}
              )} and {Presenter.timestamp(%{"value" => @chart.to_at})}. Horizontal spacing is elapsed
              time. No values are inferred between samples. Use the table pages for exact values
              and times.
            </figcaption>
          </figure>
          <p :if={@page["window"]["omitted_before"] > 0} role="status">
            The graph omits {@page["window"]["omitted_before"]} earlier samples from this window;
            the exact table pages remain available.
          </p>
          <p :if={is_nil(@chart)}>No retained values for this measurement in this time window.</p>
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
    next =
      load(socket, %{
        "event" => socket.assigns.event,
        "cursor" => nil,
        "window_ms" => socket.assigns.window_ms
      })

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
        if valid_page?(page, request) do
          choices = metric_choices(socket.assigns.event)
          metric = choose_metric(socket.assigns.metric, choices, page["window"])

          assign(socket,
            page: page,
            page_request: request,
            metric_choices: choices,
            metric: metric,
            chart: OperationalChart.project(page["window"], metric),
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

  defp valid_page?(
         %{
           "schema" => "wtr.operational-window-page.v1",
           "epoch" => epoch,
           "through" => through,
           "captured_at" => captured,
           "window" => window,
           "samples" => samples,
           "cursor" => cursor
         },
         %{"event" => event, "window_ms" => window_ms}
       ) do
    valid_page_header?(epoch, through, captured, cursor) and
      valid_page_samples?(samples, event, through) and
      valid_window?(window, through, event, window_ms)
  end

  defp valid_page?(_, _), do: false

  defp valid_page_header?(epoch, through, captured, cursor),
    do:
      is_binary(epoch) and is_integer(through) and is_integer(captured) and
        (is_nil(cursor) or is_map(cursor))

  defp valid_sample_list?(samples, event, maximum),
    do:
      is_list(samples) and length(samples) <= maximum and
        Enum.all?(samples, &(valid_sample?(&1) and event_matches?(&1, event)))

  defp valid_page_samples?(samples, event, through),
    do:
      valid_sample_list?(samples, event, 25) and
        Enum.all?(samples, &(&1["sequence"] <= through))

  defp valid_sample?(%{
         "sequence" => sequence,
         "event" => event,
         "observed_at" => observed,
         "measurements" => measurements,
         "metadata" => metadata
       }),
       do:
         is_integer(sequence) and sequence >= 1 and event in @events and is_integer(observed) and
           is_map(measurements) and is_map(metadata)

  defp valid_sample?(_), do: false

  defp valid_window?(
         %{
           "from_at" => from_at,
           "to_at" => to_at,
           "duration_ms" => duration_ms,
           "omitted_before" => omitted,
           "samples" => samples
         },
         through,
         event,
         requested_window
       ) do
    valid_window_bounds?(from_at, to_at, duration_ms, requested_window) and
      is_integer(omitted) and omitted >= 0 and
      valid_window_samples?(samples, through, event, from_at, to_at)
  end

  defp valid_window?(_, _, _, _), do: false

  defp valid_window_bounds?(from_at, to_at, duration_ms, requested_window),
    do:
      is_integer(from_at) and is_integer(to_at) and to_at > from_at and
        to_at - from_at == duration_ms and duration_ms == requested_window and
        duration_ms in @window_values

  defp valid_window_samples?(samples, through, event, from_at, to_at) do
    valid_sample_list?(samples, event, 1_000) and
      Enum.all?(samples, fn sample ->
        sample["sequence"] <= through and sample["observed_at"] > from_at and
          sample["observed_at"] <= to_at
      end)
  end

  defp event_matches?(_, nil), do: true
  defp event_matches?(sample, event), do: sample["event"] == event

  defp same_snapshot?(left, right),
    do:
      left["epoch"] == right["epoch"] and left["through"] == right["through"] and
        left["window"]["from_at"] == right["window"]["from_at"] and
        left["window"]["to_at"] == right["window"]["to_at"]

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

  defp choose_metric(current, choices, window) do
    names = Enum.map(choices, &elem(&1, 0))

    if current in names do
      current
    else
      Enum.find(names, fn name ->
        Enum.any?(window["samples"], &is_integer(&1["measurements"][name]))
      end) || hd(names)
    end
  end
end
