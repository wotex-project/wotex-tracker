defmodule Wotex.Tracker.UI.AssetRemoveLive do
  @moduledoc """
  Lets an administrator remove one enrolled asset from current views.

  The page states the consequences before anything is prepared: the enrollment,
  Thing, current state and every rule definition bound to the asset are removed,
  their rules stop, and retained history, evidence, observations and alerts stay.
  Preparing a removal captures the current scope generation and puts a fresh
  operation reference in the page address. Submission requires explicit
  confirmation. A committed receipt counts only when it names this asset and the
  enrollment is no longer readable; an uncertain result can be checked through the
  retained reference without submitting again.
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
         asset: nil,
         definitions: nil,
         operation: nil,
         generation: nil,
         outcome: nil,
         removed: nil,
         closed: false,
         error: nil
       )}

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket =
      if socket.assigns.id == id,
        do: socket,
        else: assign(socket, id: id, generation: nil)

    {:noreply, socket |> load() |> activate(params["operation"]) |> recover()}
  end

  @impl true
  def handle_event(
        "prepare",
        _,
        %{
          assigns: %{
            asset: %{},
            operation: nil,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      ) do
    case Auth.request(socket, :list, %{"resource" => "enrollments", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} ->
        socket = assign(socket, generation: generation, error: nil)

        {:noreply,
         push_patch(socket,
           to:
             Presenter.path(:asset, socket.assigns.id) <>
               "/remove?operation=" <> Identifier.uuid()
         )}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("prepare", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event(
        "remove",
        %{"removal" => %{"confirmed" => "yes"}},
        %{
          assigns: %{
            asset: %{},
            operation: operation,
            generation: generation,
            outcome: nil,
            closed: false,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(operation) and is_binary(generation) do
    request = %{"thing_id" => socket.assigns.id, "expected_generation" => generation}
    result = Auth.request(socket, :unenroll, %{"operation" => operation, "request" => request})
    {:noreply, result(socket, result)}
  end

  def handle_event("remove", %{"removal" => %{"confirmed" => "yes"}}, socket),
    do:
      {:noreply,
       if(socket.assigns.outcome,
         do: socket,
         else: assign(socket, error: %{"code" => "forbidden"})
       )}

  def handle_event("remove", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("check-operation", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href={Presenter.path(:asset, @id)}>← Asset details</a>
      <p class="eyebrow">Privacy</p>
      <h1>
        {cond do
          @removed -> "Asset removed"
          @asset -> "Remove #{@asset["title"]}"
          true -> "Asset unavailable"
        end}
      </h1>
      <.notice error={@error} />
      <section :if={@asset} class="panel" aria-labelledby="removal-consequences-title">
        <h2 id="removal-consequences-title">What removal does</h2>
        <ul>
          <li>The asset, its Thing Description and its current state leave current views.</li>
          <li :if={is_list(@definitions)}>
            {length(@definitions)} rule {if length(@definitions) == 1,
              do: "definition is",
              else: "definitions are"} deleted and stop being evaluated.
          </li>
          <li :if={is_nil(@definitions)}>
            Every rule definition for this asset is deleted and stops being evaluated.
          </li>
          <li>Open Property observations for this asset close.</li>
          <li>
            Retained history, observations, private evidence, rule status and alerts stay. This is
            not data deletion.
          </li>
          <li>Removal cannot be undone. A capture can be enrolled again as a new asset.</li>
        </ul>
        <p :if={!@identity["can_manage_queries"]}>
          Your credential can inspect this asset but cannot remove it.
        </p>
        <button
          :if={@identity["can_manage_queries"] && is_nil(@operation)}
          class="secondary"
          phx-click="prepare"
        >Prepare removal</button>
        <.form
          :if={
            @identity["can_manage_queries"] && @operation && @generation && is_nil(@outcome) &&
              !@closed
          }
          for={%{}}
          id="remove-asset"
          phx-submit="remove"
        >
          <label>
            <input type="checkbox" name="removal[confirmed]" value="yes" />
            I understand that {@asset["title"]} and its rule definitions will be removed.
          </label>
          <button type="submit" phx-disable-with="Removing…">Remove asset</button>
        </.form>
      </section>
      <section :if={@operation} class="operation">
        <p :if={@outcome} role="status">
          {if @removed, do: "Asset removed", else: "Removal outcome unknown"}
        </p>
        <a :if={@removed} href="/">Return to assets</a>
        <p :if={@outcome && !@removed}>
          Keep this page's address and check the operation outcome before trying again.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
      </section>
    </main>
    """
  end

  defp load(socket) do
    case Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}) do
      {:ok, %{"value" => asset}} ->
        socket |> assign(asset: asset, error: nil) |> definitions()

      {:error, %{"code" => "not_found"}} ->
        assign(socket, asset: nil, definitions: nil)

      {:error, error} ->
        assign(socket, asset: nil, definitions: nil, error: error)
    end
  end

  defp definitions(socket) do
    case Auth.request(socket, :thing_policies, %{"thing" => socket.assigns.id}) do
      {:ok, %{"items" => items}} -> assign(socket, definitions: items)
      _ -> assign(socket, definitions: nil)
    end
  end

  defp activate(socket, nil),
    do: assign(socket, operation: nil, outcome: nil, removed: nil, closed: false)

  defp activate(socket, operation) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket, operation: nil, error: %{"code" => "invalid_request"})

      socket.assigns.operation == operation ->
        socket

      true ->
        socket
        |> assign(operation: operation, outcome: nil, removed: nil, closed: false)
        |> current_generation()
    end
  end

  # A reconnect without a prepared generation reads the current one before showing the form.
  defp current_generation(%{assigns: %{generation: generation}} = socket)
       when is_binary(generation),
       do: socket

  defp current_generation(%{assigns: %{asset: nil}} = socket), do: socket

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "enrollments", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} -> assign(socket, generation: generation)
      {:error, error} -> assign(socket, error: error)
    end
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> result(socket, result)
    end
  end

  defp result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    if match?(%{"thing_id" => id, "action" => "unenrolled"} when id == socket.assigns.id, data),
      do: verify(socket, receipt),
      else: unrelated(socket)
  end

  defp result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, outcome: receipt, error: nil)

  defp result(socket, {:ok, _}), do: unrelated(socket)

  defp result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error, closed: true)

  defp result(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  # Success requires reading that the enrollment is gone, not only the receipt.
  defp verify(socket, receipt) do
    case Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}) do
      {:error, %{"code" => "not_found"}} ->
        assign(socket, outcome: receipt, removed: receipt, asset: nil, error: nil)

      {:error, error} ->
        assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

      {:ok, _} ->
        unrelated(socket)
    end
  end

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        removed: nil,
        error: %{"code" => "operation_mismatch"}
      )
end
