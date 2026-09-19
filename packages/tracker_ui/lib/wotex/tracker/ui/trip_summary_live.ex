defmodule Wotex.Tracker.UI.TripSummaryLive do
  @moduledoc """
  Presents one service-reconstructed final trip distance without private inputs.

  The view accepts only the closed public summary shape, preserves every
  excluded segment and reauthorizes refresh and export. It never reconstructs a
  route or distance in the browser.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Codec
  alias Wotex.Tracker.UI.{Auth, Presenter, TripSummaryExport}

  @private_keys ~w(
    observation observation_id source_observation_ids evidence evidence_id evidence_ids
    position_evidence_id bundle bundle_identity position_bundle_identity sample sample_identity
    start_sample_identity end_sample_identity from_sample_identity to_sample_identity
    from_position_evidence_id to_position_evidence_id from_position_bundle_identity
    to_position_bundle_identity policy_identity
  )
  @segment_statuses ~w(moving stationary indeterminate unknown)

  @impl true
  def mount(_, _, socket),
    do: {:ok, assign(socket, id: nil, trip_id: nil, asset: nil, summary: nil, error: nil)}

  @impl true
  def handle_params(%{"id" => id, "trip_id" => trip}, _, socket) do
    socket =
      if socket.assigns.id == id and socket.assigns.trip_id == trip do
        socket
      else
        socket
        |> assign(id: id, trip_id: trip, asset: nil, summary: nil, error: nil)
        |> load()
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("export", _, %{assigns: %{summary: %{} = summary}} = socket) do
    with :ok <-
           TripSummaryExport.verify(socket, socket.assigns.id, socket.assigns.trip_id, summary),
         {:ok, socket} <- TripSummaryExport.push(socket, summary) do
      {:noreply, socket}
    else
      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        {:noreply, clear(socket, error)}

      {:error, %{"code" => "conflict"} = error} ->
        {:noreply, assign(socket, summary: nil, error: error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("export", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a :if={@id} href={Presenter.path(:asset, @id) <> "/trips"}>← Trip event timeline</a>
      <p class="eyebrow">Movement history · retained final distance</p>
      <div class="heading">
        <div>
          <h1>{if @asset, do: @asset["title"] <> " trip distance", else: "Trip distance"}</h1>
          <p>Inspect the service's bounded, gap-honest reconstruction of one completed trip.</p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh summary</button>
      </div>
      <.notice error={@error} />
      <section :if={@summary} class="panel" aria-labelledby="trip-summary-title">
        <h2 id="trip-summary-title">Final distance summary</h2>
        <p class="reading">{distance(@summary["center_distance_m"])} m</p>
        <p>
          Bounded from {distance(@summary["lower_distance_m"])} m to {distance(
            @summary["upper_distance_m"]
          )} m.
        </p>
        <p class="notice">
          {summary_status(@summary)} The browser does not join excluded segments or infer a route.
        </p>
        <dl>
          <dt>Trip started</dt><dd>{timestamp(@summary["started_at"])}</dd>
          <dt>Movement confirmed</dt><dd>{timestamp(@summary["confirmed_moving_at"])}</dd>
          <dt>{terminal_label(@summary["terminal_kind"])}</dt>
          <dd>{timestamp(@summary["ended_at"])}</dd>
          <dt>Ending confirmed</dt><dd>{timestamp(@summary["confirmed_ended_at"])}</dd>
          <dt>Terminal reason</dt><dd>{label(@summary["terminal_reason"])}</dd>
          <dt>Samples</dt><dd>{@summary["sample_count"]}</dd>
          <dt>Segments</dt>
          <dd>
            {@summary["included_segment_count"]} included · {@summary[
              "excluded_segment_count"
            ]} excluded
          </dd>
          <dt>Motion policy revision</dt><dd>{@summary["rule_revision"]}</dd>
          <dt>Terminal generation</dt><dd>{@summary["snapshot_generation"]}</dd>
        </dl>
        <div class="table-scroll" tabindex="0" role="region" aria-labelledby="segments-title">
          <table>
            <caption id="segments-title">Every adjacent retained segment used by the summary</caption>
            <thead>
              <tr>
                <th scope="col">Event time</th>
                <th scope="col">Decision</th>
                <th scope="col">Reason</th>
                <th scope="col">Centre</th>
                <th scope="col">Bounds</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={segment <- @summary["segments"]}>
                <td>{timestamp(segment["event_at"])}</td>
                <td>
                  {if segment["included"], do: "Included", else: "Excluded"} · {segment["status"]}
                </td>
                <td>{label(segment["reason"])}</td>
                <td>{segment_distance(segment, "center_distance_m")}</td>
                <td>{segment_bounds(segment)}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="muted">
          Distances are canonical metres from the service. Excluded segments have no invented
          distance. No observation, evidence, bundle, sample or policy identity is present here.
        </p>
        <p class="identifier">Summary {@summary["identity"]}</p>
        <button class="secondary" phx-click="export">Export this final summary (JSON)</button>
      </section>
    </main>
    """
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}) do
      {:ok, %{"value" => asset}} ->
        load_summary(assign(socket, asset: asset))

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)

      _ ->
        clear(socket, %{"code" => "storage_unavailable"})
    end
  end

  defp load_summary(socket) do
    case Auth.request(socket, :trip_summary, %{
           "thing" => socket.assigns.id,
           "trip" => socket.assigns.trip_id
         }) do
      {:ok, summary} ->
        if summary?(summary, socket.assigns.id, socket.assigns.trip_id),
          do: assign(socket, summary: summary, error: nil),
          else: assign(socket, summary: nil, error: %{"code" => "storage_unavailable"})

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        clear(socket, error)

      {:error, %{"code" => "not_found"} = error} ->
        assign(socket, summary: nil, error: error)

      {:error, %{"code" => code} = error} when code in ~w(unavailable capacity_exceeded) ->
        assign(socket, summary: nil, error: summary_error(error))

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp summary?(
         %{
           "schema" => "wtr.trip-summary.v1",
           "algorithm" => "ordered-moving-segment-sum-v1",
           "thing_id" => thing,
           "trip_id" => trip,
           "snapshot_generation" => generation,
           "terminal_kind" => terminal_kind,
           "terminal_reason" => terminal_reason,
           "started_at" => started_at,
           "confirmed_moving_at" => confirmed_moving_at,
           "ended_at" => ended_at,
           "confirmed_ended_at" => confirmed_ended_at,
           "status" => status,
           "reason" => reason,
           "sample_count" => sample_count,
           "included_segment_count" => included,
           "excluded_segment_count" => excluded,
           "center_distance_m" => center,
           "lower_distance_m" => lower,
           "upper_distance_m" => upper,
           "segments" => segments,
           "rule_revision" => revision,
           "identity" => identity
         } = summary,
         thing,
         trip
       ) do
    map_size(summary) == 22 and metadata?(generation, terminal_kind, terminal_reason, revision) and
      timeline?(started_at, confirmed_moving_at, ended_at, confirmed_ended_at) and
      status_reason?(status, reason, excluded) and
      cohort?(sample_count, included, excluded, segments, started_at, confirmed_ended_at) and
      distance_summary?(segments, lower, center, upper) and identity?(identity) and
      public?(summary)
  end

  defp summary?(_, _, _), do: false

  defp metadata?(generation, terminal_kind, terminal_reason, revision),
    do:
      match?({:ok, _}, Codec.generation(generation)) and
        terminal_kind in ~w(trip.stopped trip.interrupted) and Codec.id?(terminal_reason) and
        Codec.id?(revision)

  defp timeline?(started_at, confirmed_moving_at, ended_at, confirmed_ended_at),
    do:
      Enum.all?([started_at, confirmed_moving_at, ended_at, confirmed_ended_at], &Codec.time?/1) and
        started_at <= confirmed_moving_at and confirmed_moving_at <= ended_at and
        ended_at <= confirmed_ended_at

  defp cohort?(sample_count, included, excluded, segments, started_at, ended_at),
    do:
      counts?(sample_count, included, excluded) and is_list(segments) and
        length(segments) == sample_count - 1 and
        Enum.all?(segments, &segment?(&1, started_at, ended_at)) and
        Enum.count(segments, & &1["included"]) == included

  defp counts?(sample_count, included, excluded),
    do:
      is_integer(sample_count) and sample_count in 2..100 and is_integer(included) and
        is_integer(excluded) and included >= 0 and excluded >= 0 and
        included + excluded == sample_count - 1

  defp distance_summary?(segments, lower, center, upper),
    do: distance_bounds?(lower, center, upper) and totals?(segments, lower, center, upper)

  defp status_reason?("complete", "all_segments_included", 0), do: true
  defp status_reason?("partial", "segments_excluded", excluded) when excluded > 0, do: true
  defp status_reason?(_, _, _), do: false

  defp segment?(
         %{
           "schema" => "wtr.trip-distance-segment.v1",
           "event_at" => event_at,
           "status" => status,
           "reason" => reason,
           "included" => included,
           "center_distance_m" => center,
           "lower_distance_m" => lower,
           "upper_distance_m" => upper
         } = segment,
         started_at,
         ended_at
       ) do
    map_size(segment) == 8 and Codec.time?(event_at) and event_at >= started_at and
      event_at <= ended_at and status in @segment_statuses and Codec.id?(reason) and
      is_boolean(included) and segment_distances?(included, lower, center, upper)
  end

  defp segment?(_, _, _), do: false

  defp segment_distances?(true, lower, center, upper),
    do: distance_bounds?(lower, center, upper)

  defp segment_distances?(false, nil, nil, nil), do: true
  defp segment_distances?(_, _, _, _), do: false

  defp distance_bounds?(lower, center, upper),
    do:
      Enum.all?([lower, center, upper], &(is_number(&1) and &1 >= 0)) and lower <= center and
        center <= upper

  defp totals?(segments, lower, center, upper) do
    included = Enum.filter(segments, & &1["included"])

    sum(included, "lower_distance_m") == lower and
      sum(included, "center_distance_m") == center and
      sum(included, "upper_distance_m") == upper
  end

  defp sum(segments, key), do: Enum.reduce(segments, 0.0, &(&1[key] + &2))

  defp identity?("wtr-trip-summary-v1:sha256:" <> digest),
    do: byte_size(digest) == 64 and String.match?(digest, ~r/\A[0-9a-f]+\z/)

  defp identity?(_), do: false

  defp public?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> key not in @private_keys and public?(nested) end)
  end

  defp public?(value) when is_list(value), do: Enum.all?(value, &public?/1)
  defp public?(_), do: true

  defp timestamp(value), do: Presenter.timestamp(%{"value" => value})
  defp distance(value) when is_float(value), do: Float.to_string(value)
  defp distance(value) when is_integer(value), do: Integer.to_string(value)

  defp segment_distance(%{"included" => true} = segment, key),
    do: distance(segment[key]) <> " m"

  defp segment_distance(_, _), do: "Excluded"

  defp segment_bounds(%{"included" => true} = segment),
    do: "#{distance(segment["lower_distance_m"])}–#{distance(segment["upper_distance_m"])} m"

  defp segment_bounds(_), do: "Excluded"

  defp summary_status(%{"status" => "complete"}),
    do: "Every adjacent segment qualified and was included."

  defp summary_status(%{"status" => "partial", "excluded_segment_count" => count}),
    do: "Partial total: #{count} adjacent segment(s) were excluded explicitly."

  defp terminal_label("trip.stopped"), do: "Trip stopped"
  defp terminal_label("trip.interrupted"), do: "Trip interrupted"
  defp label(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp summary_error(%{"code" => "unavailable"} = error),
    do: Map.put(error, "code", "trip_summary_unavailable")

  defp summary_error(%{"code" => "capacity_exceeded"} = error),
    do: Map.put(error, "code", "trip_summary_capacity")

  defp clear(socket, error), do: assign(socket, asset: nil, summary: nil, error: error)
end
