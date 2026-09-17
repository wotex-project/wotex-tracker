defmodule Wotex.Tracker.UI.AlertLive do
  @moduledoc """
  Shows one recorded rule alert and lets an administrator acknowledge it once.

  Preparing an acknowledgement captures the scope generation and keeps an
  operation reference in the page address, so a lost reply is resolved from the
  receipt instead of acknowledging again. Acknowledgement records review only: it
  changes no rule state, sends nothing and never requests a physical Action.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         id: nil,
         alert: nil,
         error: nil,
         operation: nil,
         generation: nil,
         outcome: nil,
         manage_error: nil
       )}

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    {:noreply,
     socket
     |> assign(id: id)
     |> load()
     |> activate(params["operation"])
     |> recover()
     |> load_generation()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event("prepare", _, socket) do
    if can_prepare?(socket.assigns) do
      case current_generation(socket) do
        {:ok, generation} ->
          {:noreply,
           socket
           |> assign(generation: generation, manage_error: nil)
           |> push_patch(
             to: Presenter.alert_path(socket.assigns.id) <> "?operation=" <> Identifier.uuid()
           )}

        {:error, error} ->
          {:noreply, assign(socket, manage_error: error)}
      end
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("acknowledge", _, socket) do
    if acknowledgeable?(socket.assigns) do
      result =
        Auth.request(socket, :acknowledge_alert, %{
          "operation" => socket.assigns.operation,
          "request" => %{
            "alert_id" => socket.assigns.id,
            "expected_generation" => socket.assigns.generation
          }
        })

      {:noreply, result(socket, result)}
    else
      {:noreply, assign(socket, manage_error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("check-operation", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href="/protection/alerts">← All alerts</a>
      <p class="eyebrow">
        {if @alert, do: Presenter.rule_kind(@alert["rule"]["kind"]), else: "Alert"}
      </p>
      <div class="heading">
        <h1>
          {if @alert, do: Presenter.alert_kind(@alert["event"]["kind"]), else: "Alert unavailable"}
        </h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@alert} class="panel" aria-labelledby="alert-title">
        <h2 id="alert-title">Recorded event</h2>
        <p class="reading">{Presenter.alert_state(@alert)}</p>
        <dl>
          <dt>Rule</dt>
          <dd>
            <a href={Presenter.rule_path(@alert["rule"]["kind"] <> ":" <> @alert["rule"]["id"])}>
              {@alert["rule"]["id"]}
            </a>
            · revision {@alert["event"]["rule_revision"] || "unknown"}
          </dd>
          <dt :if={@alert["event"]["from_status"]}>Status change</dt>
          <dd :if={@alert["event"]["from_status"]}>
            {Presenter.rule_status(@alert["event"]["from_status"])} to {Presenter.rule_status(
              @alert["event"]["to_status"]
            )}
          </dd>
          <dt :if={@alert["event"]["reason"]}>Reason</dt>
          <dd :if={@alert["event"]["reason"]}>{@alert["event"]["reason"]}</dd>
          <dt>Recorded</dt>
          <dd>{Presenter.timestamp(%{"value" => @alert["created_at"]})}</dd>
          <dt>Evaluation</dt>
          <dd>
            {if @alert["mode"] == "live",
              do: "Live evaluation",
              else: "Historical replay; no present-time review is needed"}
          </dd>
          <dt>Physical Actions</dt>
          <dd>{dispatch(@alert["physical_action_dispatch"])}</dd>
          <dt :if={@alert["acknowledgement"]}>Acknowledged by</dt>
          <dd :if={@alert["acknowledgement"]} class="identifier">
            {@alert["acknowledgement"]["by"]}
          </dd>
        </dl>
        <p>
          This alert is derived from retained evidence. Evidence identifiers stay private; inspect
          the asset's source evidence with the raw-evidence permission.
        </p>
        <p class="identifier">Event {@alert["event_id"]}</p>
      </section>
      <section :if={@alert && @identity["can_manage_queries"]} class="panel">
        <h2>Review</h2>
        <.notice error={@manage_error} />
        <button :if={can_prepare?(assigns)} phx-click="prepare">Prepare acknowledgement</button>
        <div :if={acknowledgeable?(assigns)}>
          <p>Acknowledging records that you reviewed this alert. It does not change the rule.</p>
          <button phx-click="acknowledge" phx-disable-with="Acknowledging…">Acknowledge alert</button>
        </div>
      </section>
      <section :if={@operation} class="operation">
        <p :if={@outcome} role="status">
          {if @outcome["outcome"] == "committed",
            do: "Alert acknowledged",
            else: "Acknowledgement outcome unknown"}
        </p>
        <p :if={@outcome && @outcome["outcome"] != "committed"}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
      </section>
    </main>
    """
  end

  defp dispatch("separate_authorization_required"),
    do: "None requested; any Action would need separate authorization"

  defp dispatch(_), do: "None can be dispatched from this record"

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "alerts", "id" => socket.assigns.id}) do
      {:ok, %{"value" => alert}} ->
        assign(socket, alert: alert, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        assign(socket, alert: nil, error: error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp can_prepare?(assigns),
    do:
      assigns.identity["can_manage_queries"] == true and is_nil(assigns.operation) and
        match?(%{"mode" => "live", "acknowledgement" => nil}, assigns.alert)

  defp acknowledgeable?(assigns),
    do:
      assigns.identity["can_manage_queries"] == true and is_binary(assigns.operation) and
        is_binary(assigns.generation) and is_nil(assigns.outcome) and
        match?(%{"mode" => "live", "acknowledgement" => nil}, assigns.alert)

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "alerts", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} -> {:ok, generation}
      {:error, error} -> {:error, error}
    end
  end

  defp activate(socket, nil), do: assign(socket, operation: nil, outcome: nil)

  defp activate(socket, operation) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, operation: nil, manage_error: %{"code" => "invalid_request"})

      socket.assigns.operation == operation ->
        socket

      true ->
        prepared? = is_nil(socket.assigns.operation) and is_binary(socket.assigns.generation)

        assign(socket,
          operation: operation,
          generation: if(prepared?, do: socket.assigns.generation, else: nil),
          outcome: nil
        )
    end
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> result(socket, result)
    end
  end

  # A reconnect without a prepared generation reads the current one before acknowledging.
  defp load_generation(
         %{assigns: %{operation: operation, generation: nil, outcome: nil}} = socket
       )
       when is_binary(operation) do
    case current_generation(socket) do
      {:ok, generation} -> assign(socket, generation: generation)
      {:error, error} -> assign(socket, manage_error: error)
    end
  end

  defp load_generation(socket), do: socket

  defp result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    if data == %{"alert_id" => socket.assigns.id, "action" => "acknowledged"} do
      reloaded = load(socket)

      case reloaded.assigns do
        %{alert: %{"acknowledgement" => %{}}} ->
          assign(reloaded, outcome: receipt, manage_error: nil)

        %{error: nil} ->
          unrelated(reloaded)

        %{error: error} ->
          assign(reloaded, outcome: %{"outcome" => "unknown"}, manage_error: error)
      end
    else
      unrelated(socket)
    end
  end

  defp result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, outcome: receipt, manage_error: nil)

  defp result(socket, {:ok, _}), do: unrelated(socket)

  defp result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, manage_error: error)

  defp result(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, manage_error: error)

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        manage_error: %{"code" => "operation_mismatch"}
      )
end
