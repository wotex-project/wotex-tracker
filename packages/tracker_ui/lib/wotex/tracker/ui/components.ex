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
