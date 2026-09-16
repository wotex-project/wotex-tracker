defmodule Wotex.Tracker.UI.AnalyticsLive do
  @moduledoc "Bounded structured measurement queries for one authorized asset."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Chart, Presenter}

  @buckets %{"hour" => 3_600_000, "six_hours" => 21_600_000, "day" => 86_400_000}
  @aggregations %{
    "count" => :count,
    "min" => :min,
    "max" => :max,
    "mean" => :mean,
    "last" => :last
  }
  @counter_kinds ~w(movementCounter measurementSequence)
  @max_browser_time 253_402_300_799_999

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       asset: nil,
       state: nil,
       measurements: [],
       query: %{},
       result: nil,
       chart: nil,
       save_operation: nil,
       save_generation: nil,
       save_title: nil,
       save_outcome: nil,
       save_error: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket =
      if socket.assigns.id == id and socket.assigns.asset do
        socket
      else
        socket
        |> assign(id: id, result: nil, chart: nil, error: nil, save_generation: nil)
        |> load()
      end

    {:noreply, socket |> activate_save(params["save_operation"]) |> recover_save()}
  end

  @impl true
  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> assign(result: nil, chart: nil, error: nil) |> load()}

  def handle_event("run", %{"query" => input}, %{assigns: %{state: %{}, asset: %{}}} = socket)
      when is_map(input) do
    {:noreply, run_query(socket, input)}
  end

  def handle_event("navigate", %{"direction" => direction}, %{assigns: %{result: %{}}} = socket) do
    with {:ok, from_at} <- utc_milliseconds(socket.assigns.query["from"]),
         {:ok, to_at} <- utc_milliseconds(socket.assigns.query["to"]),
         {:ok, {new_from, new_to}} <- move_window(direction, from_at, to_at) do
      input =
        socket.assigns.query
        |> Map.put("from", iso8601(new_from))
        |> Map.put("to", iso8601(new_to))

      {:noreply, run_query(socket, input)}
    else
      _ -> {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event(
        "prepare-save",
        _,
        %{
          assigns: %{
            result: %{},
            save_operation: nil,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      ) do
    case Auth.request(socket, :list, %{"resource" => "saved_queries", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} ->
        socket =
          assign(socket,
            save_generation: generation,
            save_title:
              socket.assigns.asset["title"] <>
                " " <>
                Presenter.label(socket.assigns.result["spec"]["measurement"]),
            save_error: nil
          )

        {:noreply,
         push_patch(socket,
           to:
             Presenter.path(:asset, socket.assigns.id) <>
               "/analytics?save_operation=" <>
               Identifier.uuid()
         )}

      {:error, error} ->
        {:noreply, assign(socket, save_error: error)}
    end
  end

  def handle_event("prepare-save", _, socket),
    do: {:noreply, assign(socket, save_error: %{"code" => "forbidden"})}

  def handle_event(
        "save",
        %{"save" => %{"title" => title, "window" => window}},
        %{
          assigns: %{
            result: %{},
            save_operation: operation,
            save_generation: generation,
            save_outcome: nil,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(title) and is_binary(operation) and is_binary(generation) and
             window in ~w(absolute rolling) do
    socket = assign(socket, save_title: title)
    request = save_request(socket, title, window)

    result =
      Auth.request(socket, :save_query, %{"operation" => operation, "request" => request})

    {:noreply, save_result(socket, result)}
  end

  def handle_event("save", _, socket),
    do:
      {:noreply,
       if(socket.assigns.save_outcome,
         do: socket,
         else: assign(socket, save_error: %{"code" => "forbidden"})
       )}

  def handle_event("check-save", _, socket), do: {:noreply, recover_save(socket)}

  def handle_event("run", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a :if={@id} href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Measurement history · structured query</p>
      <div class="heading">
        <div>
          <h1>{if @asset, do: @asset["title"] <> " analytics", else: "Asset analytics"}</h1>
          <p>Query qualified retained readings at one committed snapshot.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh asset</button>
      </div>
      <.notice error={@error} />
      <p :if={@asset && is_nil(@state)} class="notice">
        Provision this asset's Thing to record measurements before querying history.
      </p>
      <p :if={@state && @measurements == []} class="notice">
        This retained state has no numeric measurement available for a structured query.
      </p>
      <section :if={@asset && @measurements != []} class="panel">
        <h2>Choose a query</h2>
        <p>
          The default window ends just after the latest retained observation. Times are UTC; the start is included and the end is excluded.
        </p>
        <.form for={%{}} id="analytics-query" phx-submit="run">
          <label for="query-measurement">Measurement</label>
          <select id="query-measurement" name="query[measurement]">
            <option
              :for={measurement <- @measurements}
              value={measurement["kind"]}
              selected={@query["measurement"] == measurement["kind"]}
            >
              {Presenter.label(measurement["kind"])} · {Presenter.unit(measurement["unit"])}
            </option>
          </select>
          <label for="query-aggregation">Aggregation</label>
          <select id="query-aggregation" name="query[aggregation]">
            <option
              :for={name <- ~w(last mean min max count)}
              value={name}
              selected={@query["aggregation"] == name}
            >
              {name}
            </option>
          </select>
          <label for="query-from">From (UTC, inclusive)</label>
          <input id="query-from" name="query[from]" type="text" value={@query["from"]} required />
          <label for="query-to">To (UTC, exclusive)</label>
          <input id="query-to" name="query[to]" type="text" value={@query["to"]} required />
          <label for="query-bucket">Bucket width</label>
          <select id="query-bucket" name="query[bucket]">
            <option value="hour" selected={@query["bucket"] == "hour"}>1 hour</option>
            <option value="six_hours" selected={@query["bucket"] == "six_hours"}>6 hours</option>
            <option value="day" selected={@query["bucket"] == "day"}>1 day</option>
          </select>
          <label for="query-view">Graph view</label>
          <select id="query-view" name="query[view]">
            <option value="line" selected={@query["view"] == "line"}>Line</option>
            <option value="area" selected={@query["view"] == "area"}>Area</option>
            <option value="points" selected={@query["view"] == "points"}>Points</option>
          </select>
          <button type="submit" phx-disable-with="Querying…">Run query</button>
        </.form>
        <p class="muted">
          Queries are limited to 31 days and 1,000 requested buckets. Counter readings cannot be averaged.
        </p>
      </section>
      <div :if={@result} class="chart-controls" role="group" aria-label="Explore time window">
        <button class="secondary" phx-click="navigate" phx-value-direction="earlier">Earlier</button>
        <button class="secondary" phx-click="navigate" phx-value-direction="later">Later</button>
        <button class="secondary" phx-click="navigate" phx-value-direction="zoom_in">Zoom in</button>
        <button class="secondary" phx-click="navigate" phx-value-direction="zoom_out">Zoom out</button>
      </div>
      <.query_result :if={@result} result={@result} chart={@chart} view={@query["view"]} />
      <.notice error={@save_error} />
      <section :if={(@result && @identity["can_manage_queries"]) || @save_operation} class="panel">
        <h2>Save this query</h2>
        <p :if={@result}>Save the admitted query and graph choice for later authorized runs.</p>
        <button
          :if={@result && @identity["can_manage_queries"] && is_nil(@save_operation)}
          phx-click="prepare-save"
        >Prepare save</button>
        <.form
          :if={
            @result && @identity["can_manage_queries"] && @save_operation && @save_generation &&
              is_nil(@save_outcome)
          }
          for={%{}}
          id="save-dashboard"
          phx-submit="save"
        >
          <label for="save-title">Dashboard title</label>
          <input id="save-title" type="text" name="save[title]" value={@save_title} required />
          <label for="save-window">Window policy</label>
          <select id="save-window" name="save[window]">
            <option value="absolute">Fixed incident window</option>
            <option value="rolling">Rolling window ending at each run</option>
          </select>
          <button type="submit" phx-disable-with="Saving…">Save dashboard</button>
        </.form>
        <p :if={@save_outcome} role="status">
          {if @save_outcome["outcome"] == "committed",
            do: "Dashboard saved",
            else: "Save outcome unknown"}
        </p>
        <a
          :if={@save_outcome && @save_outcome["outcome"] == "committed"}
          href={Presenter.dashboard_path(saved_id(@save_operation))}
        >Open saved dashboard</a>
        <p :if={@save_outcome && @save_outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before saving again.
        </p>
        <p :if={@save_operation} class="identifier">Save operation {@save_operation}</p>
        <p :if={@save_operation && is_nil(@result) && is_nil(@save_outcome)}>
          Rerun a query to finish this prepared save.
        </p>
        <button :if={@save_operation} class="secondary" phx-click="check-save">
          Check save outcome
        </button>
      </section>
    </main>
    """
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{
           "resource" => "enrollments",
           "id" => socket.assigns.id
         }) do
      {:ok, asset} ->
        case Auth.request(socket, :get, %{"resource" => "state", "id" => socket.assigns.id}) do
          {:ok, %{"value" => state}} ->
            measurements = numeric_measurements(state)

            assign(socket,
              asset: asset["value"],
              state: state,
              measurements: measurements,
              query: default_query(state, measurements),
              error: nil
            )

          {:error, %{"code" => "not_found"}} ->
            assign(socket, asset: asset["value"], state: nil, measurements: [], query: %{})

          {:error, error} ->
            assign(socket, asset: asset["value"], state: nil, measurements: [], error: error)
        end

      {:error, error} ->
        assign(socket, asset: nil, state: nil, measurements: [], query: %{}, error: error)
    end
  end

  defp numeric_measurements(state) do
    state["measurements"]
    |> Enum.filter(&is_number(get_in(&1, ["value", "value"])))
    |> Enum.uniq_by(& &1["kind"])
  end

  defp default_query(state, [first | _]) do
    end_at = state["observed_at"]["value"] + 1

    %{
      "measurement" => first["kind"],
      "aggregation" => if(first["kind"] in @counter_kinds, do: "last", else: "mean"),
      "from" => iso8601(max(0, end_at - 86_400_000)),
      "to" => iso8601(end_at),
      "bucket" => "hour",
      "view" => "line"
    }
  end

  defp default_query(_, []), do: %{}

  defp activate_save(socket, nil) do
    assign(socket,
      save_operation: nil,
      save_generation: nil,
      save_title: nil,
      save_outcome: nil,
      save_error: nil
    )
  end

  defp activate_save(socket, operation) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, save_operation: nil, save_error: %{"code" => "invalid_request"})

      socket.assigns.save_operation == operation ->
        socket

      true ->
        prepared? = is_nil(socket.assigns.save_operation) and is_map(socket.assigns.result)

        assign(socket,
          save_operation: operation,
          save_generation: if(prepared?, do: socket.assigns.save_generation, else: nil),
          save_title: if(prepared?, do: socket.assigns.save_title, else: nil),
          save_outcome: nil,
          save_error: nil
        )
    end
  end

  defp recover_save(%{assigns: %{save_operation: nil}} = socket), do: socket

  defp recover_save(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.save_operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> save_result(socket, result)
    end
  end

  defp save_result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    expected = saved_id(socket.assigns.save_operation)

    if data == %{"query_id" => expected, "action" => "saved"} do
      verify_saved(socket, expected, receipt)
    else
      unrelated_save(socket)
    end
  end

  defp save_result(socket, {:ok, %{"outcome" => "unknown"} = result}),
    do: assign(socket, save_outcome: result, save_error: nil)

  defp save_result(socket, {:ok, _}), do: unrelated_save(socket)

  defp save_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, save_error: error)

  defp save_result(socket, {:error, error}),
    do: assign(socket, save_outcome: %{"outcome" => "unknown"}, save_error: error)

  defp verify_saved(socket, id, receipt) do
    asset = socket.assigns.id

    case Auth.request(socket, :get, %{"resource" => "saved_queries", "id" => id}) do
      {:ok, %{"value" => %{"query" => %{"series" => [^asset]}}}} ->
        assign(socket, save_outcome: receipt, save_error: nil)

      {:error, error} ->
        assign(socket, save_outcome: %{"outcome" => "unknown"}, save_error: error)

      _ ->
        unrelated_save(socket)
    end
  end

  defp unrelated_save(socket),
    do:
      assign(socket,
        save_outcome: %{"outcome" => "unrelated"},
        save_error: %{"code" => "operation_mismatch"}
      )

  defp saved_id(operation), do: "dashboard-" <> operation

  defp save_request(socket, title, window) do
    query = socket.assigns.result["spec"]

    request = %{
      "id" => saved_id(socket.assigns.save_operation),
      "title" => title,
      "query" => query,
      "visualization" => %{
        "type" => socket.assigns.query["view"],
        "show_legend" => true,
        "show_points" => true
      },
      "expected_generation" => socket.assigns.save_generation
    }

    if window == "rolling",
      do:
        Map.put(request, "window", %{
          "kind" => "rolling",
          "duration_ms" => query["to_at"] - query["from_at"]
        }),
      else: request
  end

  defp load_save_generation(%{assigns: %{save_operation: nil}} = socket), do: socket
  defp load_save_generation(%{assigns: %{save_outcome: %{}}} = socket), do: socket

  defp load_save_generation(%{assigns: %{save_generation: generation}} = socket)
       when is_binary(generation),
       do: socket

  defp load_save_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "saved_queries", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} ->
        assign(socket,
          save_generation: generation,
          save_title:
            socket.assigns.asset["title"] <>
              " " <>
              Presenter.label(socket.assigns.result["spec"]["measurement"]),
          save_error: nil
        )

      {:error, error} ->
        assign(socket, save_error: error)
    end
  end

  defp document(socket, input) do
    with %{"unit" => unit} = measurement <-
           Enum.find(socket.assigns.measurements, &(&1["kind"] == input["measurement"])),
         {:ok, aggregation} <- aggregation(input["aggregation"], measurement["kind"]),
         {:ok, from_at} <- utc_milliseconds(input["from"]),
         {:ok, to_at} <- utc_milliseconds(input["to"]),
         bucket_ms when is_integer(bucket_ms) <- @buckets[input["bucket"]],
         {:ok, spec} <-
           QuerySpec.new(%{
             id: "browser-measurement-history",
             revision: "service-query-v1",
             dataset: :measurements,
             measurement: measurement["kind"],
             unit: unit,
             series: [socket.assigns.id],
             qualities: [:valid],
             from_at: from_at,
             to_at: to_at,
             timezone: "Etc/UTC",
             bucket_ms: bucket_ms,
             aggregation: aggregation,
             order: :ascending,
             max_points: 1_000
           }),
         {:ok, document} <- QuerySpec.to_map(spec) do
      {:ok, document}
    else
      _ -> {:error, %{"code" => "invalid_request"}}
    end
  end

  defp run_query(socket, input) do
    socket = assign(socket, query: input, result: nil, chart: nil, error: nil)

    with view when view in ~w(line area points) <- input["view"],
         {:ok, document} <- document(socket, input),
         {:ok, result} <- Auth.request(socket, :analytics, %{"query" => document}) do
      socket |> assign(result: result, chart: Chart.project(result)) |> load_save_generation()
    else
      {:error, %{"code" => _} = error} -> assign(socket, error: error)
      _ -> assign(socket, error: %{"code" => "invalid_request"})
    end
  end

  defp move_window(direction, from_at, to_at) when to_at > from_at do
    width = to_at - from_at
    bounds = window_bounds(direction, from_at, to_at, width)

    case bounds do
      {start_at, end_at}
      when start_at >= 0 and end_at > start_at and end_at <= @max_browser_time ->
        {:ok, bounds}

      _ ->
        :error
    end
  end

  defp move_window(_, _, _), do: :error

  defp window_bounds("earlier", from_at, to_at, width),
    do: {from_at - div(width, 2), to_at - div(width, 2)}

  defp window_bounds("later", from_at, to_at, width),
    do: {from_at + div(width, 2), to_at + div(width, 2)}

  defp window_bounds("zoom_in", from_at, to_at, width),
    do: {from_at + div(width, 4), to_at - div(width, 4)}

  defp window_bounds("zoom_out", from_at, to_at, width),
    do: {from_at - div(width, 2), to_at + div(width, 2)}

  defp window_bounds(_, _, _, _), do: :invalid

  defp aggregation("mean", kind) when kind in @counter_kinds, do: :error
  defp aggregation(value, _), do: Map.fetch(@aggregations, value)

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
end
