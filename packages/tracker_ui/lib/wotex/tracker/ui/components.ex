defmodule Wotex.Tracker.UI.Components do
  @moduledoc """
  Renders evidence, measurements, query results, and coded errors for LiveViews.

  Components consume already authorized public projections. The query result
  view pairs charts with exact tables and marks absent buckets as gaps. Callers
  remain responsible for service requests and for keeping raw evidence outside
  ordinary page assigns.
  """

  use Phoenix.Component
  alias Wotex.Tracker.UI.Presenter

  attr(:error, :any, required: true)

  def notice(assigns) do
    ~H"""
    <p :if={@error} class="notice" role="alert">{Presenter.error(@error)}</p>
    """
  end

  attr(:id, :string, required: true)
  attr(:observation, :map, required: true)
  attr(:resolution, :map, required: true)
  attr(:explanation, :string, required: true)

  def observation_evidence(assigns) do
    ~H"""
    <section class="panel">
      <h2>Observation evidence</h2>
      <dl>
        <dt>Observation reference</dt><dd class="identifier">{@id}</dd>
        <dt>Recorded</dt><dd>{Presenter.timestamp(@observation["observed_at"])}</dd>
        <dt>Source</dt><dd>{@observation["ingress"]}</dd>
        <dt>Profile match</dt><dd>{@resolution["status"]} · {@resolution["reason"]}</dd>
      </dl>
      <ul>
        <li :for={candidate <- @resolution["candidates"]}>
          {candidate["id"]} {candidate["version"]} · {candidate["confidence"]}
        </li>
      </ul>
      <p>{@explanation}</p>
    </section>
    """
  end

  attr(:state, :map, required: true)

  def measurements(assigns) do
    ~H"""
    <section aria-labelledby="measurements-title">
      <h2 id="measurements-title">Recorded measurements</h2>
      <p>
        Observed {Presenter.timestamp(@state["observed_at"])}. These are retained readings; current device connectivity is unknown.
      </p>
      <div class="measurements">
        <article :for={measurement <- @state["measurements"]} class="measurement">
          <h3>{Presenter.label(measurement["kind"])}</h3>
          <p class="reading">
            {Presenter.scalar(measurement["value"])}
            <span>{Presenter.unit(measurement["unit"])}</span>
          </p>
          <p class="muted">{measurement["availability"]} · quality: {measurement["quality"]}</p>
        </article>
      </div>
    </section>
    """
  end

  attr(:result, :map, required: true)
  attr(:chart, :any, required: true)
  attr(:view, :string, required: true)

  def query_result(assigns) do
    ~H"""
    <section class="panel" aria-labelledby="analytics-result-title">
      <h2 id="analytics-result-title">Query result</h2>
      <p>
        {@result["spec"]["aggregation"]} of {Presenter.label(@result["spec"]["measurement"])} ({Presenter.unit(
          @result["spec"]["unit"]
        )}) · {@result["qualified_rows"]} qualified of {@result["selected_rows"]} selected readings.
      </p>
      <p class="muted">
        {@result["excluded_unavailable"]} unavailable and {@result["excluded_quality"]} excluded by quality.
        Buckets with no qualified reading are absent; no line or value is inferred across a gap.
        Aggregation is at the requested bucket width.
      </p>
      <p class="identifier">Snapshot {@result["snapshot"]}</p>
      <p class="identifier">Result {@result["identity"]}</p>
      <figure :if={@chart} class="history-chart">
        <svg
          viewBox="0 0 1000 300"
          role="img"
          aria-label={"#{@view} graph of qualified #{@result["spec"]["measurement"]} buckets; exact values follow in the table"}
        >
          <line x1="56" y1="260" x2="944" y2="260" class="chart-axis" />
          <path
            :for={segment <- @chart.segments}
            :if={@view == "area"}
            d={segment.area}
            class="chart-area"
          />
          <path
            :for={segment <- @chart.segments}
            :if={@view in ~w(line area)}
            d={segment.line}
            class="chart-line"
          />
          <circle
            :for={point <- @chart.points}
            cx={point.x}
            cy={point.y}
            r="5"
            class="chart-point"
          >
            <title>
              {timestamp(point.start_at)} · {point.value} {Presenter.unit(@result["spec"]["unit"])} · {point.sample_count} samples
            </title>
          </circle>
        </svg>
        <figcaption>
          {@view} view · range {@chart.minimum} to {@chart.maximum}
          {Presenter.unit(@result["spec"]["unit"])}. Area fill extends to the chart floor.
          Separate marks show gaps; use the table for exact values and times.
        </figcaption>
      </figure>
      <div class="table-scroll" tabindex="0" role="region" aria-labelledby="analytics-result-title">
        <table>
          <caption>Qualified bucket values at the recorded snapshot</caption>
          <thead>
            <tr>
              <th scope="col">Bucket start (UTC)</th><th scope="col">Bucket end (UTC)</th><th scope="col">
                Value
              </th><th scope="col">Samples</th><th scope="col">Last observed (UTC)</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={point <- points(@result)}>
              <td>{timestamp(point["start_at"])}</td>
              <td>{timestamp(point["end_at"])}</td>
              <td>{point["value"]} {Presenter.unit(@result["spec"]["unit"])}</td>
              <td>{point["sample_count"]}</td>
              <td>{timestamp(point["last_event_at"])}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p :if={points(@result) == []}>No qualified readings in this window.</p>
    </section>
    """
  end

  defp timestamp(value), do: Presenter.timestamp(%{"value" => value})

  defp points(%{"series" => [%{"points" => points}]}), do: points
  defp points(_), do: []
end
