defmodule Wotex.Tracker.UI.PresenceLive do
  @moduledoc """
  Reviews and admits one asset's complete owner-presence evidence fact.

  Readers receive only the service's closed public projection. Administrators
  prepare a stable operation reference before selecting one bounded JSON file,
  explicitly confirm its admission, and submit it once. The private document is
  revalidated and sent directly to the service without entering LiveView assigns.
  Lost replies are recovered from the durable operation receipt and an exact
  public-state read; no mutation is retried automatically.
  """

  use Phoenix.LiveView, log: false
  import Wotex.Tracker.UI.Components

  alias Wotex.Tracker.Service.{Codec, Identifier}
  alias Wotex.Tracker.UI.{Auth, PresenceEvidence, Presenter}

  @maximum_file_bytes 262_144

  @impl true
  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(
       id: nil,
       asset: nil,
       thing: nil,
       presence: nil,
       generation: nil,
       operation: nil,
       outcome: nil,
       error: nil
     )
     |> allow_upload(:fact,
       accept: ~w(.json),
       max_entries: 1,
       max_file_size: @maximum_file_bytes
     )}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _, socket) do
    socket = if socket.assigns.id == id, do: socket, else: reset(socket, id)
    {:noreply, socket |> load() |> activate(params["operation"]) |> recover()}
  end

  @impl true
  def handle_event("refresh", _, socket), do: {:noreply, load(socket)}
  def handle_event("validate-fact", _, socket), do: {:noreply, socket}

  def handle_event(
        "prepare",
        _,
        %{
          assigns: %{
            operation: nil,
            thing: %{},
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      ) do
    case current_generation(socket) do
      {:ok, generation} ->
        path = Presenter.presence_path(socket.assigns.id) <> "?operation=" <> Identifier.uuid()

        {:noreply,
         socket
         |> assign(generation: generation, error: nil)
         |> push_patch(to: path)}

      {:error, error} ->
        {:noreply, assign(socket, error: error)}
    end
  end

  def handle_event("prepare", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "forbidden"})}

  def handle_event(
        "admit",
        %{"presence" => %{"confirmed" => "yes"}},
        %{
          assigns: %{
            operation: operation,
            generation: generation,
            outcome: nil,
            thing: %{},
            identity: %{"can_manage_queries" => true}
          }
        } = socket
      )
      when is_binary(operation) and is_binary(generation) do
    case uploaded_fact(socket) do
      {:ok, admission} ->
        result =
          Auth.request(socket, :admit_owner_presence, %{
            "operation" => operation,
            "request" => %{
              "thing_id" => socket.assigns.id,
              "fact" => admission.document,
              "expected_generation" => generation
            }
          })

        {:noreply, result(socket, result, admission)}

      :error ->
        {:noreply, assign(socket, error: %{"code" => "invalid_request"})}
    end
  end

  def handle_event("admit", _, socket),
    do: {:noreply, assign(socket, error: %{"code" => "invalid_request"})}

  def handle_event("check-operation", _, socket), do: {:noreply, recover(socket)}
  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main id="main" class="workspace narrow">
      <a href={Presenter.path(:asset, @id) <> "/protection"}>← Protection rules</a>
      <p class="eyebrow">Protection evidence</p>
      <div class="heading">
        <h1>
          {if @asset, do: "Owner presence for #{@asset["title"]}", else: "Owner presence unavailable"}
        </h1>
        <button class="secondary" phx-click="refresh">Refresh</button>
      </div>
      <p>
        This page reviews qualified evidence already associated with the asset. It does not detect
        the owner, turn radio silence into absence, contact the tracker or prove a physical fact.
      </p>
      <.notice error={@error} />
      <section :if={@thing} class="panel" aria-labelledby="presence-status-title">
        <h2 id="presence-status-title">Reviewed state</h2>
        <p class="reading">{PresenceEvidence.label(@presence)}</p>
        <p :if={@presence}>
          Observed {Presenter.timestamp(%{"value" => @presence["observed_at"]})} · admitted {Presenter.timestamp(
            %{"value" => @presence["admitted_at"]}
          )} · revision {@presence["revision"]}
        </p>
        <p :if={is_nil(@presence)}>
          No reviewed owner-presence fact is available. Missing evidence remains unknown; it is
          not proof that the owner is absent.
        </p>
      </section>
      <section :if={@thing} class="panel" aria-labelledby="presence-admission-title">
        <h2 id="presence-admission-title">Admit reviewed evidence</h2>
        <p>
          The file must contain one complete <code>wtr.policy-fact-sample.v1</code>
          document for <code>owner.present</code>, backed by exact or strong identity evidence associated with
          this asset. The service revalidates every identity and requires a strictly newer receiver
          observation time. Admission records evidence; it does not independently establish that
          the source's physical claim is true.
        </p>
        <p :if={!@identity["can_manage_queries"]}>
          Your credential can inspect the reviewed state but cannot admit private evidence.
        </p>
        <button
          :if={@identity["can_manage_queries"] && is_nil(@operation)}
          phx-click="prepare"
        >Prepare evidence admission</button>
        <.form
          :if={@identity["can_manage_queries"] && @operation && @generation && is_nil(@outcome)}
          for={%{}}
          id="owner-presence-admission"
          phx-change="validate-fact"
          phx-submit="admit"
        >
          <label for={@uploads.fact.ref}>Complete owner-presence fact JSON</label>
          <.live_file_input upload={@uploads.fact} />
          <p :if={invalid_upload?(@uploads.fact)} class="notice" role="alert">
            Choose one JSON evidence document of 256 KiB or less.
          </p>
          <label>
            <input type="checkbox" name="presence[confirmed]" value="yes" required />
            I reviewed the evidence source and understand that admission is not a fresh physical
            detection.
          </label>
          <button type="submit" phx-disable-with="Admitting…">Admit evidence once</button>
        </.form>
      </section>
      <section :if={@operation} class="operation">
        <p :if={@outcome} role="status">{outcome_label(@outcome)}</p>
        <p :if={@outcome && @outcome["outcome"] != "committed"}>
          Keep this page address and check the operation before preparing another admission.
        </p>
        <p class="identifier">Operation {@operation}</p>
        <button class="secondary" phx-click="check-operation">Check operation outcome</button>
        <a
          :if={@outcome && @outcome["outcome"] == "committed"}
          href={Presenter.presence_path(@id)}
        >
          Start another evidence admission
        </a>
      </section>
    </main>
    """
  end

  defp load(socket) do
    with {:ok, %{"value" => asset}} <-
           Auth.request(socket, :get, %{"resource" => "enrollments", "id" => socket.assigns.id}),
         {:ok, %{"value" => thing}} <-
           Auth.request(socket, :get, %{"resource" => "things", "id" => socket.assigns.id}) do
      socket
      |> assign(asset: asset, thing: thing, error: nil)
      |> load_presence()
    else
      {:error, error} ->
        assign(socket, asset: nil, thing: nil, presence: nil, error: error)

      _ ->
        assign(socket,
          asset: nil,
          thing: nil,
          presence: nil,
          error: %{"code" => "unavailable"}
        )
    end
  end

  # A transient failure retains the last exact public projection. Authority loss clears it.
  defp load_presence(socket) do
    case Auth.request(socket, :owner_presence, %{"id" => socket.assigns.id}) do
      {:ok, %{"value" => value}} ->
        if PresenceEvidence.public?(value, socket.assigns.id),
          do: assign(socket, presence: value),
          else: assign(socket, presence: nil, error: %{"code" => "unavailable"})

      {:error, %{"code" => "not_found"}} ->
        assign(socket, presence: nil)

      {:error, %{"code" => code} = error} when code in ~w(forbidden unauthorized) ->
        assign(socket, presence: nil, error: error)

      {:error, error} ->
        assign(socket, error: error)

      _ ->
        assign(socket, presence: nil, error: %{"code" => "unavailable"})
    end
  end

  defp current_generation(socket) do
    case Auth.request(socket, :list, %{
           "resource" => "owner_presence",
           "params" => %{"limit" => 1}
         }) do
      {:ok, %{"generation" => generation}} when is_binary(generation) -> {:ok, generation}
      {:error, error} -> {:error, error}
      _ -> {:error, %{"code" => "unavailable"}}
    end
  end

  defp activate(socket, nil),
    do: assign(socket, operation: nil, generation: nil, outcome: nil)

  defp activate(socket, operation) do
    cond do
      not Identifier.operation?(operation) ->
        assign(socket,
          operation: nil,
          generation: nil,
          outcome: nil,
          error: %{"code" => "invalid_request"}
        )

      socket.assigns.operation == operation ->
        socket

      true ->
        socket
        |> assign(operation: operation, generation: nil, outcome: nil)
        |> ensure_generation()
    end
  end

  defp ensure_generation(socket) do
    case current_generation(socket) do
      {:ok, generation} -> assign(socket, generation: generation)
      {:error, error} -> assign(socket, error: error)
    end
  end

  defp uploaded_fact(socket) do
    with {[entry], []} <- uploaded_entries(socket, :fact),
         true <- entry.done?,
         false <- invalid_upload?(socket.assigns.uploads.fact),
         [{:ok, admission}] <-
           consume_uploaded_entries(socket, :fact, fn %{path: path}, _ ->
             {:ok, decode_fact(path, socket.assigns.id)}
           end) do
      {:ok, admission}
    else
      _ -> :error
    end
  end

  defp decode_fact(path, thing) do
    with {:ok, bytes} <- File.read(path),
         {:ok, document} <- Codec.decode(bytes),
         {:ok, admission} <- PresenceEvidence.admission(document, thing) do
      {:ok, admission}
    else
      _ -> :error
    end
  end

  defp invalid_upload?(upload) do
    upload_errors(upload) != [] or
      Enum.any?(upload.entries, &(upload_errors(upload, &1) != []))
  end

  defp recover(%{assigns: %{operation: nil}} = socket), do: socket

  defp recover(socket) do
    case Auth.request(socket, :operation, %{"id" => socket.assigns.operation}) do
      {:error, %{"code" => "not_found"}} -> socket
      result -> result(socket, result, nil)
    end
  end

  defp result(socket, {:ok, %{"outcome" => "committed", "data" => data} = receipt}, expected) do
    if receipt_data?(data, socket.assigns.id, expected),
      do: verify(socket, receipt, data),
      else: unrelated(socket)
  end

  defp result(socket, {:ok, %{"outcome" => "unknown"} = receipt}, _expected),
    do: assign(socket, outcome: receipt, error: nil)

  defp result(socket, {:ok, _}, _expected), do: unrelated(socket)

  defp result(socket, {:error, %{"outcome" => "not_committed"} = error}, _expected),
    do: assign(socket, error: error)

  defp result(socket, {:error, error}, _expected),
    do: assign(socket, outcome: %{"outcome" => "unknown"}, error: error)

  defp receipt_data?(data, thing, expected) do
    valid =
      is_map(data) and map_size(data) == 3 and data["thing_id"] == thing and
        data["status"] in ~w(present absent unknown) and timestamp?(data["observed_at"])

    valid and
      (is_nil(expected) or
         (data["status"] == expected.status and data["observed_at"] == expected.observed_at))
  end

  defp verify(socket, receipt, data) do
    case Auth.request(socket, :owner_presence, %{"id" => socket.assigns.id}) do
      {:ok, %{"value" => value}} ->
        if PresenceEvidence.public?(value, socket.assigns.id) and
             value["status"] == data["status"] and
             value["observed_at"] == data["observed_at"] do
          assign(socket, presence: value, outcome: receipt, error: nil)
        else
          unrelated(socket)
        end

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
        presence: nil,
        generation: nil,
        operation: nil,
        outcome: nil,
        error: nil
      )

  defp timestamp?(value), do: is_integer(value) and value in 0..9_007_199_254_740_991

  defp outcome_label(%{"outcome" => "committed"}),
    do: "Owner-presence evidence admitted and verified"

  defp outcome_label(_), do: "Evidence-admission outcome unknown"
end
