defmodule Wotex.Tracker.UI.DashboardLive do
  @moduledoc """
  Runs and displays one saved query under current read authority.

  While following, the page checks the scope's committed events every 5 seconds
  and reruns the query only after a commit, coalescing every pending change into
  one run from a fresh snapshot cursor. A rolling window also reruns after six
  quiet checks. A temporary check or run failure keeps a marked stale result and
  retries on each later check. Readers can switch between an exact table and
  gap-preserving chart views without changing the definition.
  Administrators can edit its title or view and delete it with generation and
  operation checks; a deleted or unauthorized definition is cleared. Every
  loaded definition also exposes a credential-free relative link. Opening that
  link always requires the recipient's own current scope read authority.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Chart, Presenter, QueryExport, QueryWindow}
  @refresh_interval_ms 5_000
  @rolling_quiet_checks 6

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       definition: nil,
       result: nil,
       chart: nil,
       preview_window: false,
       display_view: nil,
       display_override: false,
       error: nil,
       manage_operation: nil,
       manage_intent: nil,
       manage_generation: nil,
       manage_outcome: nil,
       manage_error: nil,
       refresh_epoch: 0,
       refresh_timer: nil,
       refresh_status: nil,
       refresh_error: nil,
       follow_cursor: nil,
       quiet_checks: 0
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket = socket |> stop_refresh() |> assign(id: id) |> load()

    {:noreply,
     socket
     |> activate_manage(params["manage_operation"], params["manage_intent"])
     |> recover_manage()
     |> load_manage_generation()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, socket |> stop_refresh() |> load()}

  def handle_event("run", _, socket) do
    {:noreply, socket |> stop_refresh() |> load() |> execute()}
  end

  def handle_event("start-auto-refresh", _, socket) do
    if socket.assigns.definition && is_nil(socket.assigns.refresh_timer) do
      socket =
        socket
        |> assign(refresh_epoch: socket.assigns.refresh_epoch + 1)
        |> schedule_refresh()
        |> follow_latest()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stop-auto-refresh", _, socket), do: {:noreply, stop_refresh(socket)}

  def handle_event("export-result", _, %{assigns: %{result: result}} = socket)
      when is_map(result) do
    case Auth.request(socket, :get, %{"resource" => "saved_queries", "id" => socket.assigns.id}) do
      {:ok, %{"value" => definition}} when definition == socket.assigns.definition ->
        export_current_result(socket, result)

      {:ok, _} ->
        {:noreply,
         assign(socket, definition: nil, result: nil, chart: nil, error: %{"code" => "conflict"})}

      {:error, %{"code" => code} = error}
      when code in ~w(forbidden unauthorized not_found) ->
        {:noreply,
         socket
         |> stop_refresh()
         |> assign(definition: nil, result: nil, chart: nil, error: error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("export-result", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("change-view", %{"view" => view}, %{assigns: %{result: result}} = socket)
      when view in ~w(line area points table) and is_map(result),
      do:
        {:noreply,
         assign(socket,
           display_view: view,
           display_override: true,
           chart: chart_for(result, view),
           error: nil
         )}

  def handle_event("change-view", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event(
        "navigate-result",
        %{"direction" => direction},
        %{assigns: %{result: %{"spec" => spec}}} = socket
      ) do
    case QueryWindow.query(spec, direction) do
      {:ok, query} ->
        socket = stop_refresh(socket)

        case Auth.request(socket, :analytics, %{"query" => query}) do
          {:ok, result} ->
            {:noreply,
             assign(socket,
               result: result,
               chart: chart_for(result, socket.assigns.display_view),
               preview_window: true,
               error: nil
             )}

          {:error, %{"code" => code} = error}
          when code in ~w(forbidden unauthorized not_found) ->
            {:noreply,
             assign(socket, result: nil, chart: nil, preview_window: false, error: error)}

          {:error, error} ->
            {:noreply, assign(socket, error: error)}
        end

      :error ->
        {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("navigate-result", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("prepare-manage", %{"intent" => intent}, socket)
      when intent in ~w(edit delete) do
    if socket.assigns.identity["can_manage_queries"] && socket.assigns.definition &&
         is_nil(socket.assigns.manage_operation) do
      case current_generation(socket) do
        {:ok, generation} ->
          socket = assign(socket, manage_generation: generation, manage_error: nil)

          {:noreply,
           push_patch(socket,
             to:
               Presenter.dashboard_path(socket.assigns.id) <>
                 "?manage_operation=#{Identifier.uuid()}&manage_intent=#{intent}"
           )}

        {:error, error} ->
          {:noreply, assign(socket, manage_error: error)}
      end
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("prepare-manage", _, socket),
    do: {:noreply, assign(socket, manage_error: %{"code" => "invalid_request"})}

  def handle_event("edit", %{"edit" => %{"title" => title, "view" => view}}, socket)
      when is_binary(title) and view in ~w(line area points table) do
    if manageable?(socket, "edit") do
      definition = socket.assigns.definition

      request = %{
        "id" => socket.assigns.id,
        "title" => title,
        "query" => definition["query"],
        "visualization" => Map.put(definition["visualization"], "type", view),
        "expected_generation" => socket.assigns.manage_generation
      }

      request =
        if is_map(definition["window"]),
          do: Map.put(request, "window", definition["window"]),
          else: request

      result =
        Auth.request(socket, :save_query, %{
          "operation" => socket.assigns.manage_operation,
          "request" => request
        })

      {:noreply, socket |> stop_refresh() |> manage_result(result)}
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("edit", _, socket),
    do: {:noreply, assign(socket, manage_error: %{"code" => "invalid_request"})}

  def handle_event("delete", _, socket) do
    if manageable?(socket, "delete") do
      result =
        Auth.request(socket, :delete_query, %{
          "operation" => socket.assigns.manage_operation,
          "request" => %{
            "id" => socket.assigns.id,
            "expected_generation" => socket.assigns.manage_generation
          }
        })

      {:noreply, socket |> stop_refresh() |> manage_result(result)}
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("check-manage", _, socket), do: {:noreply, recover_manage(socket)}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:auto_refresh, epoch}, socket) do
    if is_reference(socket.assigns.refresh_timer) and epoch == socket.assigns.refresh_epoch do
      socket = socket |> check_changes() |> reschedule_refresh()
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a href="/dashboards">← All dashboards</a>
      <p class="eyebrow">Saved analytics</p>
      <div class="heading">
        <div>
          <h1>{if @definition, do: @definition["title"], else: "Dashboard unavailable"}</h1>
          <p>Every run checks your current read access and selects a new committed snapshot.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh definition</button>
      </div>
      <.notice error={@error} />
      <.offline_status projection={@result || @definition} />
      <.notice error={@manage_error} />
      <section :if={@definition} class="panel" aria-label="Automatic refresh">
        <h2>Automatic refresh</h2>
        <p>
          While this page is open, check every 5 seconds for commits in this scope and rerun the
          saved definition only after one. A rolling window also reruns every 30 seconds.
        </p>
        <button :if={is_nil(@refresh_timer)} phx-click="start-auto-refresh">
          Start auto-refresh
        </button>
        <button :if={@refresh_timer} class="secondary" phx-click="stop-auto-refresh">
          Stop auto-refresh
        </button>
        <p :if={@refresh_timer && @refresh_status == :current} role="status">
          Auto-refresh active; following committed changes from the latest successful query snapshot.
        </p>
        <p :if={@refresh_timer && @refresh_status == :stale} role="status">
          The displayed result is stale. Auto-refresh will check again in 5 seconds.
        </p>
        <.notice error={@refresh_error} />
      </section>
      <section :if={@manage_operation} class="panel">
        <h2>{if @manage_intent == "delete", do: "Delete dashboard", else: "Edit dashboard"}</h2>
        <p :if={@manage_outcome} role="status">{manage_status(@manage_intent, @manage_outcome)}</p>
        <p :if={@manage_outcome && @manage_outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@manage_operation}</p>
        <button class="secondary" phx-click="check-manage">Check operation outcome</button>
        <a href={Presenter.dashboard_path(@id)}>Start another change</a>
      </section>
      <section :if={@definition && @identity["can_manage_queries"]} class="panel">
        <h2>Manage dashboard</h2>
        <div :if={is_nil(@manage_operation)}>
          <button phx-click="prepare-manage" phx-value-intent="edit">Prepare edit</button>
          <button class="secondary" phx-click="prepare-manage" phx-value-intent="delete">
            Prepare delete
          </button>
        </div>
        <.form
          :if={
            manageable?(
              @definition,
              @manage_operation,
              @manage_intent,
              @manage_generation,
              @manage_outcome,
              "edit"
            )
          }
          for={%{}}
          id="edit-dashboard"
          phx-submit="edit"
        >
          <label for="edit-title">Title</label>
          <input id="edit-title" name="edit[title]" type="text" value={@definition["title"]} required />
          <label for="edit-view">View</label>
          <select id="edit-view" name="edit[view]">
            <option
              :for={view <- ~w(line area points table)}
              value={view}
              selected={@definition["visualization"]["type"] == view}
            >
              {view}
            </option>
          </select>
          <button type="submit" phx-disable-with="Saving…">Save changes</button>
        </.form>
        <button
          :if={
            manageable?(
              @definition,
              @manage_operation,
              @manage_intent,
              @manage_generation,
              @manage_outcome,
              "delete"
            )
          }
          phx-click="delete"
          phx-disable-with="Deleting…"
        >Delete dashboard</button>
      </section>
      <section :if={@definition} class="panel">
        <h2>Saved definition</h2>
        <dl>
          <dt>Reference</dt><dd class="identifier">{@id}</dd>
          <dt>Measurement</dt><dd>
            {Presenter.label(@definition["query"]["measurement"])} · {Presenter.unit(
              @definition["query"]["unit"]
            )}
          </dd>
          <dt>Series</dt><dd>{Enum.join(@definition["query"]["series"], ", ")}</dd>
          <dt>Window</dt><dd>{window_label(@definition["window"])}</dd>
          <dt>View</dt><dd>{@definition["visualization"]["type"]}</dd>
        </dl>
        <button phx-click="run" phx-disable-with="Querying…">Run saved query</button>
      </section>
      <section :if={@definition} class="panel" aria-labelledby="share-dashboard-title">
        <h2 id="share-dashboard-title">Share dashboard</h2>
        <p>
          This relative link contains no credential and grants no access. A recipient must sign in
          to this deployment with current read access to the same scope; every definition load and
          query run is authorized again.
        </p>
        <label for="share-dashboard-link">Scope-authorized dashboard link</label>
        <input
          id="share-dashboard-link"
          type="text"
          value={Presenter.dashboard_path(@id)}
          readonly
        />
      </section>
      <.query_result
        :if={@result && length(@result["series"]) == 1}
        result={@result}
        chart={@chart}
        view={@display_view}
      />
      <div :if={@result} class="chart-controls" role="group" aria-label="Display current result">
        <span>Display current result:</span>
        <button
          :for={view <- ~w(table line area points)}
          class="secondary"
          phx-click="change-view"
          phx-value-view={view}
          aria-pressed={to_string(@display_view == view)}
        >{view}</button>
        <span class="muted">This choice does not edit the saved dashboard.</span>
      </div>
      <div :if={@result} class="chart-controls" role="group" aria-label="Explore saved result window">
        <button class="secondary" phx-click="navigate-result" phx-value-direction="earlier">Earlier</button>
        <button class="secondary" phx-click="navigate-result" phx-value-direction="later">Later</button>
        <button class="secondary" phx-click="navigate-result" phx-value-direction="zoom_in">Zoom in</button>
        <button class="secondary" phx-click="navigate-result" phx-value-direction="zoom_out">Zoom out</button>
      </div>
      <p :if={@result && @preview_window} role="status">
        Exploring {Presenter.timestamp(%{"value" => @result["spec"]["from_at"]})} to {Presenter.timestamp(
          %{
            "value" => @result["spec"]["to_at"]
          }
        )}.
        This does not edit the saved dashboard. Run saved query to return to its window.
      </p>
      <button :if={@result} class="secondary" phx-click="export-result">
        Export result JSON
      </button>
      <section :if={@result && length(@result["series"]) > 1} class="panel">
        <h2>Query result</h2>
        <p class="identifier">Snapshot {@result["snapshot"]}</p>
        <p class="identifier">Result {@result["identity"]}</p>
        <p>
          {@result["qualified_rows"]} qualified of {@result["selected_rows"]} selected readings. {@result[
            "excluded_unavailable"
          ]} unavailable; {@result["excluded_quality"]} excluded by quality.
        </p>
        <p>
          Each series keeps its own qualified buckets. Empty buckets are gaps; no value is inferred between them.
        </p>
        <figure :if={@chart} class="history-chart">
          <svg
            viewBox="0 0 1000 300"
            role="img"
            aria-label={"#{@display_view} graph comparing #{length(@chart.series)} series of qualified #{@result["spec"]["measurement"]} buckets; exact values follow in separate tables"}
          >
            <line x1="56" y1="260" x2="944" y2="260" class="chart-axis" />
            <g
              :for={{series, index} <- Enum.with_index(@chart.series, 1)}
              class={"chart-series series-#{index}"}
            >
              <title>{series.id}</title>
              <path
                :for={segment <- series.segments}
                :if={@display_view == "area"}
                d={segment.area}
                class="chart-area"
              />
              <path
                :for={segment <- series.segments}
                :if={@display_view in ~w(line area)}
                d={segment.line}
                class="chart-line"
              />
              <circle
                :for={point <- series.points}
                :if={
                  @definition["visualization"]["show_points"] ||
                    @display_view == "points"
                }
                cx={point.x}
                cy={point.y}
                r="5"
                class="chart-point"
              >
                <title>
                  {series.id} · {timestamp(point.start_at)} · {point.value} {Presenter.unit(
                    @result["spec"]["unit"]
                  )} · {point.sample_count} samples
                </title>
              </circle>
            </g>
          </svg>
          <figcaption>
            Shared range {@chart.minimum} to {@chart.maximum} {Presenter.unit(@result["spec"]["unit"])}.
            Separate marks show gaps; use the tables for exact values and times.
          </figcaption>
          <ul :if={@definition["visualization"]["show_legend"]} class="chart-legend">
            <li :for={{series, index} <- Enum.with_index(@chart.series, 1)} class={"series-#{index}"}>
              <span class="chart-swatch" aria-hidden="true"></span>{series.id}
            </li>
          </ul>
        </figure>
        <p :if={Enum.all?(@result["series"], &(&1["points"] == []))}>
          No qualified readings in this window.
        </p>
        <div :for={series <- @result["series"]} class="table-scroll" tabindex="0">
          <h3>{series["id"]}</h3>
          <table>
            <caption>Qualified buckets for {series["id"]}</caption>
            <thead>
              <tr>
                <th scope="col">Start (UTC)</th><th scope="col">End (UTC)</th><th scope="col">
                  Value
                </th><th scope="col">Samples</th><th scope="col">Last observed (UTC)</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={point <- series["points"]}>
                <td>{timestamp(point["start_at"])}</td>
                <td>{timestamp(point["end_at"])}</td>
                <td>{point["value"]} {Presenter.unit(@result["spec"]["unit"])}</td>
                <td>{point["sample_count"]}</td>
                <td>{timestamp(point["last_event_at"])}</td>
              </tr>
            </tbody>
          </table>
          <p :if={series["points"] == []}>No qualified readings in this series.</p>
        </div>
      </section>
    </main>
    """
  end

  defp export_current_result(socket, result) do
    case QueryExport.verify(socket, result) do
      :ok ->
        {:noreply, QueryExport.push(socket, result)}

      {:error, %{"code" => code} = error}
      when code in ~w(forbidden unauthorized not_found conflict) ->
        {:noreply, assign(socket, result: nil, chart: nil, error: error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "saved_queries", "id" => socket.assigns.id}) do
      {:ok, %{"value" => definition}} ->
        assign(socket,
          definition: definition,
          result: nil,
          chart: nil,
          preview_window: false,
          display_view: definition["visualization"]["type"],
          display_override: false,
          error: nil
        )

      {:error, error} ->
        assign(socket,
          definition: nil,
          result: nil,
          chart: nil,
          preview_window: false,
          display_view: nil,
          display_override: false,
          error: error
        )
    end
  end

  defp execute(%{assigns: %{definition: nil}} = socket), do: socket

  defp execute(socket) do
    case Auth.request(socket, :execute_saved_query, %{"id" => socket.assigns.id}) do
      {:ok, result} ->
        view = socket.assigns.display_view
        chart = chart_for(result, view)
        assign(socket, result: result, chart: chart, preview_window: false, error: nil)

      {:error, error} ->
        assign(socket, result: nil, chart: nil, error: error)
    end
  end

  defp refresh_follow(socket) do
    case Auth.request(socket, :get, %{"resource" => "saved_queries", "id" => socket.assigns.id}) do
      {:ok, %{"value" => definition}} ->
        execute_follow(socket, definition)

      {:error, error} ->
        refresh_failure(socket, error)
    end
  end

  defp execute_follow(socket, definition) do
    case Auth.request(socket, :execute_saved_query, %{"id" => socket.assigns.id}) do
      {:ok, result} ->
        view =
          if socket.assigns.display_override,
            do: socket.assigns.display_view,
            else: definition["visualization"]["type"]

        chart = chart_for(result, view)

        assign(socket,
          definition: definition,
          result: result,
          chart: chart,
          preview_window: false,
          display_view: view,
          error: nil,
          refresh_status: :current,
          refresh_error: nil
        )

      {:error, error} ->
        socket |> assign(definition: definition) |> refresh_failure(error)
    end
  end

  # The snapshot cursor is taken before the run, so no later commit is missed. It
  # advances only after a successful run, so a failed run retries on the next check.
  defp follow_latest(socket) do
    case Auth.request(socket, :list, %{"resource" => "saved_queries", "params" => %{"limit" => 1}}) do
      {:ok, %{"stream_cursor" => cursor}} when is_binary(cursor) ->
        socket = refresh_follow(socket)

        if socket.assigns.refresh_status == :current and
             is_reference(socket.assigns.refresh_timer),
           do: assign(socket, follow_cursor: cursor, quiet_checks: 0),
           else: socket

      {:error, error} ->
        refresh_failure(socket, error)

      _ ->
        refresh_failure(socket, %{"code" => "storage_unavailable"})
    end
  end

  defp check_changes(%{assigns: %{follow_cursor: nil}} = socket), do: follow_latest(socket)

  # A stale result retries from a fresh snapshot even when no newer commit exists.
  defp check_changes(%{assigns: %{refresh_status: :stale}} = socket), do: follow_latest(socket)

  defp check_changes(socket) do
    case Auth.request(socket, :events, %{"cursor" => socket.assigns.follow_cursor}) do
      {:ok, %{"items" => []}} ->
        quiet(socket)

      {:ok, %{"items" => [_ | _]}} ->
        follow_latest(socket)

      {:error, %{"code" => code}} when code in ~w(cursor_expired invalid_cursor) ->
        follow_latest(socket)

      {:error, error} ->
        refresh_failure(socket, error)

      _ ->
        refresh_failure(socket, %{"code" => "storage_unavailable"})
    end
  end

  # A rolling window moves without commits, so it still reruns after quiet checks.
  defp quiet(socket) do
    checks = socket.assigns.quiet_checks + 1

    if rolling?(socket.assigns.definition) and checks >= @rolling_quiet_checks,
      do: follow_latest(socket),
      else: assign(socket, quiet_checks: checks)
  end

  defp rolling?(%{"window" => %{"kind" => "rolling"}}), do: true
  defp rolling?(_), do: false

  defp refresh_failure(socket, %{"code" => code} = error)
       when code in ~w(forbidden not_found unauthorized) do
    socket
    |> stop_refresh()
    |> assign(definition: nil, result: nil, chart: nil, error: error)
  end

  defp refresh_failure(socket, error),
    do: assign(socket, refresh_status: :stale, refresh_error: error)

  defp schedule_refresh(socket) do
    timer =
      Process.send_after(
        self(),
        {:auto_refresh, socket.assigns.refresh_epoch},
        @refresh_interval_ms
      )

    assign(socket, refresh_timer: timer)
  end

  defp reschedule_refresh(%{assigns: %{refresh_timer: timer}} = socket)
       when is_reference(timer),
       do: schedule_refresh(socket)

  defp reschedule_refresh(socket), do: socket

  defp stop_refresh(%{assigns: %{refresh_timer: timer}} = socket)
       when is_reference(timer) do
    Process.cancel_timer(timer)

    assign(socket,
      refresh_epoch: socket.assigns.refresh_epoch + 1,
      refresh_timer: nil,
      refresh_status: nil,
      refresh_error: nil,
      follow_cursor: nil,
      quiet_checks: 0
    )
  end

  defp stop_refresh(socket), do: socket

  defp window_label("absolute"), do: "Fixed absolute UTC bounds"

  defp window_label(%{"kind" => "rolling", "duration_ms" => duration}),
    do: "Rolling #{duration} ms ending at each execution"

  defp window_label(_), do: "Saved window"

  defp timestamp(value), do: Presenter.timestamp(%{"value" => value})

  defp chart_for(_, "table"), do: nil
  defp chart_for(%{"series" => [_]} = result, _), do: Chart.project(result)
  defp chart_for(result, _), do: Chart.project_many(result)

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "saved_queries", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} -> {:ok, generation}
      {:error, error} -> {:error, error}
    end
  end

  defp activate_manage(socket, nil, nil) do
    assign(socket,
      manage_operation: nil,
      manage_intent: nil,
      manage_generation: nil,
      manage_outcome: nil,
      manage_error: nil
    )
  end

  defp activate_manage(socket, operation, intent)
       when is_binary(operation) and intent in ~w(edit delete) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, manage_operation: nil, manage_error: %{"code" => "invalid_request"})

      socket.assigns.manage_operation == operation and socket.assigns.manage_intent == intent ->
        socket

      true ->
        prepared? =
          is_nil(socket.assigns.manage_operation) and is_binary(socket.assigns.manage_generation)

        assign(socket,
          manage_operation: operation,
          manage_intent: intent,
          manage_generation: if(prepared?, do: socket.assigns.manage_generation, else: nil),
          manage_outcome: nil,
          manage_error: nil
        )
    end
  end

  defp activate_manage(socket, _, _),
    do: assign(socket, manage_operation: nil, manage_error: %{"code" => "invalid_request"})

  defp recover_manage(%{assigns: %{manage_operation: nil}} = socket), do: socket

  defp recover_manage(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.manage_operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> manage_result(socket, result)
    end
  end

  defp load_manage_generation(%{assigns: %{manage_operation: nil}} = socket), do: socket
  defp load_manage_generation(%{assigns: %{manage_outcome: %{}}} = socket), do: socket

  defp load_manage_generation(%{assigns: %{manage_generation: generation}} = socket)
       when is_binary(generation),
       do: socket

  defp load_manage_generation(socket) do
    if socket.assigns.identity["can_manage_queries"] && socket.assigns.definition do
      case current_generation(socket) do
        {:ok, generation} -> assign(socket, manage_generation: generation, manage_error: nil)
        {:error, error} -> assign(socket, manage_error: error)
      end
    else
      socket
    end
  end

  defp manageable?(socket, intent) do
    assigns = socket.assigns

    assigns.identity["can_manage_queries"] &&
      manageable?(
        assigns.definition,
        assigns.manage_operation,
        assigns.manage_intent,
        assigns.manage_generation,
        assigns.manage_outcome,
        intent
      )
  end

  defp manageable?(definition, operation, current_intent, generation, outcome, intent),
    do:
      is_map(definition) and is_binary(operation) and current_intent == intent and
        is_binary(generation) and is_nil(outcome)

  defp manage_result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    expected = if(socket.assigns.manage_intent == "edit", do: "saved", else: "deleted")

    if data == %{"query_id" => socket.assigns.id, "action" => expected} do
      socket = assign(socket, manage_outcome: receipt, manage_error: nil)

      if expected == "saved",
        do: load(socket),
        else: assign(socket, definition: nil, result: nil, chart: nil, error: nil)
    else
      unrelated_manage(socket)
    end
  end

  defp manage_result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, manage_outcome: receipt, manage_error: nil)

  defp manage_result(socket, {:ok, _}), do: unrelated_manage(socket)

  defp manage_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, manage_error: error)

  defp manage_result(socket, {:error, error}),
    do: assign(socket, manage_outcome: %{"outcome" => "unknown"}, manage_error: error)

  defp unrelated_manage(socket),
    do:
      assign(socket,
        manage_outcome: %{"outcome" => "unrelated"},
        manage_error: %{"code" => "operation_mismatch"}
      )

  defp manage_status("edit", %{"outcome" => "committed"}), do: "Dashboard updated"
  defp manage_status("delete", %{"outcome" => "committed"}), do: "Dashboard deleted"
  defp manage_status(_, _), do: "Operation outcome unknown"
end
