defmodule Wotex.Tracker.UI.RouteLive do
  @moduledoc """
  Presents one bounded retained route page without inventing continuity.

  The screen sends a closed route-page request through the authorized service
  client. Every service segment stays separate in the coordinate plot and exact
  table. Missing, ambiguous, rejected and gap records remain visible, and page
  navigation never connects one response to another.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter, RouteChart, RouteExport}

  @back_limit 32
  @day_ms 86_400_000
  @quality_filters %{
    "valid" => ["valid"],
    "suspect" => ["suspect"],
    "valid_suspect" => ["valid", "suspect"]
  }

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       asset: nil,
       state: nil,
       input: %{},
       request: nil,
       page: nil,
       chart: nil,
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
        |> assign(id: id, asset: nil, state: nil, input: %{}, request: nil, page: nil)
        |> assign(chart: nil, back: [], error: nil)
        |> load()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("run", %{"route" => input}, socket) when is_map(input) do
    socket =
      assign(socket, input: input, request: nil, page: nil, chart: nil, back: [], error: nil)

    case request(socket.assigns.id, input) do
      {:ok, request} -> {:noreply, page(socket, request)}
      :error -> {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("next-page", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    request = Map.put(socket.assigns.request, "cursor", cursor)
    next = page(socket, request)

    if next.assigns.request == request do
      back = [socket.assigns.request | socket.assigns.back]
      {:noreply, assign(next, back: Enum.take(back, @back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous-page", _, %{assigns: %{back: [request | rest]}} = socket) do
    previous = page(socket, request)

    cond do
      previous.assigns.request != request ->
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
        %{assigns: %{page: %{} = shown, request: %{} = request}} = socket
      ) do
    with :ok <- RouteExport.verify(socket, shown, request),
         {:ok, socket} <- RouteExport.push(socket, shown) do
      {:noreply, socket}
    else
      {:error, %{"code" => code} = error}
      when code in ~w(forbidden unauthorized not_found) ->
        {:noreply, clear(socket, error)}

      {:error, %{"code" => "conflict"} = error} ->
        {:noreply, assign(socket, request: nil, page: nil, chart: nil, back: [], error: error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("export-page", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("run", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a :if={@id} href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Position history · retained route replay</p>
      <div class="heading">
        <div>
          <h1>{if @asset, do: @asset["title"] <> " route", else: "Asset route"}</h1>
          <p>Inspect qualified retained positions without filling gaps or choosing among sources.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh asset</button>
      </div>
      <.notice error={@error} />
      <p :if={@asset && is_nil(@state)} class="notice">
        Provision this asset's Thing before requesting retained position history.
      </p>
      <section :if={@state} class="panel">
        <h2>Choose a route window</h2>
        <p>
          Times are UTC; the start is included and the end is excluded. A trusted fix is used only
          when its clock is qualified. Receiver fallback applies only when the fix time is absent.
        </p>
        <.form for={%{}} id="route-query" phx-submit="run">
          <label for="route-from">From (UTC, inclusive)</label>
          <input id="route-from" name="route[from]" type="text" value={@input["from"]} required />
          <label for="route-to">To (UTC, exclusive)</label>
          <input id="route-to" name="route[to]" type="text" value={@input["to"]} required />
          <label for="route-event-time">Event time</label>
          <select id="route-event-time" name="route[event_time]">
            <option value="trusted_fix" selected={@input["event_time"] == "trusted_fix"}>
              Trusted fix only
            </option>
            <option
              value="trusted_fix_or_receiver"
              selected={@input["event_time"] == "trusted_fix_or_receiver"}
            >
              Trusted fix, or receiver time when fix is absent
            </option>
          </select>
          <label for="route-quality">Position quality</label>
          <select id="route-quality" name="route[quality]">
            <option value="valid" selected={@input["quality"] == "valid"}>Valid only</option>
            <option value="suspect" selected={@input["quality"] == "suspect"}>
              Suspect only
            </option>
            <option value="valid_suspect" selected={@input["quality"] == "valid_suspect"}>
              Valid and suspect
            </option>
          </select>
          <label for="route-gap-minutes">Maximum adjacent time gap (minutes)</label>
          <input
            id="route-gap-minutes"
            name="route[max_gap_minutes]"
            type="number"
            min="1"
            max="525600"
            value={@input["max_gap_minutes"]}
            required
          />
          <label for="route-gap-metres">Maximum adjacent centre distance (metres)</label>
          <input
            id="route-gap-metres"
            name="route[max_gap_m]"
            type="number"
            min="1"
            max="40075000"
            value={@input["max_gap_m"]}
            required
          />
          <label for="route-page-size">Materialisations per page</label>
          <select id="route-page-size" name="route[page_size]">
            <option :for={size <- ~w(25 50 100)} value={size} selected={@input["page_size"] == size}>
              {size}
            </option>
          </select>
          <button type="submit" phx-disable-with="Replaying…">Replay retained positions</button>
        </.form>
        <p class="muted">
          A page may contain fewer qualified points than materialisations. Missing, ambiguous and
          rejected positions remain disclosed instead of being connected.
        </p>
      </section>
      <section :if={@page} class="panel" aria-labelledby="route-result-title">
        <h2 id="route-result-title">Route page</h2>
        <p>
          {@page["route"]["point_count"]} qualified points in {@page["route"]["segment_count"]} separate segments · {@page[
            "route"
          ]["rejected_count"]} rejected · {@page["route"][
            "excluded_count"
          ]} missing or ambiguous.
        </p>
        <p class="notice">
          Continuity is local to this page. Never connect its first or last point to another page.
          Lines are retained evidence segments, not a road-matched or reconstructed path.
        </p>
        <dl>
          <dt>Replay status</dt><dd>
            {@page["route"]["status"]} · {route_reason(@page["route"]["reason"])}
          </dd>
          <dt>Committed snapshot</dt><dd class="identifier">{@page["generation"]}</dd>
          <dt>Materialisation versions on this page</dt><dd>
            after {@page["history"]["after_generation"]} through {@page["history"][
              "last_generation"
            ]} ({@page["history"]["record_count"]} records)
          </dd>
          <dt>Page identity</dt><dd class="identifier">{@page["identity"]}</dd>
        </dl>
        <figure :if={@chart} class="history-chart route-chart">
          <svg
            viewBox="0 0 1000 400"
            role="img"
            aria-label="Coordinate plot of page-local retained route segments; exact coordinates and gaps follow"
          >
            <line x1="56" y1="376" x2="944" y2="376" class="chart-axis" />
            <line x1="56" y1="24" x2="56" y2="376" class="chart-axis" />
            <path :for={segment <- @chart.segments} d={segment.line} class="chart-line" />
            <circle
              :for={point <- chart_points(@chart)}
              cx={point.x}
              cy={point.y}
              r="5"
              class="chart-point"
            >
              <title>
                {Presenter.timestamp(point.event_at)} · {point.latitude}, {point.displayed_longitude} · {Presenter.position_source(
                  point.source
                )} · {point.quality}
              </title>
            </circle>
          </svg>
          <figcaption>
            Coordinate-only plot with separate service segments and short antimeridian deltas.
            It supplies no basemap, street matching or position between recorded points.
          </figcaption>
        </figure>
        <p :if={is_nil(@chart)}>No qualified position can be plotted on this page.</p>
        <div
          :if={route_points(@page) != []}
          class="table-scroll"
          tabindex="0"
          role="region"
          aria-labelledby="route-result-title"
        >
          <table>
            <caption>Exact qualified route points, kept in separate service segments</caption>
            <thead>
              <tr>
                <th scope="col">Segment</th><th scope="col">Event time (UTC)</th><th scope="col">
                  Coordinate
                </th><th scope="col">Source</th><th scope="col">Quality</th><th scope="col">
                  Stated accuracy
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{segment, point} <- route_points(@page)}>
                <td>{segment}</td>
                <td>{Presenter.timestamp(point["event_at"])} · {point["event_time_basis"]}</td>
                <td>{Presenter.scalar(point["latitude"])}, {Presenter.scalar(point["longitude"])}</td>
                <td>{Presenter.position_source(point["source"])}</td>
                <td>{point["quality"]}</td>
                <td>
                  {point["accuracy_kind"]} · {Presenter.scalar(point["horizontal_accuracy_m"])} m
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <section :if={route_gaps?(@page)} aria-labelledby="route-gaps-title">
          <h3 id="route-gaps-title">Visible gaps and exclusions</h3>
          <ul class="route-gaps">
            <li :for={gap <- @page["route"]["breaks"]}>
              {gap_reason(gap["reason"])} between {Presenter.timestamp(gap["after_event_at"])} and {Presenter.timestamp(
                gap["before_event_at"]
              )} · {Presenter.scalar(gap["gap_ms"])} ms · {Presenter.scalar(gap["center_distance_m"])} m
            </li>
            <li :for={rejection <- @page["route"]["rejected"]}>
              Rejected at {Presenter.timestamp(rejection["received_at"])} · {gap_reason(
                rejection["reason"]
              )}
            </li>
            <li :for={exclusion <- @page["route"]["excluded"]}>
              Excluded at {Presenter.timestamp(exclusion["received_at"])} · {gap_reason(
                exclusion["reason"]
              )}
            </li>
          </ul>
        </section>
        <div class="chart-controls" role="group" aria-label="Retained route pages">
          <button class="secondary" phx-click="export-page">Export this route page (JSON)</button>
          <button :if={@back != []} class="secondary" phx-click="previous-page">
            Previous route page
          </button>
          <button :if={@page["cursor"]} class="secondary" phx-click="next-page">
            Next route page
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
           Auth.request(socket, :get, %{"resource" => "state", "id" => socket.assigns.id}),
         {:ok, observed_at} <- observed_at(state) do
      input = default_input(observed_at)
      {:ok, request} = request(socket.assigns.id, input)

      socket
      |> assign(
        asset: asset,
        state: state,
        input: input,
        page: nil,
        chart: nil,
        back: [],
        error: nil
      )
      |> page(request)
    else
      {:error, %{"code" => "not_found"}} ->
        case Auth.request(socket, :get, %{
               "resource" => "enrollments",
               "id" => socket.assigns.id
             }) do
          {:ok, %{"value" => asset}} ->
            assign(socket,
              asset: asset,
              state: nil,
              input: %{},
              request: nil,
              page: nil,
              chart: nil,
              back: [],
              error: nil
            )

          {:error, error} ->
            clear(socket, error)

          _ ->
            clear(socket, %{"code" => "storage_unavailable"})
        end

      {:error, error} ->
        clear(socket, error)

      _ ->
        clear(socket, %{"code" => "storage_unavailable"})
    end
  end

  defp page(socket, request) do
    case Auth.request(socket, :route_history, %{"request" => request}) do
      {:ok, page} ->
        if page?(page, socket.assigns.id) do
          assign(socket,
            request: request,
            page: page,
            chart: RouteChart.project(page["route"]),
            error: nil
          )
        else
          assign(socket, error: %{"code" => "storage_unavailable"})
        end

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp request(thing, input) do
    with {:ok, from_at} <- utc_milliseconds(input["from"]),
         {:ok, to_at} <- utc_milliseconds(input["to"]),
         true <- from_at < to_at,
         event_time when event_time in ~w(trusted_fix trusted_fix_or_receiver) <-
           input["event_time"],
         {:ok, qualities} <- Map.fetch(@quality_filters, input["quality"]),
         {:ok, minutes} <- positive_integer(input["max_gap_minutes"], 525_600),
         {:ok, max_gap_m} <- positive_integer(input["max_gap_m"], 40_075_000),
         {:ok, page_size} <- positive_integer(input["page_size"], 100),
         true <- page_size in [25, 50, 100] do
      {:ok,
       %{
         "schema" => "wtr.route-page-request.v1",
         "thing_id" => thing,
         "from_at" => from_at,
         "to_at" => to_at,
         "event_time" => event_time,
         "qualities" => qualities,
         "max_gap_ms" => minutes * 60_000,
         "max_gap_m" => max_gap_m,
         "page_size" => page_size,
         "cursor" => nil
       }}
    else
      _ -> :error
    end
  end

  defp page?(
         %{
           "schema" => "wtr.route-page.v1",
           "thing_id" => thing,
           "generation" => generation,
           "history" => history,
           "continuity" => "page_local_only",
           "route" => route,
           "cursor" => cursor,
           "identity" => identity
         } = page,
         thing
       )
       when map_size(page) == 10 and is_binary(generation) and is_map(history) and is_map(route) and
              (is_nil(cursor) or is_binary(cursor)) and is_binary(identity) do
    Map.keys(history) |> Enum.sort() == ~w(after_generation last_generation record_count) and
      route?(route)
  end

  defp page?(_, _), do: false

  defp route?(%{
         "segments" => segments,
         "breaks" => breaks,
         "rejected" => rejected,
         "excluded" => excluded,
         "point_count" => point_count,
         "segment_count" => segment_count
       })
       when is_list(segments) and is_list(breaks) and is_list(rejected) and is_list(excluded) and
              is_integer(point_count) and is_integer(segment_count),
       do: true

  defp route?(_), do: false

  defp observed_at(%{"observed_at" => %{"value" => value}}) when is_integer(value),
    do: {:ok, value}

  defp observed_at(_), do: :error

  defp default_input(observed_at) do
    to_at = observed_at + 1

    %{
      "from" => iso8601(max(0, to_at - @day_ms)),
      "to" => iso8601(to_at),
      "event_time" => "trusted_fix",
      "quality" => "valid",
      "max_gap_minutes" => "30",
      "max_gap_m" => "10000",
      "page_size" => "100"
    }
  end

  defp positive_integer(value, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 1 and parsed <= maximum -> {:ok, parsed}
      _ -> :error
    end
  end

  defp positive_integer(_, _), do: :error

  defp utc_milliseconds(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.to_unix(datetime, :millisecond)}
      _ -> :error
    end
  end

  defp utc_milliseconds(_), do: :error

  defp iso8601(value) do
    {:ok, datetime} = DateTime.from_unix(value, :millisecond)
    DateTime.to_iso8601(datetime)
  end

  defp chart_points(chart), do: Enum.flat_map(chart.segments, & &1.points)

  defp route_points(page) do
    page["route"]["segments"]
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {segment, index} -> Enum.map(segment["points"], &{index, &1}) end)
  end

  defp route_gaps?(page),
    do:
      page["route"]["breaks"] != [] or page["route"]["rejected"] != [] or
        page["route"]["excluded"] != []

  defp route_reason("all_positions_qualified"), do: "all retained positions qualified"
  defp route_reason("gaps_or_rejections"), do: "gaps or rejected positions remain visible"
  defp route_reason("no_qualified_positions"), do: "no position qualified in this page"
  defp route_reason(value), do: value

  defp gap_reason("unqualified_materialisations"), do: "Missing or ambiguous materialisation"
  defp gap_reason("missing_position"), do: "No position in this materialisation"
  defp gap_reason("ambiguous_positions"), do: "Multiple positions; no source selected"
  defp gap_reason("rejected_samples"), do: "Rejected position sample"
  defp gap_reason("time_gap"), do: "Time gap exceeded"
  defp gap_reason("distance_gap"), do: "Distance gap exceeded"
  defp gap_reason("time_and_distance_gap"), do: "Time and distance gaps exceeded"
  defp gap_reason("quality:" <> quality), do: "Quality excluded: " <> quality
  defp gap_reason(value), do: value

  defp clear(socket, error) do
    assign(socket,
      asset: nil,
      state: nil,
      input: %{},
      request: nil,
      page: nil,
      chart: nil,
      back: [],
      error: error
    )
  end
end
