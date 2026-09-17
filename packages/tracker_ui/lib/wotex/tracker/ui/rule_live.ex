defmodule Wotex.Tracker.UI.RuleLive do
  @moduledoc """
  Shows one committed rule status and its retained evaluation history.

  The current status and every history page come from the authorized service
  `rules` projection. History navigation keeps a bounded path through earlier
  pages and reloads each under current authority. Terminal denial or a missing
  rule clears the page; a temporary failure keeps the displayed status for retry.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @history_back_limit 32

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         id: nil,
         rule: nil,
         history: nil,
         history_params: nil,
         history_back: [],
         error: nil
       )}

  @impl true
  def handle_params(%{"id" => id}, _, socket),
    do: {:noreply, socket |> assign(id: id) |> load()}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("next-history", _, %{assigns: %{history: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor) do
    next = history(socket, %{"cursor" => cursor})

    if next.assigns.history_params == %{"cursor" => cursor} do
      back = [socket.assigns.history_params | socket.assigns.history_back]
      {:noreply, assign(next, history_back: Enum.take(back, @history_back_limit))}
    else
      {:noreply, next}
    end
  end

  def handle_event("previous-history", _, %{assigns: %{history_back: [params | rest]}} = socket) do
    previous = history(socket, params)

    cond do
      previous.assigns.history_params != params ->
        {:noreply, previous}

      previous.assigns.history["generation"] != socket.assigns.history["generation"] ->
        {:noreply, assign(socket, error: %{"code" => "conflict"})}

      true ->
        {:noreply, assign(previous, history_back: rest)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a href="/protection">← All tracking rules</a>
      <p class="eyebrow">{if @rule, do: Presenter.rule_kind(@rule["kind"]), else: "Tracking rule"}</p>
      <div class="heading">
        <h1>{if @rule, do: @rule["rule"]["id"], else: "Rule status unavailable"}</h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@rule} class="panel" aria-labelledby="rule-status-title">
        <h2 id="rule-status-title">Current committed status</h2>
        <p class="reading">{Presenter.rule_status(@rule["status"])}</p>
        <p>
          The service evaluated this rule from retained evidence. The status does not prove current
          device connectivity, and this page does not change, arm or acknowledge the rule.
        </p>
        <.rule_details status={@rule} />
        <p class="identifier">Rule identity {@rule["rule"]["identity"]}</p>
        <p class="identifier">State identity {@rule["state_identity"]}</p>
      </section>
      <section :if={@history} class="panel" aria-labelledby="rule-history-title">
        <h2 id="rule-history-title">Evaluation history</h2>
        <p>Committed status versions in commit order. Unchanged evaluations are not recorded.</p>
        <div class="table-scroll" tabindex="0" role="region" aria-labelledby="rule-history-title">
          <table>
            <caption>Retained rule status versions</caption>
            <thead>
              <tr>
                <th scope="col">Version</th><th scope="col">Status</th><th scope="col">
                  Rule revision
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @history["items"]}>
                <td>{row["generation"]}</td>
                <td>{Presenter.rule_status(row["value"]["status"])}</td>
                <td>{row["value"]["rule"]["revision"]}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <button :if={@history_back != []} class="secondary" phx-click="previous-history">
          Previous history page
        </button>
        <button :if={@history["cursor"]} class="secondary" phx-click="next-history">
          Next history page
        </button>
      </section>
    </main>
    """
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "rules", "id" => socket.assigns.id}) do
      {:ok, %{"value" => rule}} ->
        socket
        |> assign(rule: rule, error: nil, history_back: [])
        |> history(%{})

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp history(socket, params) do
    case Auth.request(socket, :history, %{
           "resource" => "rules",
           "id" => socket.assigns.id,
           "params" => params
         }) do
      {:ok, history} ->
        assign(socket, history: history, history_params: params, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp clear(socket, error),
    do:
      assign(socket,
        rule: nil,
        history: nil,
        history_params: nil,
        history_back: [],
        error: error
      )
end
