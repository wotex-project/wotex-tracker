defmodule Wotex.Tracker.UI.AssociationLive do
  @moduledoc "Evidence-first reassociation of an existing asset with a stable operation URL."
  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       thing_id: nil,
       observation_id: nil,
       asset: nil,
       observation: nil,
       resolution: nil,
       generation: nil,
       operation: nil,
       outcome: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(
        %{"thing_id" => thing, "observation_id" => observation, "operation" => operation},
        _,
        socket
      ) do
    if Identifier.operation?(operation) do
      {:noreply, socket |> activate(thing, observation, operation) |> recover() |> load()}
    else
      {:noreply,
       assign(socket, operation: nil, outcome: nil, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_params(%{"thing_id" => thing, "observation_id" => observation}, _, socket) do
    {:noreply,
     redirect(socket,
       to: Presenter.association_path(thing, observation) <> "?operation=" <> Identifier.uuid()
     )}
  end

  @impl true
  def handle_event(
        "associate",
        %{"association" => params},
        %{
          assigns: %{
            asset: %{},
            observation: %{},
            outcome: nil,
            error: nil,
            operation: operation,
            identity: %{"can_enroll" => true}
          }
        } = socket
      )
      when is_binary(operation) do
    request = %{
      "thing_id" => socket.assigns.thing_id,
      "observation_id" => socket.assigns.observation_id,
      "owner_confirmed" => params["confirmed"] == "true",
      "expected_generation" => socket.assigns.generation
    }

    result =
      Auth.request(socket, :associate, %{
        "operation" => operation,
        "request" => request
      })

    {:noreply, socket |> outcome(result) |> load()}
  end

  def handle_event("associate", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event("check-operation", _, socket), do: {:noreply, socket |> recover() |> load()}
  def handle_event("refresh", _, socket), do: {:noreply, socket |> recover() |> load()}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a :if={@thing_id} href={Presenter.path(:asset, @thing_id) <> "/observations"}>
        ← Choose another observation
      </a>
      <p class="eyebrow">Setup · associate observation</p>
      <h1>{if @asset, do: "Update " <> @asset["title"], else: "Update asset"}</h1>
      <.notice error={@error} />
      <.observation_evidence
        :if={@observation && @resolution}
        id={@observation_id}
        observation={@observation}
        resolution={@resolution}
        explanation="A profile match does not prove ownership. Confirm that this evidence belongs to the same physical asset before changing its association."
      />
      <section :if={@asset && @observation} class="panel">
        <h2>Existing asset</h2>
        <p>{@asset["title"]} · <span class="identifier">{@thing_id}</span></p>
        <p>Current observation <span class="identifier">{@asset["observation_id"]}</span></p>
      </section>
      <section
        :if={
          @asset && @observation && @resolution && @resolution["status"] == "resolved" &&
            @identity["can_enroll"] && @operation && is_nil(@outcome) && is_nil(@error)
        }
        class="panel"
      >
        <h2>Confirm association</h2>
        <p>
          This changes the asset's source observation. Update its Thing afterward to publish the new retained measurements.
        </p>
        <.form for={%{}} id="associate" phx-submit="associate">
          <label class="checkbox" for="association-confirmed">
            <input
              id="association-confirmed"
              type="checkbox"
              name="association[confirmed]"
              value="true"
              required
            /> I confirm this observation belongs to the same physical asset.
          </label>
          <button type="submit" phx-disable-with="Associating…">Confirm association</button>
        </.form>
      </section>
      <p
        :if={@asset && @observation && @resolution && @resolution["status"] != "resolved"}
        class="notice"
      >
        This observation has no supported exact profile and cannot be associated.
      </p>
      <p :if={@asset && @observation && !@identity["can_enroll"]} class="notice">
        This credential can inspect evidence but cannot change an asset association.
      </p>
      <section :if={@outcome} class="panel" role="status">
        <h2>
          {if @outcome["outcome"] == "committed",
            do: "Association saved",
            else: "Association outcome unknown"}
        </h2>
        <a
          :if={
            @outcome["outcome"] == "committed" && @asset &&
              @asset["observation_id"] == @observation_id
          }
          class="button"
          href={Presenter.path(:asset, @thing_id)}
        >
          Update Thing
        </a>
        <p
          :if={
            @outcome["outcome"] == "committed" && @asset &&
              @asset["observation_id"] != @observation_id
          }
          class="notice"
        >
          This receipt records an earlier association. The asset now references another observation.
        </p>
        <a
          :if={
            @outcome["outcome"] == "committed" && @asset &&
              @asset["observation_id"] != @observation_id
          }
          href={Presenter.path(:asset, @thing_id)}
        >Review current asset</a>
        <p :if={@outcome["outcome"] != "committed"}>
          Keep this page's address and check the outcome before starting another association.
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

  defp activate(socket, thing, observation, operation) do
    if socket.assigns.thing_id == thing and socket.assigns.observation_id == observation and
         socket.assigns.operation == operation do
      socket
    else
      assign(socket,
        thing_id: thing,
        observation_id: observation,
        operation: operation,
        asset: nil,
        observation: nil,
        resolution: nil,
        generation: nil,
        outcome: nil,
        error: nil
      )
    end
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} ->
        if is_nil(socket.assigns.outcome), do: assign(socket, error: nil), else: socket

      result ->
        outcome(socket, result)
    end
  end

  defp outcome(
         socket,
         {:ok,
          %{
            "outcome" => "committed",
            "data" =>
              %{
                "thing_id" => thing,
                "observation_id" => observation,
                "association_id" => association_id
              } = data
          } = result}
       )
       when map_size(data) == 3 and thing == socket.assigns.thing_id and
              observation == socket.assigns.observation_id do
    if Identifier.operation?(association_id),
      do: assign(socket, outcome: result, error: nil),
      else: unrelated(socket)
  end

  defp outcome(socket, {:ok, %{"outcome" => "unknown"} = result}),
    do: assign(socket, outcome: result, error: nil)

  defp outcome(socket, {:ok, _}), do: unrelated(socket)

  defp outcome(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error)

  defp outcome(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        error: %{"code" => "operation_mismatch"}
      )

  defp load(socket) do
    with {:ok, asset} <-
           Auth.request(socket, :get, %{
             "resource" => "enrollments",
             "id" => socket.assigns.thing_id
           }),
         {:ok, observation} <-
           Auth.request(socket, :get, %{
             "resource" => "observations",
             "id" => socket.assigns.observation_id
           }),
         {:ok, resolution} <-
           Auth.request(socket, :get, %{
             "resource" => "resolutions",
             "id" => socket.assigns.observation_id
           }),
         {:ok, page} <-
           Auth.request(socket, :list, %{
             "resource" => "observations",
             "params" => %{"limit" => 1}
           }) do
      assign(socket,
        asset: asset["value"],
        observation: observation["value"],
        resolution: resolution["value"],
        generation: page["generation"]
      )
    else
      {:error, error} -> assign(socket, error: error)
    end
  end
end
