defmodule Wotex.Tracker.UI.Components do
  @moduledoc """
  Renders evidence, measurements, positions, query results, and coded errors for LiveViews.

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

  attr(:projection, :any, default: nil)

  def offline_status(assigns) do
    assigns = assign(assigns, :offline, offline_metadata(assigns.projection))

    ~H"""
    <p :if={@offline} class="notice" role="status">
      Offline cached data · synchronized {Presenter.timestamp(%{
        "value" => @offline["synchronized_at"]
      })} · age {Presenter.duration(%{
        "type" => "integer",
        "value" => @offline["age_ms"]
      })} · {if @offline["complete"],
        do: "complete for this request",
        else: "more remote pages may exist"}. Cached access expires {Presenter.timestamp(%{
        "value" => @offline["expires_at"]
      })}.
    </p>
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
          <p class="muted">
            {measurement["availability"]} · quality: {measurement["quality"]} · reason: {Presenter.measurement_reason(
              measurement["reason"]
            )}
          </p>
        </article>
      </div>
    </section>
    """
  end

  attr(:state, :map, required: true)

  def positions(assigns) do
    assigns = assign(assigns, :positions, Map.get(assigns.state, "positions", []))

    ~H"""
    <section aria-labelledby="positions-title">
      <h2 id="positions-title">Recorded positions</h2>
      <p>
        Observed {Presenter.timestamp(@state["observed_at"])}. These are retained source claims, not a live or fused location.
      </p>
      <p :if={@positions == []}>No position was supplied by this profile.</p>
      <div :if={@positions != []} class="positions">
        <article :for={position <- @positions} class="position">
          <h3>{Presenter.position_source(position["source"])}</h3>
          <p class="coordinates">{Presenter.position_summary(position)}</p>
          <p class="muted">
            Fix {Presenter.timestamp(position["fix_at"])} · received {Presenter.timestamp(
              position["received_at"]
            )} · {position["fix_clock"]} fix clock
          </p>
        </article>
      </div>
      <p :if={@positions != []} class="muted">
        Multiple claims remain distinct. This view does not choose a canonical position or infer a route.
      </p>
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

  attr(:status, :map, required: true)

  def rule_details(assigns) do
    ~H"""
    <dl :if={@status["kind"] == "heartbeat"}>
      <dt>Last receiver observation</dt><dd>
        {Presenter.timestamp(@status["heartbeat"]["observed_at"])}
      </dd>
      <dt>Overdue after</dt><dd>{Presenter.timestamp(@status["heartbeat"]["due_at"])}</dd>
      <dt>Maximum silence</dt><dd>
        {Presenter.duration(@status["heartbeat"]["maximum_silence_ms"])}
      </dd>
      <dt>Evaluated</dt><dd>{Presenter.timestamp(@status["heartbeat"]["evaluated_at"])}</dd>
    </dl>
    <dl :if={@status["kind"] == "battery"}>
      <dt>Reading</dt>
      <dd>
        {Presenter.label(@status["battery"]["measurement"]["kind"])}: {Presenter.scalar(
          @status["battery"]["measurement"]["value"]
        )} {Presenter.unit(@status["battery"]["measurement"]["unit"])} · {@status["battery"][
          "measurement"
        ]["availability"]} · quality: {@status["battery"]["measurement"]["quality"]}
      </dd>
      <dt>Recorded</dt><dd>{Presenter.timestamp(@status["battery"]["observed_at"])}</dd>
      <dt>Low at or below</dt>
      <dd>
        {Presenter.scalar(@status["battery"]["low_threshold"])} {Presenter.unit(
          @status["battery"]["measurement"]["unit"]
        )}
      </dd>
      <dt>Clears at or above</dt>
      <dd>
        {Presenter.scalar(@status["battery"]["clear_threshold"])} {Presenter.unit(
          @status["battery"]["measurement"]["unit"]
        )}
      </dd>
      <dt>Maximum reading age</dt><dd>{Presenter.duration(@status["battery"]["maximum_age_ms"])}</dd>
      <dt>Suspect readings</dt>
      <dd>{if @status["battery"]["accept_suspect"], do: "Accepted", else: "Not accepted"}</dd>
      <dt>Evaluated</dt><dd>{Presenter.timestamp(@status["battery"]["evaluated_at"])}</dd>
    </dl>
    <dl :if={@status["kind"] == "transport_degradation"}>
      <dt>Latest route decision</dt>
      <dd>
        {@status["transport_degradation"]["decision_status"]} · action: {@status[
          "transport_degradation"
        ]["decision_action"]}
      </dd>
      <dt>Selected route</dt>
      <dd>{@status["transport_degradation"]["selected_candidate_id"] || "None"}</dd>
      <dt>Healthy routes</dt>
      <dd>{Enum.join(@status["transport_degradation"]["healthy_candidate_ids"], ", ")}</dd>
      <dt>Decided</dt><dd>{Presenter.timestamp(@status["transport_degradation"]["decided_at"])}</dd>
      <dt>Maximum decision age</dt>
      <dd>{Presenter.duration(@status["transport_degradation"]["maximum_decision_age_ms"])}</dd>
      <dt>Evaluated</dt><dd>
        {Presenter.timestamp(@status["transport_degradation"]["evaluated_at"])}
      </dd>
    </dl>
    <dl :if={@status["kind"] == "motion"}>
      <dt>Active trip</dt>
      <dd :if={@status["motion"]["active_trip"]}>
        Started {Presenter.timestamp(@status["motion"]["active_trip"]["started_at"])}, confirmed {Presenter.timestamp(
          @status["motion"]["active_trip"]["confirmed_at"]
        )}
      </dd>
      <dd :if={!@status["motion"]["active_trip"]}>No active trip</dd>
      <dt>Pending change</dt>
      <dd :if={@status["motion"]["candidate_status"]}>
        {Presenter.rule_status(@status["motion"]["candidate_status"])} since {Presenter.timestamp(
          @status["motion"]["candidate_since"]
        )}
      </dd>
      <dd :if={!@status["motion"]["candidate_status"]}>None</dd>
      <dt>Last position outcome</dt><dd>{@status["motion"]["last_received_outcome"]}</dd>
      <dt>Dwell before moving / stopped</dt>
      <dd>
        {Presenter.duration(@status["motion"]["minimum_movement_ms"])} / {Presenter.duration(
          @status["motion"]["minimum_stop_ms"]
        )}
      </dd>
    </dl>
    <dl :if={@status["kind"] == "geofence"}>
      <dt>Fence</dt>
      <dd>
        {@status["geofence"]["fence"]["id"]} · revision {@status["geofence"]["fence"]["revision"]}
      </dd>
      <dt>Membership evidence</dt>
      <dd>{@status["geofence"]["membership_reason"] || "No valid membership yet"}</dd>
      <dt>Membership time</dt>
      <dd>
        {if @status["geofence"]["membership_event_at"],
          do: Presenter.timestamp(@status["geofence"]["membership_event_at"]),
          else: "Unknown"}
      </dd>
      <dt>Last position outcome</dt><dd>{@status["geofence"]["last_received_outcome"]}</dd>
      <dt>Maximum transition gap</dt>
      <dd>{Presenter.duration(@status["geofence"]["max_transition_gap_ms"])}</dd>
    </dl>
    """
  end

  defp timestamp(value), do: Presenter.timestamp(%{"value" => value})

  defp points(%{"series" => [%{"points" => points}]}), do: points
  defp points(_), do: []

  defp offline_metadata(%{
         "_offline" =>
           %{
             "source" => "offline_cache",
             "synchronized_at" => synchronized_at,
             "age_ms" => age,
             "complete" => complete,
             "expires_at" => expires_at
           } = metadata
       })
       when is_integer(synchronized_at) and is_integer(age) and is_boolean(complete) and
              is_integer(expires_at),
       do: metadata

  defp offline_metadata(_), do: nil
end
