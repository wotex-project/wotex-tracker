defmodule Wotex.Tracker.UI.AssetLive do
  @moduledoc "Explicit Thing provisioning, retained measurements and bounded public history."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         enrollment: nil,
         state: nil,
         history: nil,
         generation: nil,
         needs_materialization: false,
         operation: nil,
         outcome: nil,
         error: nil
       )}

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    case params["operation"] do
      nil ->
        {:noreply,
         redirect(socket, to: Presenter.path(:asset, id) <> "?operation=" <> Identifier.uuid())}

      operation ->
        if Identifier.operation?(operation) do
          {:noreply, socket |> assign(id: id, operation: operation) |> recover() |> load()}
        else
          {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
        end
    end
  end

  @impl true
  def handle_event(
        "provision",
        _,
        %{assigns: %{needs_materialization: true, outcome: nil, enrollment: enrollment}} = socket
      )
      when not is_nil(enrollment) do
    result =
      Auth.request(socket, :materialize, %{
        "operation" => socket.assigns.operation,
        "request" => %{
          "thing_id" => socket.assigns.id,
          "expected_generation" => socket.assigns.generation
        }
      })

    {:noreply, socket |> outcome(result) |> load()}
  end

  def handle_event("check-operation", _, socket), do: {:noreply, socket |> recover() |> load()}
  def handle_event("refresh", _, socket), do: {:noreply, socket |> recover() |> load()}

  def handle_event("next-history", _, %{assigns: %{history: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor),
      do: {:noreply, history(socket, %{"cursor" => cursor})}

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a href="/">← All assets</a>
      <p class="eyebrow">Asset details</p>
      <div class="heading">
        <h1>{if @enrollment, do: @enrollment["title"], else: "Asset unavailable"}</h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <.notice error={@error} />
      <section :if={@enrollment} class="panel">
        <h2>Identity and provisioning</h2>
        <p class="identifier">{@id}</p>
        <p>Ownership confirmed · {@enrollment["identity_strategy"]}</p>
        <a href={Presenter.path(:observation, @enrollment["observation_id"])}>Inspect source evidence</a>
        <a :if={@identity["can_enroll"]} href={Presenter.path(:asset, @id) <> "/observations"}>
          Associate a later observation
        </a>
        <p :if={!@state}>
          This asset is enrolled. Provision its Thing to expose supported measurements through the service.
        </p>
        <p :if={@state && @needs_materialization} class="notice">
          These are prior retained measurements. Update the Thing to publish the newly associated observation.
        </p>
        <button
          :if={@needs_materialization && is_nil(@outcome) && @identity["can_enroll"]}
          phx-click="provision"
          phx-disable-with="Provisioning…"
        >{if @state, do: "Update Thing", else: "Provision Thing"}</button>
        <a :if={@needs_materialization && @outcome} href={Presenter.path(:asset, @id)}>
          Start another Thing update
        </a>
        <p :if={@state && !@needs_materialization}>
          Provisioned. The service exposes the measurements supplied by this profile.
        </p>
      </section>
      <.measurements :if={@state} state={@state} />
      <a :if={@state} class="button" href={Presenter.path(:asset, @id) <> "/analytics"}>
        Explore measurement history
      </a>
      <section :if={@state} class="panel">
        <h2>Tracking capabilities</h2>
        <p>
          This environmental-sensor profile does not supply position, motion, armed state or physical Actions. Battery voltage is a reading, not a battery percentage.
        </p>
      </section>
      <section :if={@history} class="panel" aria-labelledby="history-title">
        <h2 id="history-title">Measurement history</h2>
        <p>Retained snapshots in commit order. Missing intervals are not interpolated.</p>
        <div class="table-scroll" tabindex="0" role="region" aria-labelledby="history-title">
          <table>
            <caption>Retained measurement versions</caption>
            <thead>
              <tr>
                <th scope="col">Version</th><th scope="col">Observed (UTC)</th><th scope="col">
                  Measurements
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @history["items"]}>
                <td>{row["generation"]}</td>
                <td>
                  {if row["value"],
                    do: Presenter.timestamp(row["value"]["observed_at"]),
                    else: "Deleted"}
                </td>
                <td>
                  <ul :if={row["value"]}>
                    <li :for={value <- row["value"]["measurements"]}>
                      {Presenter.label(value["kind"])}: {Presenter.scalar(value["value"])} {Presenter.unit(
                        value["unit"]
                      )} · {value[
                        "quality"
                      ]}
                    </li>
                  </ul>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <button :if={@history["cursor"]} class="secondary" phx-click="next-history">Next history page</button>
      </section>
      <div :if={@operation} class="operation">
        <p :if={@outcome} role="status">
          Provisioning outcome: {@outcome["outcome"]}. This describes the service commit, not a physical device change.
        </p>
        <p>Operation reference <code>{@operation}</code></p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
      </div>
    </main>
    """
  end

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> outcome(socket, result)
    end
  end

  defp outcome(
         socket,
         {:ok,
          %{"outcome" => "committed", "data" => %{"thing_id" => id, "materialisation_id" => _}} =
            result}
       )
       when id == socket.assigns.id,
       do: assign(socket, outcome: result, error: nil)

  defp outcome(socket, {:ok, %{"outcome" => "unknown"} = result}),
    do: assign(socket, outcome: result, error: nil)

  defp outcome(socket, {:ok, _}),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        error: %{"code" => "operation_mismatch"}
      )

  defp outcome(socket, {:error, error}), do: assign(socket, error: error)

  defp load(socket) do
    with {:ok, enrollment} <-
           Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}),
         {:ok, page} <-
           Auth.request(socket, :list, %{"resource" => "enrollments", "params" => %{"limit" => 1}}),
         {:ok, state} <- state(socket) do
      needs_materialization =
        is_nil(state) or
          state["value"]["observation_id"] != enrollment["value"]["observation_id"]

      socket
      |> assign(
        enrollment: enrollment["value"],
        state: if(state, do: state["value"], else: nil),
        generation: page["generation"],
        needs_materialization: needs_materialization
      )
      |> history(%{})
    else
      {:error, error} -> assign(socket, error: error)
    end
  end

  defp state(socket) do
    case Auth.request(socket, :get, %{"resource" => "state", "id" => socket.assigns.id}) do
      {:ok, row} -> {:ok, row}
      {:error, %{"code" => "not_found"}} -> {:ok, nil}
      error -> error
    end
  end

  defp history(%{assigns: %{state: nil}} = socket, _), do: socket

  defp history(socket, params) do
    case Auth.request(socket, :history, %{
           "resource" => "state",
           "id" => socket.assigns.id,
           "params" => params
         }) do
      {:ok, history} -> assign(socket, history: history)
      {:error, error} -> assign(socket, error: error)
    end
  end
end
