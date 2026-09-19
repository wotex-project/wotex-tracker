defmodule Wotex.Tracker.Service.RuleDefinition do
  @moduledoc false

  # Administrators bind a closed state or suspicious-movement policy to one
  # enrolled Thing.
  # The service assigns the policy revision from the definition's commit
  # generation and validates it through the pure constructor before storage.

  alias Wotex.Tracker.{
    BatteryTransition,
    Geofence,
    GeofenceTransition,
    HeartbeatTransition,
    MotionTransition,
    PositionMovement,
    PositionOrder,
    SuspiciousMovement
  }

  alias Wotex.Tracker.Service.{Codec, RuleEvaluation, Store, Update}

  @save_fields ~w(id kind thing_id parameters expected_generation)
  @delete_fields ~w(id expected_generation)
  @public_fields ~w(schema id kind thing_id revision policy_identity parameters created_at updated_at)
  @parameters %{
    "heartbeat" => ~w(maximum_silence_ms future_skew_ms),
    "battery" =>
      ~w(measurement_kind unit low_threshold clear_threshold maximum_age_ms future_skew_ms accept_suspect),
    "motion" =>
      ~w(event_time future_skew_ms late_window_ms sequence moving_speed_m_s stationary_speed_m_s moving_distance_m stationary_distance_m max_plausible_speed_m_s max_gap_ms uncertainty minimum_movement_ms minimum_stop_ms),
    "geofence" =>
      ~w(shape boundary uncertainty event_time future_skew_ms late_window_ms sequence max_transition_gap_ms),
    "suspicious_movement" =>
      ~w(motion_rule_id maximum_fact_age_ms future_skew_ms owner_unknown_as_absent)
  }
  @maximum_per_thing 8

  def admit_save(request) do
    with true <- exact?(request, @save_fields),
         true <- rule_id?(request["id"]),
         "urn:uuid:" <> _ <- request["thing_id"],
         true <- Codec.id?(request["thing_id"]),
         {:ok, generation} <- Codec.generation(request["expected_generation"]),
         :ok <-
           admit_policy(
             request["kind"],
             request["id"],
             revision(generation),
             request["parameters"]
           ) do
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

    with {:ok, thing} <- fetch(service, access, "things", request["thing_id"], request, now),
         :ok <- supported(request, thing["value"]["public"]),
         {:ok, definition} <- resolved_definition(service, access, request, revision, now),
         {:ok, created_at} <- existing(service, access, request, now),
         :ok <- capacity(service, access, request, now),
         {:ok, observation, bundle} <-
           RuleEvaluation.committed_input(
             service,
             access,
             "admin",
             request["thing_id"],
             request["expected_generation"],
             now
           ),
         {:ok, rules} <-
           RuleEvaluation.transitions(
             service,
             access.scope,
             [definition],
             observation,
             bundle,
             now
           ) do
      public = %{
        "schema" => "wtr.rule-definition.v1",
        "id" => request["id"],
        "kind" => request["kind"],
        "thing_id" => request["thing_id"],
        "revision" => revision,
        "policy_identity" => policy_identity(definition),
        "parameters" => request["parameters"],
        "created_at" => created_at || now,
        "updated_at" => now
      }

      update(
        access,
        operation,
        {request, now},
        stored_definition(access.principal, public, definition),
        rules
      )
    end
  end

  def prepare_delete(service, access, operation, request, now) do
    case fetch(service, access, "policies", request["id"], request, now) do
      {:ok, row} ->
        with {:ok, _definition} <- definition(row["value"], request["id"]),
             do: update(access, operation, {request, now}, nil, [])

      error ->
        error
    end
  end

  def definition(%{"actor" => actor, "public" => public} = record, id)
      when map_size(record) == 2 do
    with :ok <- public_definition(actor, public, id),
         {:ok, definition} <-
           definition_policy(public["kind"], id, public["revision"], public["parameters"]),
         definition = Map.put(definition, :thing_id, public["thing_id"]),
         true <- policy_identity(definition) == public["policy_identity"] do
      {:ok, definition}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  def definition(
        %{"actor" => actor, "public" => public, "policy" => policy_document} = record,
        id
      )
      when map_size(record) == 3 do
    with :ok <- public_definition(actor, public, id),
         true <- public["kind"] == "suspicious_movement",
         :ok <- suspicious_parameters(id, public["parameters"]),
         {:ok, policy} <- SuspiciousMovement.from_map(policy_document),
         true <- policy.id == id and policy.revision == public["revision"],
         true <- policy.armed_predicate == "asset.armed",
         true <- policy.owner_presence_predicate == "owner.present",
         true <- policy.motion_policy.id == public["parameters"]["motion_rule_id"],
         true <- policy.maximum_fact_age_ms == public["parameters"]["maximum_fact_age_ms"],
         true <- policy.future_skew_ms == public["parameters"]["future_skew_ms"],
         true <-
           policy.owner_unknown_as_absent == public["parameters"]["owner_unknown_as_absent"],
         definition = %{
           kind: "suspicious_movement",
           policy: policy,
           thing_id: public["thing_id"],
           motion_rule_id: public["parameters"]["motion_rule_id"]
         },
         true <- policy_identity(definition) == public["policy_identity"] do
      {:ok, definition}
    else
      _ -> {:error, :storage_unavailable}
    end
  end

  def definition(_, _), do: {:error, :storage_unavailable}

  defp admit_policy("suspicious_movement", id, _revision, parameters),
    do: suspicious_parameters(id, parameters)

  defp admit_policy(kind, id, revision, parameters) do
    case definition_policy(kind, id, revision, parameters) do
      {:ok, _definition} -> :ok
      error -> error
    end
  end

  defp definition_policy("heartbeat", id, revision, parameters) do
    with true <- exact?(parameters, @parameters["heartbeat"]),
         {:ok, policy} <-
           HeartbeatTransition.new(%{
             id: id,
             revision: revision,
             maximum_silence_ms: parameters["maximum_silence_ms"],
             future_skew_ms: parameters["future_skew_ms"]
           }) do
      {:ok, %{kind: "heartbeat", policy: policy}}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp definition_policy("battery", id, revision, parameters) do
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
      {:ok, %{kind: "battery", policy: policy}}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp definition_policy("motion", id, revision, parameters) do
    with true <- exact?(parameters, @parameters["motion"]),
         {:ok, order} <- order_policy(revision, parameters),
         {:ok, uncertainty} <- uncertainty(parameters["uncertainty"]),
         {:ok, movement} <-
           PositionMovement.new(%{
             id: id,
             revision: revision,
             order_policy: order,
             moving_speed_m_s: parameters["moving_speed_m_s"],
             stationary_speed_m_s: parameters["stationary_speed_m_s"],
             moving_distance_m: parameters["moving_distance_m"],
             stationary_distance_m: parameters["stationary_distance_m"],
             max_plausible_speed_m_s: parameters["max_plausible_speed_m_s"],
             max_gap_ms: parameters["max_gap_ms"],
             uncertainty: uncertainty
           }),
         {:ok, policy} <-
           MotionTransition.new(%{
             id: id,
             revision: revision,
             movement_policy: movement,
             minimum_movement_ms: parameters["minimum_movement_ms"],
             minimum_stop_ms: parameters["minimum_stop_ms"]
           }) do
      {:ok, %{kind: "motion", policy: policy}}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp definition_policy("geofence", id, revision, parameters) do
    with true <- exact?(parameters, @parameters["geofence"]),
         {:ok, shape} <- shape(parameters["shape"]),
         {:ok, boundary} <- boundary(parameters["boundary"]),
         {:ok, uncertainty} <- uncertainty(parameters["uncertainty"]),
         {:ok, fence} <-
           Geofence.new(%{
             id: id,
             revision: revision,
             shape: shape,
             boundary: boundary,
             uncertainty: uncertainty
           }),
         {:ok, order} <- order_policy(revision, parameters),
         {:ok, policy} <-
           GeofenceTransition.new(%{
             id: id,
             revision: revision,
             order_policy: order,
             max_transition_gap_ms: parameters["max_transition_gap_ms"]
           }) do
      {:ok, %{kind: "geofence", fence: fence, policy: policy}}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp definition_policy(_, _, _, _), do: {:error, :invalid_policy}

  defp resolved_definition(
         service,
         access,
         %{"kind" => "suspicious_movement"} = request,
         revision,
         now
       ) do
    motion_id = request["parameters"]["motion_rule_id"]

    with {:ok, row} <- fetch(service, access, "policies", motion_id, request, now),
         {:ok, %{kind: "motion", thing_id: thing, policy: motion_policy}} <-
           definition(row["value"], motion_id),
         true <- thing == request["thing_id"],
         {:ok, policy} <-
           SuspiciousMovement.new(%{
             id: request["id"],
             revision: revision,
             motion_policy: motion_policy,
             armed_predicate: "asset.armed",
             owner_presence_predicate: "owner.present",
             maximum_fact_age_ms: request["parameters"]["maximum_fact_age_ms"],
             future_skew_ms: request["parameters"]["future_skew_ms"],
             owner_unknown_as_absent: request["parameters"]["owner_unknown_as_absent"]
           }) do
      {:ok,
       %{
         kind: "suspicious_movement",
         policy: policy,
         thing_id: thing,
         motion_rule_id: motion_id
       }}
    else
      false -> {:error, :conflict}
      {:ok, _} -> {:error, :conflict}
      {:error, %Wotex.Tracker.Error{}} -> {:error, :invalid_policy}
      error -> error
    end
  end

  defp resolved_definition(_service, _access, request, revision, _now) do
    with {:ok, definition} <-
           definition_policy(request["kind"], request["id"], revision, request["parameters"]),
         do: {:ok, Map.put(definition, :thing_id, request["thing_id"])}
  end

  defp suspicious_parameters(id, parameters) do
    with true <- exact?(parameters, @parameters["suspicious_movement"]),
         true <- rule_id?(parameters["motion_rule_id"]),
         true <- parameters["motion_rule_id"] != id,
         true <- duration?(parameters["maximum_fact_age_ms"]),
         true <- duration?(parameters["future_skew_ms"]),
         true <- is_boolean(parameters["owner_unknown_as_absent"]) do
      :ok
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp public_definition(actor, public, id) do
    if exact?(public, @public_fields) and public_identity?(actor, public, id) and
         public_times?(public),
       do: :ok,
       else: {:error, :storage_unavailable}
  end

  defp public_identity?(actor, public, id),
    do:
      Codec.id?(actor) and public["schema"] == "wtr.rule-definition.v1" and
        public["id"] == id and Codec.id?(public["thing_id"]) and
        Codec.id?(public["revision"]) and Codec.id?(public["policy_identity"])

  defp public_times?(public),
    do:
      Codec.time?(public["created_at"]) and Codec.time?(public["updated_at"]) and
        public["updated_at"] >= public["created_at"]

  defp stored_definition(actor, public, %{kind: "suspicious_movement", policy: policy}) do
    {:ok, policy_document} = SuspiciousMovement.to_map(policy)
    %{"actor" => actor, "public" => public, "policy" => policy_document}
  end

  defp stored_definition(actor, public, _definition),
    do: %{"actor" => actor, "public" => public}

  defp order_policy(revision, parameters) do
    with {:ok, event_time} <- event_time(parameters["event_time"]),
         {:ok, sequence} <- sequence(parameters["sequence"]) do
      PositionOrder.new(%{
        revision: revision,
        event_time: event_time,
        future_skew_ms: parameters["future_skew_ms"],
        late_window_ms: parameters["late_window_ms"],
        sequence: sequence
      })
    end
  end

  defp shape(%{"kind" => "circle"} = value) when map_size(value) == 4 do
    {:ok,
     %{
       kind: :circle,
       latitude: value["latitude"],
       longitude: value["longitude"],
       radius_m: value["radius_m"]
     }}
  end

  defp shape(%{"kind" => "polygon", "vertices" => vertices} = value)
       when map_size(value) == 2 and is_list(vertices) do
    Enum.reduce_while(vertices, {:ok, []}, fn
      %{"latitude" => latitude, "longitude" => longitude} = vertex, {:ok, acc}
      when map_size(vertex) == 2 ->
        {:cont, {:ok, [%{latitude: latitude, longitude: longitude} | acc]}}

      _, _ ->
        {:halt, {:error, :invalid_policy}}
    end)
    |> case do
      {:ok, admitted} -> {:ok, %{kind: :polygon, vertices: Enum.reverse(admitted)}}
      error -> error
    end
  end

  defp shape(_), do: {:error, :invalid_policy}

  defp event_time("trusted_fix"), do: {:ok, :trusted_fix}
  defp event_time("trusted_fix_or_receiver"), do: {:ok, :trusted_fix_or_receiver}
  defp event_time(_), do: {:error, :invalid_policy}

  defp sequence("none"), do: {:ok, :none}
  defp sequence("optional"), do: {:ok, :optional}
  defp sequence("required"), do: {:ok, :required}
  defp sequence(_), do: {:error, :invalid_policy}

  defp boundary("inside"), do: {:ok, :inside}
  defp boundary("outside"), do: {:ok, :outside}
  defp boundary(_), do: {:error, :invalid_policy}

  defp uncertainty("require_bound"), do: {:ok, :require_bound}
  defp uncertainty("coordinate_only"), do: {:ok, :coordinate_only}
  defp uncertainty(_), do: {:error, :invalid_policy}

  defp policy_identity(%{kind: "geofence", fence: fence, policy: policy}) do
    Codec.digest(%{
      "schema" => "wtr.geofence-definition-policy.v1",
      "fence_identity" => fence.identity,
      "transition_identity" => policy.identity
    })
  end

  defp policy_identity(%{policy: policy}), do: policy.identity

  # A battery rule must consume a declared numeric Property in its exact unit.
  defp supported(%{"kind" => "heartbeat"}, _td), do: :ok

  defp supported(%{"kind" => kind}, _td)
       when kind in ~w(motion geofence suspicious_movement),
       do: :ok

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
      {:error, :not_found} -> lineage(service, access, request, now)
      error -> error
    end
  end

  # A deleted ID can be defined again only for its original kind and Thing, so one
  # rule history never mixes evidence from different assets.
  defp lineage(service, access, request, now) do
    query = %{
      scope: access.scope,
      kind: "policies",
      id: request["id"],
      generation: request["expected_generation"],
      after: "0",
      limit: 1
    }

    case Store.authorized_history(service.store, access, "admin", query, now) do
      {:ok, %{"items" => [%{"value" => first}]}} ->
        with {:ok, _created_at} <- same_binding(first, request), do: {:ok, nil}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, :invalid_cursor} ->
        {:error, :conflict}

      error ->
        error
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
           "admin",
           request["thing_id"],
           request["expected_generation"],
           now
         ) do
      {:ok, %{"items" => rows}} ->
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

  defp update(access, operation, {request, now}, value, rules) do
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
      rules: rules,
      records: [%{kind: "policies", id: request["id"], value: value}],
      events: [
        %{"type" => "policy.changed", "data" => %{"id" => request["id"], "action" => action}}
      ]
    })
  end

  defp revision(generation), do: Integer.to_string(generation + 1)

  defp duration?(value), do: is_integer(value) and value in 0..604_800_000

  # Rule IDs also appear as `kind:id` status identifiers, so they exclude colons.
  defp rule_id?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,62}\z/, value)

  defp exact?(value, fields),
    do:
      is_map(value) and not is_struct(value) and
        Enum.sort(Map.keys(value)) == Enum.sort(fields)
end
