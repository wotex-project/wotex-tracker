defmodule Wotex.Tracker.UI.DashboardCompareLive do
  @moduledoc """
  Creates a multi-series saved query from compatible existing definitions.

  The screen checks that two to eight selected definitions use the same
  measurement, unit, window, and query settings with distinct series. The
  service makes the generation-checked save under an administrator grant.
  A stable operation reference lets reconnect inspect an uncertain outcome
  without silently submitting a second definition.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components
  alias Wotex.Tracker.QuerySpec
  alias Wotex.Tracker.Service.Identifier
  alias Wotex.Tracker.UI.{Auth, Presenter}

  @impl true
  def mount(_, _, socket),
    do: {:ok, assign(socket, page: nil, operation: nil, outcome: nil, error: nil)}

  @impl true
  def handle_params(%{"operation" => operation}, _, socket) do
    if Identifier.operation?(operation) do
      {:noreply, socket |> activate(operation) |> load(%{}) |> recover()}
    else
      {:noreply,
       assign(socket,
         operation: nil,
         outcome: nil,
         page: nil,
         error: %{"code" => "invalid_request"}
       )}
    end
  end

  def handle_params(_, _, socket),
    do: {:noreply, redirect(socket, to: "/dashboards/compare?operation=" <> Identifier.uuid())}

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, socket |> load(%{}) |> recover()}

  def handle_event("next", _, %{assigns: %{page: %{"cursor" => cursor}}} = socket)
      when is_binary(cursor),
      do: {:noreply, load(socket, %{"limit" => 100, "cursor" => cursor})}

  def handle_event("save", %{"compose" => %{"title" => title, "query_ids" => ids}}, socket)
      when is_binary(title) and is_list(ids) do
    if can_save?(socket) do
      case save_request(socket, title, ids) do
        {:ok, request} ->
          result =
            Auth.request(socket, :save_query, %{
              "operation" => socket.assigns.operation,
              "request" => request
            })

          {:noreply, save_result(socket, result)}

        :error ->
          {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
      end
    else
      {:noreply, assign(socket, error: %{"code" => "forbidden"})}
    end
  end

  def handle_event("save", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("check", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace">
      <a href="/dashboards">← All dashboards</a>
      <p class="eyebrow">Saved analytics</p>
      <div class="heading">
        <div>
          <h1>Compare saved queries</h1>
          <p>
            Choose two or more definitions with the same measurement, unit, query settings and window. The new dashboard shows each distinct series in an exact table.
          </p>
        </div>
        <button class="secondary" phx-click="refresh">Refresh definitions</button>
      </div>
      <.notice error={@error} />
      <p :if={!@identity["can_manage_queries"]} class="notice">
        This credential can read dashboards but cannot save a comparison.
      </p>
      <section :if={@outcome} class="panel" role="status">
        <h2>
          {if @outcome["outcome"] == "committed", do: "Comparison saved", else: "Save outcome unknown"}
        </h2>
        <a
          :if={@outcome["outcome"] == "committed"}
          href={Presenter.dashboard_path(composed_id(@operation))}
        >Open comparison dashboard</a>
        <p :if={@outcome["outcome"] != "committed"}>
          Keep this page address and check the operation outcome before saving again.
        </p>
      </section>
      <section :if={@page && @identity["can_manage_queries"] && is_nil(@outcome)} class="panel">
        <h2>Choose definitions on this page</h2>
        <p>At most 100 definitions are shown per page. Select two to eight with distinct series.</p>
        <.form for={%{}} id="compare-dashboard" phx-submit="save">
          <label for="compare-title">New dashboard title</label>
          <input id="compare-title" name="compose[title]" type="text" required />
          <fieldset>
            <legend>Saved queries</legend>
            <label :for={row <- @page["items"]}>
              <input type="checkbox" name="compose[query_ids][]" value={row["id"]} />
              {row["value"]["title"]} · {Enum.join(row["value"]["query"]["series"], ", ")}
            </label>
          </fieldset>
          <button type="submit" phx-disable-with="Saving…">Save comparison</button>
        </.form>
        <button :if={@page["cursor"]} class="secondary" phx-click="next">Next page</button>
      </section>
      <p :if={@operation} class="identifier">Operation {@operation}</p>
      <button :if={@operation} class="secondary" phx-click="check">Check save outcome</button>
    </main>
    """
  end

  defp activate(socket, operation) do
    if socket.assigns.operation == operation,
      do: socket,
      else: assign(socket, operation: operation, outcome: nil, error: nil)
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> save_result(socket, result)
    end
  end

  defp save_result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}) do
    if data == %{"query_id" => composed_id(socket.assigns.operation), "action" => "saved"} do
      verify_saved(socket, receipt)
    else
      mismatch(socket)
    end
  end

  defp save_result(socket, {:ok, %{"outcome" => "unknown"} = receipt}),
    do: assign(socket, outcome: receipt, error: nil)

  defp save_result(socket, {:ok, _}), do: mismatch(socket)

  defp save_result(socket, {:error, %{"outcome" => "not_committed"} = error}),
    do: assign(socket, error: error)

  defp save_result(socket, {:error, error}),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  defp verify_saved(socket, receipt) do
    case Auth.request(socket, :get, %{
           "resource" => "saved_queries",
           "id" => composed_id(socket.assigns.operation)
         }) do
      {:ok, %{"value" => %{"query" => %{"series" => series}}}}
      when is_list(series) and length(series) >= 2 ->
        assign(socket, outcome: receipt, error: nil)

      {:error, error} ->
        assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

      _ ->
        mismatch(socket)
    end
  end

  defp mismatch(socket),
    do:
      assign(socket,
        outcome: %{"outcome" => "unrelated"},
        error: %{"code" => "operation_mismatch"}
      )

  defp load(socket, params) do
    if socket.assigns.identity["can_manage_queries"] do
      case Auth.request(socket, :list, %{
             "resource" => "saved_queries",
             "params" => Map.put_new(params, "limit", 100)
           }) do
        {:ok, page} -> assign(socket, page: page, error: nil)
        {:error, error} -> assign(socket, page: nil, error: error)
      end
    else
      assign(socket, page: nil)
    end
  end

  defp can_save?(socket) do
    socket.assigns.identity["can_manage_queries"] and is_binary(socket.assigns.operation) and
      is_nil(socket.assigns.outcome) and is_map(socket.assigns.page)
  end

  defp save_request(socket, title, ids) do
    with {:ok, rows} <- selected(socket.assigns.page["items"], ids),
         {:ok, query, window} <- combined(rows, socket.assigns.operation) do
      request = %{
        "id" => composed_id(socket.assigns.operation),
        "title" => title,
        "query" => query,
        "visualization" => %{"type" => "table", "show_legend" => true, "show_points" => true},
        "expected_generation" => socket.assigns.page["generation"]
      }

      {:ok, if(is_map(window), do: Map.put(request, "window", window), else: request)}
    else
      _ -> :error
    end
  end

  defp selected(items, ids) when length(ids) in 2..8 do
    by_id = Map.new(items, &{&1["id"], &1})
    rows = Enum.map(ids, &Map.get(by_id, &1))

    if Enum.uniq(ids) == ids and Enum.all?(rows, &is_map/1),
      do: {:ok, rows},
      else: :error
  end

  defp selected(_, _), do: :error

  defp combined([first | rest], operation) do
    query = first["value"]["query"]
    window = first["value"]["window"]
    comparable = Map.drop(query, ~w(id series identity))
    rows = [first | rest]
    series = Enum.flat_map(rows, & &1["value"]["query"]["series"])

    with true <-
           Enum.all?(rest, fn row ->
             row["value"]["window"] == window and
               Map.drop(row["value"]["query"], ~w(id series identity)) == comparable
           end),
         true <- length(series) in 2..8 and Enum.uniq(series) == series,
         {:ok, spec} <- QuerySpec.from_map(query),
         {:ok, combined} <-
           spec
           |> Map.from_struct()
           |> Map.delete(:identity)
           |> Map.put(:id, "browser-comparison-" <> operation)
           |> Map.put(:series, series)
           |> QuerySpec.new(),
         {:ok, document} <- QuerySpec.to_map(combined) do
      {:ok, document, window}
    else
      _ -> :error
    end
  end

  defp combined(_, _), do: :error
  defp composed_id(operation), do: "comparison-" <> operation
end
