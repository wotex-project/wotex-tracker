defmodule Wotex.Tracker.UI.ObservationLive do
  @moduledoc "Evidence-first enrollment with a stable operation reference across reconnects."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter, RawExport}

  @impl true
  def mount(_, _, socket),
    do:
      {:ok,
       assign(socket,
         observation: nil,
         resolution: nil,
         generation: nil,
         operation: nil,
         outcome: nil,
         error: nil
       )}

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    case params["operation"] do
      nil ->
        {:noreply,
         redirect(socket,
           to: Presenter.path(:observation, id) <> "?operation=" <> Identifier.uuid()
         )}

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
        "enroll",
        %{"enrollment" => params},
        %{assigns: %{outcome: nil, observation: observation}} = socket
      )
      when not is_nil(observation) do
    request = %{
      "observation_id" => socket.assigns.id,
      "title" => params["title"],
      "owner_confirmed" => params["confirmed"] == "true",
      "expected_generation" => socket.assigns.generation
    }

    result =
      Auth.request(socket, :enroll, %{
        "operation" => socket.assigns.operation,
        "request" => request
      })

    {:noreply, outcome(socket, result)}
  end

  def handle_event("check-operation", _, socket),
    do: {:noreply, socket |> assign(error: nil) |> recover()}

  def handle_event("refresh", _, socket),
    do: {:noreply, socket |> assign(error: nil) |> recover() |> load()}

  def handle_event("export-raw", %{"kind" => kind}, %{assigns: %{observation: %{}}} = socket)
      when kind in ~w(observation evidence) do
    {action, export_kind} =
      if kind == "observation",
        do: {:raw_observation, :observation},
        else: {:raw_evidence, :evidence}

    case Auth.request(socket, action, %{"id" => socket.assigns.id}) do
      {:ok, content} when is_binary(content) ->
        case RawExport.push(socket, export_kind, content) do
          {:ok, socket} -> {:noreply, assign(socket, error: nil)}
          {:error, error} -> {:noreply, assign(socket, error: error)}
        end

      {:ok, _} ->
        {:noreply, assign(socket, error: %{"code" => "storage_unavailable"})}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href="/setup">← All observations</a>
      <p class="eyebrow">Setup · review evidence</p>
      <h1>Confirm this tracker</h1>
      <.notice error={@error} />
      <.observation_evidence
        :if={@observation && @resolution}
        id={@id}
        observation={@observation}
        resolution={@resolution}
        explanation="Enrollment creates a service identity. A profile match alone does not prove that you own the physical device."
      />
      <section :if={@observation && @identity["can_read_raw"]} class="panel">
        <h2>Private evidence export</h2>
        <p>
          These downloads can contain raw device identifiers and source claims. Keep them private.
          Each download checks the raw-evidence grant again.
        </p>
        <button class="secondary" phx-click="export-raw" phx-value-kind="observation">
          Export native observation (JSON)
        </button>
        <button class="secondary" phx-click="export-raw" phx-value-kind="evidence">
          Export raw evidence claims (JSON)
        </button>
      </section>
      <section :if={@observation && @identity["can_enroll"] && is_nil(@outcome)} class="panel">
        <h2>Enroll an asset</h2>
        <.form for={%{}} id="enroll" phx-submit="enroll">
          <label for="title">Asset name</label>
          <input
            id="title"
            name="enrollment[title]"
            required
            maxlength="128"
            placeholder="Workshop sensor"
          />
          <label class="checkbox" for="confirmed">
            <input id="confirmed" type="checkbox" name="enrollment[confirmed]" value="true" required />
            I own this device or have permission to enroll it.
          </label>
          <button type="submit" phx-disable-with="Checking enrollment…">Confirm enrollment</button>
        </.form>
      </section>
      <p :if={@observation && !@identity["can_enroll"]} class="notice">
        This credential can inspect evidence but cannot enroll an asset.
      </p>
      <section :if={@outcome} class="panel" role="status">
        <h2>
          {if @outcome["outcome"] == "committed",
            do: "Enrollment saved",
            else: "Enrollment outcome unknown"}
        </h2>
        <a
          :if={@outcome["outcome"] == "committed" && @outcome["data"]["thing_id"]}
          class="button"
          href={Presenter.path(:asset, @outcome["data"]["thing_id"])}
        >Continue provisioning</a>
        <p :if={@outcome["outcome"] != "committed"}>
          Keep this page's address. Check the outcome before starting another enrollment.
        </p>
      </section>
      <div :if={@operation} class="operation">
        <p>Operation reference <code>{@operation}</code></p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
        <button class="secondary" phx-click="refresh">Refresh evidence</button>
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
        observation: nil,
        resolution: nil,
        generation: nil,
        outcome: nil,
        error: nil
      )
    end
  end

  defp outcome(
         socket,
         {:ok, %{"outcome" => "committed", "data" => %{"thing_id" => id} = data} = result}
       )
       when map_size(data) == 1 do
    case Auth.request(socket, :get, %{"resource" => "enrollments", "id" => id}) do
      {:ok, %{"value" => %{"observation_id" => observation}}}
      when observation == socket.assigns.id ->
        assign(socket, outcome: result, error: nil)

      _ ->
        unrelated(socket)
    end
  end

  defp outcome(socket, {:ok, %{"outcome" => "unknown"} = result}),
    do: assign(socket, outcome: result, error: nil)

  defp outcome(socket, {:ok, _}), do: unrelated(socket)
  defp outcome(socket, {:error, error}), do: assign(socket, error: error)

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        error: %{"code" => "operation_mismatch"}
      )

  defp load(socket) do
    with {:ok, observation} <-
           Auth.request(socket, :get, %{"resource" => "observations", "id" => socket.assigns.id}),
         {:ok, resolution} <-
           Auth.request(socket, :get, %{"resource" => "resolutions", "id" => socket.assigns.id}),
         {:ok, page} <-
           Auth.request(socket, :list, %{
             "resource" => "observations",
             "params" => %{"limit" => 1}
           }) do
      assign(socket,
        observation: observation["value"],
        resolution: resolution["value"],
        generation: page["generation"]
      )
    else
      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized not_found) ->
        assign(socket,
          observation: nil,
          resolution: nil,
          generation: nil,
          outcome: nil,
          error: error
        )

      {:error, error} ->
        assign(socket, error: error)
    end
  end
end
