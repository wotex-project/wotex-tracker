defmodule Wotex.Tracker.UI.Components do
  @moduledoc "Shared accessible presentation components."
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
end
