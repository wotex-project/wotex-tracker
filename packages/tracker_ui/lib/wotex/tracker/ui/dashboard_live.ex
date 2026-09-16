defmodule Wotex.Tracker.UI.DashboardLive do
  @moduledoc "Re-executes a saved definition under current read authority."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Chart, Presenter}

  @impl true
  def mount(_, _, socket) do
    {:ok, assign(socket, id: nil, definition: nil, result: nil, chart: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket),
    do: {:noreply, socket |> assign(id: id) |> load()}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("run", _, socket) do
    {:noreply, socket |> load() |> execute()}
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

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

  defp window_label("absolute"), do: "Fixed absolute UTC bounds"

  defp window_label(%{"kind" => "rolling", "duration_ms" => duration}),
    do: "Rolling #{duration} ms ending at each execution"

  defp window_label(_), do: "Saved window"

  defp timestamp(value), do: Presenter.timestamp(%{"value" => value})
end
