defmodule Wotex.Tracker.UI.DashboardLive do
  @moduledoc "Re-executes a saved definition under current read authority."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Chart, Presenter}
  @refresh_interval_ms 30_000

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       definition: nil,
       result: nil,
       chart: nil,
       error: nil,
       manage_operation: nil,
       manage_intent: nil,
       manage_generation: nil,
       manage_outcome: nil,
       manage_error: nil,
       refresh_epoch: 0,
       refresh_timer: nil,
       refresh_status: nil,
       refresh_error: nil
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
        |> refresh_follow()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stop-auto-refresh", _, socket), do: {:noreply, stop_refresh(socket)}

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
      socket = socket |> refresh_follow() |> reschedule_refresh()
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
      <.notice error={@manage_error} />
      <section :if={@definition} class="panel" aria-label="Automatic refresh">
        <h2>Automatic refresh</h2>
        <p>Recheck this saved definition and rerun it every 30 seconds while this page is open.</p>
        <button :if={is_nil(@refresh_timer)} phx-click="start-auto-refresh">
          Start auto-refresh
        </button>
        <button :if={@refresh_timer} class="secondary" phx-click="stop-auto-refresh">
          Stop auto-refresh
        </button>
        <p :if={@refresh_timer && @refresh_status == :current} role="status">
          Auto-refresh active; showing the latest successful query snapshot.
        </p>
        <p :if={@refresh_timer && @refresh_status == :stale} role="status">
          The displayed result is stale. Auto-refresh will retry in 30 seconds.
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
      <.query_result
        :if={@result && length(@result["series"]) == 1}
        result={@result}
        chart={@chart}
        view={@definition["visualization"]["type"]}
      />
      <section :if={@result && length(@result["series"]) > 1} class="panel">
        <h2>Query result</h2>
        <p class="identifier">Snapshot {@result["snapshot"]}</p>
        <p>
          {@result["qualified_rows"]} qualified of {@result["selected_rows"]} selected readings. {@result[
            "excluded_unavailable"
          ]} unavailable; {@result["excluded_quality"]} excluded by quality.
        </p>
        <p>Each series is shown separately. Empty buckets are gaps.</p>
        <div :for={series <- @result["series"]} class="table-scroll" tabindex="0">
          <h3>{series["id"]}</h3>
          <table>
            <caption>Qualified buckets for {series["id"]}</caption>
            <thead>
              <tr>
                <th scope="col">Start (UTC)</th><th scope="col">End (UTC)</th><th scope="col">
                  Value
                </th><th scope="col">Samples</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={point <- series["points"]}>
                <td>{timestamp(point["start_at"])}</td>
                <td>{timestamp(point["end_at"])}</td>
                <td>{point["value"]} {Presenter.unit(@result["spec"]["unit"])}</td>
                <td>{point["sample_count"]}</td>
              </tr>
            </tbody>
          </table>
          <p :if={series["points"] == []}>No qualified readings in this series.</p>
        </div>
      </section>
    </main>
    """
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "saved_queries", "id" => socket.assigns.id}) do
      {:ok, %{"value" => definition}} ->
        assign(socket, definition: definition, result: nil, chart: nil, error: nil)

      {:error, error} ->
        assign(socket, definition: nil, result: nil, chart: nil, error: error)
    end
  end

  defp execute(%{assigns: %{definition: nil}} = socket), do: socket

  defp execute(socket) do
    case Auth.request(socket, :execute_saved_query, %{"id" => socket.assigns.id}) do
      {:ok, result} ->
        view = socket.assigns.definition["visualization"]["type"]
        chart = if view == "table", do: nil, else: Chart.project(result)
        assign(socket, result: result, chart: chart, error: nil)

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
        view = definition["visualization"]["type"]
        chart = if view == "table", do: nil, else: Chart.project(result)

        assign(socket,
          definition: definition,
          result: result,
          chart: chart,
          error: nil,
          refresh_status: :current,
          refresh_error: nil
        )

      {:error, error} ->
        socket |> assign(definition: definition) |> refresh_failure(error)
    end
  end

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
      refresh_error: nil
    )
  end

  defp stop_refresh(socket), do: socket

  defp window_label("absolute"), do: "Fixed absolute UTC bounds"

  defp window_label(%{"kind" => "rolling", "duration_ms" => duration}),
    do: "Rolling #{duration} ms ending at each execution"

  defp window_label(_), do: "Saved window"

  defp timestamp(value), do: Presenter.timestamp(%{"value" => value})

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
