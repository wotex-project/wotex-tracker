defmodule Wotex.Tracker.UI.AssetLive do
  @moduledoc """
  Shows one authorized asset's committed state, evidence, and history.

  The screen distinguishes an unprovisioned asset from unavailable or retained
  measurements and retained position claims. It reads declared scalar Properties from the service snapshot;
  that read does not contact the device or establish current connectivity.
  Provisioning uses a stable operation reference and generation check. History
  navigation reloads bounded pages under current authority.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, HistoryExport, Presenter}

  @history_back_limit 32

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         enrollment: nil,
         state: nil,
         thing: nil,
         property_result: nil,
         property_error: nil,
         history: nil,
         history_params: nil,
         history_back: [],
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
          {:noreply, socket |> activate(id, operation) |> recover() |> load()}
        else
          {:noreply, socket |> activate(id, nil) |> assign(error: %{"code" => "invalid_request"})}
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

  def handle_event("check-operation", _, socket),
    do: {:noreply, socket |> assign(error: nil) |> recover() |> load()}

  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> assign(error: nil) |> recover() |> load()}

  def handle_event("read-property", %{"name" => name}, socket) when is_binary(name) do
    properties = if socket.assigns.thing, do: socket.assigns.thing["properties"], else: nil

    if is_map(properties) and Map.has_key?(properties, name) do
      case Auth.request(socket, :read_property, %{"thing" => socket.assigns.id, "name" => name}) do
        {:ok, result} ->
          {:noreply,
           assign(socket, property_result: Map.put(result, "name", name), property_error: nil)}

        {:error, error} ->
          {:noreply, assign(socket, property_result: nil, property_error: error)}
      end
    else
      {:noreply,
       assign(socket, property_result: nil, property_error: %{"code" => "invalid_request"})}
    end
  end

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

  def handle_event(
        "export-history",
        _,
        %{assigns: %{history: %{} = shown, history_params: params}} = socket
      )
      when is_map(params) do
    case Auth.request(socket, :history, %{
           "resource" => "state",
           "id" => socket.assigns.id,
           "params" => params
         }) do
      {:ok, current} ->
        if same_history_page?(shown, current) do
          {:noreply, HistoryExport.push(socket, socket.assigns.id, shown)}
        else
          {:noreply,
           assign(socket,
             history: nil,
             history_params: nil,
             history_back: [],
             error: %{"code" => "conflict"}
           )}
        end

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        {:noreply, clear_detail(socket, error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("export-history", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("export-all-history", _, %{assigns: %{history: %{}}} = socket) do
    fetch = fn params ->
      Auth.request(socket, :history, %{
        "resource" => "state",
        "id" => socket.assigns.id,
        "params" => params
      })
    end

    case HistoryExport.collect(socket.assigns.id, fetch) do
      {:ok, document} ->
        {:noreply, HistoryExport.push_complete(socket, document)}

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        {:noreply, clear_detail(socket, error)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("export-all-history", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

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
      <.positions :if={@state} state={@state} />
      <section :if={@thing && map_size(@thing["properties"]) > 0} class="panel">
        <h2>Read a Property</h2>
        <p>
          Read a declared Property at the service's current committed snapshot. This does not contact the physical device.
        </p>
        <div class="property-controls">
          <button
            :for={name <- @thing["properties"] |> Map.keys() |> Enum.sort()}
            class="secondary"
            phx-click="read-property"
            phx-value-name={name}
          >Read {Presenter.label(name)}</button>
        </div>
        <.notice error={@property_error} />
        <p :if={@property_result} role="status">
          {Presenter.label(@property_result["name"])}: {Presenter.scalar(%{
            "value" => @property_result["value"]
          })}
          {Presenter.unit(@thing["properties"][@property_result["name"]]["unit"])} · committed generation {@property_result[
            "generation"
          ]}
        </p>
      </section>
      <a :if={@state} class="button" href={Presenter.path(:asset, @id) <> "/analytics"}>
        Explore measurement history
      </a>
      <a :if={@state} class="button secondary" href={Presenter.path(:asset, @id) <> "/route"}>
        Explore route history
      </a>
      <a :if={@thing} href={Presenter.path(:asset, @id) <> "/protection"}>
        Protection rules
      </a>
      <a
        :if={@enrollment && @identity["can_manage_queries"]}
        class="secondary"
        href={Presenter.path(:asset, @id) <> "/remove"}
      >
        Remove asset
      </a>
      <section :if={@state} class="panel">
        <h2>Tracking capabilities</h2>
        <p :if={Map.get(@state, "positions", []) == []}>
          This environmental-sensor profile does not supply position, motion, armed state or physical Actions. Battery voltage is a reading, not a battery percentage. Heartbeat and low-battery-voltage rules can use its committed captures.
        </p>
        <p :if={Map.get(@state, "positions", []) != []}>
          This profile supplied retained position evidence. The screen has not selected a canonical source, inferred movement, contacted the device or dispatched a physical Action.
        </p>
      </section>
      <section :if={@history} class="panel" aria-labelledby="history-title">
        <h2 id="history-title">Measurement history</h2>
        <p>Retained snapshots in commit order. Missing intervals are not interpolated.</p>
        <p>
          Page export includes only the rows shown. Retained-history export traverses one committed
          snapshot under fresh authorization for every page. It fails without a file if history exceeds
          1,000 rows or 1 MB.
        </p>
        <div class="table-scroll" tabindex="0" role="region" aria-labelledby="history-title">
          <table>
            <caption>Retained measurement and position versions</caption>
            <thead>
              <tr>
                <th scope="col">Version</th><th scope="col">Observed (UTC)</th><th scope="col">
                  Measurements
                </th><th scope="col">
                  Positions
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
                <td>
                  <ul :if={row["value"]}>
                    <li :for={position <- Map.get(row["value"], "positions", [])}>
                      {Presenter.position_summary(position)}
                    </li>
                  </ul>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <button class="secondary" phx-click="export-history">Export this history page (JSON)</button>
        <button class="secondary" phx-click="export-all-history">Export retained history (JSON)</button>
        <button :if={@history_back != []} class="secondary" phx-click="previous-history">Previous history page</button>
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

  defp activate(socket, id, operation) do
    if socket.assigns[:id] == id and socket.assigns.operation == operation do
      socket
    else
      assign(socket,
        id: id,
        operation: operation,
        enrollment: nil,
        state: nil,
        thing: nil,
        property_result: nil,
        property_error: nil,
        history: nil,
        history_params: nil,
        history_back: [],
        generation: nil,
        needs_materialization: false,
        outcome: nil,
        error: nil
      )
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
        needs_materialization: needs_materialization,
        property_result: nil,
        property_error: nil
      )
      |> assign(history_back: [])
      |> history(%{})
      |> load_thing()
    else
      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear_detail(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp state(socket) do
    case Auth.request(socket, :get, %{"resource" => "state", "id" => socket.assigns.id}) do
      {:ok, row} -> {:ok, row}
      {:error, %{"code" => "not_found"}} -> {:ok, nil}
      error -> error
    end
  end

  defp load_thing(%{assigns: %{state: nil}} = socket), do: assign(socket, thing: nil)

  defp load_thing(socket) do
    case Auth.request(socket, :get, %{"resource" => "things", "id" => socket.assigns.id}) do
      {:ok, %{"value" => thing}} ->
        assign(socket, thing: thing)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear_detail(socket, error)

      {:error, error} ->
        assign(socket, thing: nil, property_error: error)
    end
  end

  defp history(%{assigns: %{state: nil}} = socket, _),
    do: assign(socket, history: nil, history_params: nil, history_back: [])

  defp history(socket, params) do
    case Auth.request(socket, :history, %{
           "resource" => "state",
           "id" => socket.assigns.id,
           "params" => params
         }) do
      {:ok, history} ->
        assign(socket, history: history, history_params: params, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        clear_detail(socket, error)

      {:error, error} ->
        assign(socket, error: error)
    end
  end

  defp same_history_page?(shown, current) do
    Map.take(shown, ~w(items generation)) == Map.take(current, ~w(items generation)) and
      is_binary(shown["cursor"]) == is_binary(current["cursor"])
  end

  defp clear_detail(socket, error) do
    assign(socket,
      enrollment: nil,
      state: nil,
      thing: nil,
      property_result: nil,
      property_error: nil,
      history: nil,
      history_params: nil,
      history_back: [],
      generation: nil,
      needs_materialization: false,
      outcome: nil,
      error: error
    )
  end
end
