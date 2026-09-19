defmodule Wotex.Tracker.UI.ArmingLive do
  @moduledoc """
  Presents and conditionally changes one asset's committed arming fact.

  The page offers controls only when the asset has a motion rule and the current
  credential can administer the scope. A prepared change has a stable operation
  reference in the URL, requires explicit confirmation and never describes the
  service commit as device contact or successful notification delivery.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @public_fields ~w(schema thing_id status revision changed_at changed_by)
  @statuses ~w(armed disarmed)

  @impl true
  def mount(_, _, socket) do
    {:ok,
     assign(socket,
       id: nil,
       asset: nil,
       thing: nil,
       definitions: nil,
       arming: nil,
       generation: nil,
       operation: nil,
       target: nil,
       outcome: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket = if socket.assigns.id == id, do: socket, else: reset(socket, id)

    {:noreply,
     socket
     |> load()
     |> activate(params["operation"], params["status"])
     |> recover()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}

  def handle_event(
        "prepare",
        %{"status" => status},
        %{
          assigns: %{
            operation: nil,
            thing: %{},
            definitions: definitions,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when status in @statuses and is_list(definitions) do
    if motion?(definitions) do
      case current_generation(socket) do
        {:ok, generation} ->
          path =
            Presenter.arming_path(socket.assigns.id) <>
              "?operation=#{Identifier.uuid()}&status=#{status}"

          {:noreply, socket |> assign(generation: generation, error: nil) |> push_patch(to: path)}

        {:error, error} ->
          {:noreply, assign(socket, error: error)}
      end
    else
      {:noreply, assign(socket, error: %{"code" => "unsupported"})}
    end
  end

  def handle_event("prepare", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event(
        "commit",
        %{"arming" => %{"confirmed" => "yes"}},
        %{
          assigns: %{
            operation: operation,
            target: target,
            generation: generation,
            outcome: nil,
            thing: %{},
            definitions: definitions,
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(operation) and target in @statuses and is_binary(generation) and
             is_list(definitions) do
    if motion?(definitions) do
      result =
        Auth.request(socket, :set_arming, %{
          "operation" => operation,
          "request" => %{
            "thing_id" => socket.assigns.id,
            "status" => target,
            "expected_generation" => generation
          }
        })

      {:noreply, result(socket, result)}
    else
      {:noreply, assign(socket, error: %{"code" => "unsupported"})}
    end
  end

  def handle_event("commit", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("check-operation", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href={Presenter.path(:asset, @id) <> "/protection"}>← Protection rules</a>
      <p class="eyebrow">Protection</p>
      <div class="heading">
        <h1>{if @asset, do: "Arming #{@asset["title"]}", else: "Arming unavailable"}</h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <p>
        Arming is an explicit state committed by this service. It does not contact the tracker,
        prove current connectivity, trigger a physical Action or confirm notification delivery.
      </p>
      <.notice error={@error} />
      <section :if={@thing} class="panel" aria-labelledby="arming-status-title">
        <h2 id="arming-status-title">Committed state</h2>
        <p class="reading">{arming_label(@arming)}</p>
        <p :if={@arming}>
          Changed {Presenter.timestamp(%{"value" => @arming["changed_at"]})} · revision {@arming[
            "revision"
          ]}
        </p>
        <p :if={is_nil(@arming)}>
          No arming decision has been committed. Unknown is not treated as disarmed.
        </p>
      </section>
      <section :if={@thing && !motion?(@definitions)} class="panel">
        <h2>Motion rule required</h2>
        <p>
          This asset has no motion/trip definition, so this browser does not offer an arming
          control. Add and review a motion rule first.
        </p>
      </section>
      <section
        :if={@thing && motion?(@definitions)}
        class="panel"
        aria-labelledby="arming-control-title"
      >
        <h2 id="arming-control-title">Change arming state</h2>
        <p :if={!@identity["can_manage_queries"]}>
          Your credential can inspect this state but cannot arm or disarm the asset.
        </p>
        <div :if={@identity["can_manage_queries"] && is_nil(@operation)}>
          <button phx-click="prepare" phx-value-status="armed">Prepare arm</button>
          <button class="secondary" phx-click="prepare" phx-value-status="disarmed">
            Prepare disarm
          </button>
        </div>
        <.form
          :if={@identity["can_manage_queries"] && @operation && @target && is_nil(@outcome)}
          for={%{}}
          id="arming-confirmation"
          phx-submit="commit"
        >
          <p>
            Commit <strong>{arming_label(%{"status" => @target})}</strong> at the current service
            generation. Suspicious-movement evaluation and notification delivery are separate work.
          </p>
          <label>
            <input type="checkbox" name="arming[confirmed]" value="yes" required />
            I understand this records service state and does not prove a device change.
          </label>
          <button type="submit" phx-disable-with="Committing…">Confirm {verb(@target)}</button>
        </.form>
      </section>
      <section :if={@operation} class="operation">
        <p :if={@outcome} role="status">{outcome_label(@outcome, @target)}</p>
        <p :if={@outcome && @outcome["outcome"] != "committed"}>
          Keep this page address and check the operation before starting another change.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
        <a :if={@outcome && @outcome["outcome"] == "committed"} href={Presenter.arming_path(@id)}>
          Start another arming change
        </a>
      </section>
    </main>
    """
  end

  defp load(socket) do
    with {:ok, %{"value" => asset}} <-
           Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}),
         {:ok, %{"value" => thing}} <-
           Auth.request(socket, :get, %{"resource" => "things", "id" => socket.assigns.id}),
         {:ok, %{"items" => definitions}} <-
           Auth.request(socket, :thing_policies, %{"thing" => socket.assigns.id}),
         true <- is_list(definitions) do
      socket
      |> assign(
        asset: asset,
        thing: thing,
        definitions: Enum.map(definitions, & &1["value"]),
        error: nil
      )
      |> load_arming()
    else
      {:error, error} ->
        assign(socket, asset: nil, thing: nil, definitions: nil, error: error)

      _ ->
        assign(socket,
          asset: nil,
          thing: nil,
          definitions: nil,
          error: %{"code" => "unavailable"}
        )
    end
  end

  # A transient read failure keeps a previously validated public state visible.
  defp load_arming(socket) do
    case Auth.request(socket, :arming, %{"id" => socket.assigns.id}) do
      {:ok, %{"value" => value}} ->
        if arming?(value, socket.assigns.id),
          do: assign(socket, arming: value, error: nil),
          else: assign(socket, arming: nil, error: %{"code" => "unavailable"})

      {:error, %{"code" => "not_found"}} ->
        assign(socket, arming: nil, error: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        assign(socket, arming: nil, error: error)

      {:error, error} ->
        assign(socket, error: error)

      _ ->
        assign(socket, arming: nil, error: %{"code" => "unavailable"})
    end
  end

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{"resource" => "arming", "params" => %{"limit" => 1}}) do
      {:ok, %{"generation" => generation}} when is_binary(generation) -> {:ok, generation}
      {:error, error} -> {:error, error}
      _ -> {:error, %{"code" => "unavailable"}}
    end
  end

  defp activate(socket, nil, nil), do: assign(socket, operation: nil, target: nil, outcome: nil)

  defp activate(socket, operation, target) do
    cond do
      not Identifier.operation?(operation) or target not in @statuses ->
        assign(socket,
          operation: nil,
          target: nil,
          outcome: nil,
          error: %{"code" => "invalid_request"}
        )

      socket.assigns.operation == operation and socket.assigns.target == target ->
        socket

      true ->
        assign(socket, operation: operation, target: target, outcome: nil)
        |> ensure_generation()
    end
  end

  defp ensure_generation(%{assigns: %{generation: generation}} = socket)
       when is_binary(generation),
       do: socket

  defp ensure_generation(socket) do
    case current_generation(socket) do
      {:ok, generation} -> assign(socket, generation: generation)
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
    if data == %{"thing_id" => socket.assigns.id, "status" => socket.assigns.target},
      do: verify(socket, receipt),
      else: unrelated(socket)
  end

  defp result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, outcome: receipt, error: nil)

  defp result(socket, {:ok, _}), do: unrelated(socket)

  defp result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error)

  defp result(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  defp verify(socket, receipt) do
    case Auth.request(socket, :arming, %{"id" => socket.assigns.id}) do
      {:ok, %{"value" => %{"status" => status} = value}} when status == socket.assigns.target ->
        if arming?(value, socket.assigns.id),
          do: assign(socket, arming: value, outcome: receipt, error: nil),
          else: unrelated(socket)

      {:error, error} ->
        assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

      _ ->
        unrelated(socket)
    end
  end

  defp unrelated(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        error: %{"code" => "operation_mismatch"}
      )

  defp reset(socket, id),
    do:
      assign(socket,
        id: id,
        asset: nil,
        thing: nil,
        definitions: nil,
        arming: nil,
        generation: nil,
        operation: nil,
        target: nil,
        outcome: nil,
        error: nil
      )

  defp arming?(value, id) do
    exact_arming_shape?(value) and arming_identity?(value, id) and
      arming_change_time?(value) and arming_actor?(value)
  end

  defp exact_arming_shape?(value),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(@public_fields)

  defp arming_identity?(value, id),
    do:
      value["schema"] == "wtr.arming.v1" and value["thing_id"] == id and
        value["status"] in @statuses and arming_revision?(value["revision"])

  defp arming_change_time?(value),
    do:
      is_integer(value["changed_at"]) and
        value["changed_at"] in 0..9_007_199_254_740_991

  defp arming_actor?(value),
    do:
      is_binary(value["changed_by"]) and
        Regex.match?(~r/\Awtr1_[A-Za-z0-9_-]+\z/, value["changed_by"])

  defp arming_revision?("arming-" <> generation) when byte_size(generation) in 1..19 do
    case Integer.parse(generation) do
      {value, ""} when value > 0 and value < 9_223_372_036_854_775_807 ->
        Integer.to_string(value) == generation

      _ ->
        false
    end
  end

  defp arming_revision?(_), do: false

  defp motion?(definitions) when is_list(definitions),
    do: Enum.any?(definitions, &match?(%{"kind" => "motion"}, &1))

  defp motion?(_), do: false

  defp arming_label(%{"status" => "armed"}), do: "Armed"
  defp arming_label(%{"status" => "disarmed"}), do: "Disarmed"
  defp arming_label(_), do: "Unknown"
  defp verb("armed"), do: "arming"
  defp verb("disarmed"), do: "disarming"

  defp outcome_label(%{"outcome" => "committed"}, target),
    do: "Service state committed: " <> arming_label(%{"status" => target})

  defp outcome_label(_, _), do: "Arming outcome unknown"
end
