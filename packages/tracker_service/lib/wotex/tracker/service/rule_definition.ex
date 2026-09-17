defmodule Wotex.Tracker.Service.RuleDefinition do
  @moduledoc false

  # Administrators bind a closed heartbeat or battery policy to one enrolled Thing.
  # The service assigns the policy revision from the definition's commit
  # generation and validates it through the pure constructor before storage.

  alias Wotex.Tracker.{BatteryTransition, HeartbeatTransition}
  alias Wotex.Tracker.Service.{Codec, Store, Update}

  @save_fields ~w(id kind thing_id parameters expected_generation)
  @delete_fields ~w(id expected_generation)
  @public_fields ~w(schema id kind thing_id revision policy_identity parameters created_at updated_at)
  @parameters %{
    "heartbeat" => ~w(maximum_silence_ms future_skew_ms),
    "battery" =>
      ~w(measurement_kind unit low_threshold clear_threshold maximum_age_ms future_skew_ms accept_suspect)
  }
  @maximum_per_thing 8

  def admit_save(request) do
    with true <- exact?(request, @save_fields),
         true <- rule_id?(request["id"]),
         "urn:uuid:" <> _ <- request["thing_id"],
         true <- Codec.id?(request["thing_id"]),
         {:ok, generation} <- Codec.generation(request["expected_generation"]),
         {:ok, _policy} <-
           policy(request["kind"], request["id"], revision(generation), request["parameters"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def admit_delete(request) do
    with true <- exact?(request, @delete_fields),
         true <- rule_id?(request["id"]),
         {:ok, _} <- Codec.generation(request["expected_generation"]) do
      :ok
    else
      _ -> {:error, :invalid_request}
    end
  end

  def prepare_save(service, access, operation, request, now) do
    {:ok, generation} = Codec.generation(request["expected_generation"])
    revision = revision(generation)
    # Admission already constructed this exact policy from the same request.
    {:ok, policy} = policy(request["kind"], request["id"], revision, request["parameters"])

    with {:ok, thing} <- fetch(service, access, "things", request["thing_id"], request, now),
         :ok <- supported(request, thing["value"]["public"]),
         {:ok, created_at} <- existing(service, access, request, now),
         :ok <- capacity(service, access, request, now) do
      public = %{
        "schema" => "wtr.rule-definition.v1",
        "id" => request["id"],
        "kind" => request["kind"],
        "thing_id" => request["thing_id"],
        "revision" => revision,
        "policy_identity" => policy.identity,
        "parameters" => request["parameters"],
        "created_at" => created_at || now,
        "updated_at" => now
      }

      update(access, operation, request, now, %{"actor" => access.principal, "public" => public})
    end
  end

  def prepare_delete(service, access, operation, request, now) do
    case fetch(service, access, "policies", request["id"], request, now) do
      {:ok, row} ->
        with {:ok, _definition} <- definition(row["value"], request["id"]),
             do: update(access, operation, request, now, nil)

      error ->
        error
    end
  end

  def definition(%{"actor" => actor, "public" => public} = record, id)
      when map_size(record) == 2 and is_binary(actor) do
    with true <- exact?(public, @public_fields),
         true <- public["schema"] == "wtr.rule-definition.v1" and public["id"] == id,
         true <- Codec.time?(public["created_at"]) and Codec.time?(public["updated_at"]),
         true <- public["updated_at"] >= public["created_at"],
         {:ok, policy} <-
           policy(public["kind"], id, public["revision"], public["parameters"]),
         true <- policy.identity == public["policy_identity"] do
      {:ok, %{kind: public["kind"], thing_id: public["thing_id"], policy: policy}}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  def definition(_, _), do: {:error, :storage_unavailable}

  defp policy("heartbeat", id, revision, parameters) do
    with true <- exact?(parameters, @parameters["heartbeat"]),
         {:ok, policy} <-
           HeartbeatTransition.new(%{
             id: id,
             revision: revision,
             maximum_silence_ms: parameters["maximum_silence_ms"],
             future_skew_ms: parameters["future_skew_ms"]
           }) do
      {:ok, policy}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp policy("battery", id, revision, parameters) do
    with true <- exact?(parameters, @parameters["battery"]),
         {:ok, policy} <-
           BatteryTransition.new(%{
             id: id,
             revision: revision,
             measurement_kind: parameters["measurement_kind"],
             unit: parameters["unit"],
             low_threshold: parameters["low_threshold"],
             clear_threshold: parameters["clear_threshold"],
             maximum_age_ms: parameters["maximum_age_ms"],
             future_skew_ms: parameters["future_skew_ms"],
             accept_suspect: parameters["accept_suspect"]
           }) do
      {:ok, policy}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp policy(_, _, _, _), do: {:error, :invalid_policy}

  # A battery rule must consume a declared numeric Property in its exact unit.
  defp supported(%{"kind" => "heartbeat"}, _td), do: :ok

  defp supported(
         %{"kind" => "battery", "parameters" => %{"measurement_kind" => kind, "unit" => unit}},
         td
       ) do
    case get_in(td, ["properties", kind]) do
      %{"type" => "number", "unit" => ^unit} -> :ok
      _ -> {:error, :unsupported}
    end
  end

  defp existing(service, access, request, now) do
    case fetch(service, access, "policies", request["id"], request, now) do
      {:ok, row} -> same_binding(row["value"], request)
      {:error, :not_found} -> {:ok, nil}
      error -> error
    end
  end

  defp same_binding(record, %{"id" => id, "kind" => kind, "thing_id" => thing}) do
    case definition(record, id) do
      {:ok, %{kind: ^kind, thing_id: ^thing}} ->
        {:ok, record["public"]["created_at"]}

      {:ok, _} ->
        {:error, :conflict}

      error ->
        error
    end
  end

  defp capacity(service, access, request, now) do
    case Store.authorized_policies(
           service.store,
           access,
           request["thing_id"],
           request["expected_generation"],
           now
         ) do
      {:ok, rows} ->
        ids = Enum.map(rows, & &1["id"])

        if request["id"] in ids or length(ids) < @maximum_per_thing,
          do: :ok,
          else: {:error, :capacity_exceeded}

      error ->
        error
    end
  end

  defp fetch(service, access, kind, id, request, now) do
    Store.authorized_fetch(
      service.store,
      access,
      "admin",
      %{scope: access.scope, kind: kind, id: id, generation: request["expected_generation"]},
      now
    )
    |> then(fn
      {:error, :invalid_cursor} -> {:error, :conflict}
      result -> result
    end)
  end

  defp update(access, operation, request, now, value) do
    action = if value, do: "saved", else: "deleted"

    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{
        "operation" => if(value, do: "save_policy", else: "delete_policy"),
        "body" => request
      },
      observation: nil,
      publication: nil,
      response: %{"policy_id" => request["id"], "action" => action},
      records: [%{kind: "policies", id: request["id"], value: value}],
      events: [
        %{"type" => "policy.changed", "data" => %{"id" => request["id"], "action" => action}}
      ]
    })
  end

  defp revision(generation), do: Integer.to_string(generation + 1)

  # Rule IDs also appear as `kind:id` status identifiers, so they exclude colons.
  defp rule_id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, value)

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
