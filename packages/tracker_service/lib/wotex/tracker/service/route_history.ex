defmodule Wotex.Tracker.Service.RouteHistory do
  @moduledoc false

  alias Wotex.Tracker.{
    Evidence,
    EvidenceBundle,
    Observation,
    Position,
    PositionSample,
    RouteReplay
  }

  alias Wotex.Tracker.Service.{
    Access,
    Codec,
    Credentials,
    Cursor,
    Identifier,
    Projection,
    Store
  }

  @schema "wtr.route-page-request.v1"
  @algorithm "snapshot-pinned-gap-honest-route-v1"
  @fields ~w(schema thing_id from_at to_at event_time qualities max_gap_ms max_gap_m page_size cursor)
  @earth_radius_m 6_371_008.8

  def run(service, %Access{} = access, request, now) do
    with {:ok, admitted} <- request(request),
         {:ok, generation, after_generation} <- position(service, access, admitted, now),
         {:ok, page} <- history(service, access, admitted, generation, after_generation, now),
         {:ok, tokens} <- tokens(service, access, admitted, page, now),
         {:ok, route} <- replay(service, access, admitted, tokens),
         {:ok, cursor} <- next_cursor(service, access, admitted, page, now) do
      material = %{
        "schema" => "wtr.route-page.v1",
        "algorithm" => @algorithm,
        "thing_id" => admitted.thing_id,
        "generation" => page["generation"],
        "history" => history_window(page, after_generation),
        "window" => %{"from_at" => admitted.from_at, "to_at" => admitted.to_at},
        "continuity" => "page_local_only",
        "route" => route
      }

      {:ok,
       material
       |> Map.put("cursor", cursor)
       |> Map.put("identity", "wtr-route-page-v1:sha256:" <> Codec.digest(material))}
    else
      {:error, %Wotex.Tracker.Error{}} -> {:error, :invalid_request}
      error -> error
    end
  end

  def run(_, _, _, _), do: {:error, :invalid_request}

  defp request(%{} = request) do
    with true <- Enum.sort(Map.keys(request)) == Enum.sort(@fields),
         true <- request["schema"] == @schema,
         true <- thing?(request["thing_id"]),
         true <- Codec.time?(request["from_at"]) and Codec.time?(request["to_at"]),
         true <- request["from_at"] < request["to_at"],
         {:ok, event_time} <- event_time(request["event_time"]),
         {:ok, qualities} <- qualities(request["qualities"]),
         true <- is_integer(request["page_size"]) and request["page_size"] in 1..100,
         true <- is_nil(request["cursor"]) or is_binary(request["cursor"]),
         material = Map.drop(request, ["cursor"]),
         request_identity = "wtr-route-request-v1:sha256:" <> Codec.digest(material),
         {:ok, policy} <-
           RouteReplay.new(%{
             id: "route-history",
             revision: request_identity,
             event_time: event_time,
             qualities: qualities,
             max_gap_ms: request["max_gap_ms"],
             max_gap_m: request["max_gap_m"],
             max_samples: request["page_size"]
           }) do
      {:ok,
       %{
         thing_id: request["thing_id"],
         from_at: request["from_at"],
         to_at: request["to_at"],
         page_size: request["page_size"],
         cursor: request["cursor"],
         request_identity: request_identity,
         policy: policy
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  defp request(_), do: {:error, :invalid_request}

  defp position(_service, _access, %{cursor: nil}, _now), do: {:ok, nil, "0"}

  defp position(service, access, admitted, now) do
    with {:ok, data} <-
           Cursor.open(
             Credentials.derive_key(service.credentials, :cursor),
             binding(service, access),
             admitted.cursor,
             now
           ),
         true <-
           data["thing_id"] == admitted.thing_id and
             data["request_identity"] == admitted.request_identity and
             data["page_size"] == admitted.page_size do
      {:ok, data["generation"], data["after"]}
    else
      false -> {:error, :invalid_cursor}
      error -> error
    end
  end

  defp history(service, access, admitted, generation, after_generation, now) do
    Store.authorized_history(
      service.store,
      access,
      "read",
      %{
        scope: access.scope,
        kind: "evidence",
        id: admitted.thing_id,
        generation: generation,
        after: after_generation,
        limit: admitted.page_size
      },
      now
    )
  end

  defp tokens(service, access, admitted, page, now) do
    Enum.reduce_while(page["items"], {:ok, []}, fn item, {:ok, tokens} ->
      case token(service, access, admitted, page["generation"], item, now) do
        {:ok, nil} -> {:cont, {:ok, tokens}}
        {:ok, token} -> {:cont, {:ok, [token | tokens]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, tokens} -> {:ok, Enum.sort_by(tokens, & &1.order)}
      error -> error
    end)
  end

  defp token(service, access, admitted, generation, item, now) do
    with {:ok, evidence} <- evidence(item["value"]),
         [observation_id] <- source_observations(evidence),
         {:ok, row} <-
           Store.authorized_fetch(
             service.store,
             access,
             "read",
             %{
               scope: access.scope,
               kind: "observations",
               id: observation_id,
               generation: generation
             },
             now
           ),
         {:ok, observation} <- stored_observation(row["value"]),
         {:ok, bundle} <- EvidenceBundle.new([observation], evidence) do
      position_token(service, access, admitted, item, observation, bundle)
    else
      {:error, code} when is_atom(code) -> {:error, code}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp position_token(service, access, admitted, item, observation, bundle) do
    positions = bundle.evidence |> Map.values() |> Enum.filter(&(&1.kind == :position))

    case positions do
      [evidence] ->
        with {:ok, position} <- Position.new(evidence.id, bundle),
             {:ok, sample} <- PositionSample.new(position, bundle) do
          sample_token(admitted, sample)
        else
          _ -> {:error, :storage_unavailable}
        end

      [] ->
        exclusion_token(
          service,
          access,
          admitted,
          item,
          observation.observed_at,
          "missing_position"
        )

      _ ->
        exclusion_token(
          service,
          access,
          admitted,
          item,
          observation.observed_at,
          "ambiguous_positions"
        )
    end
  end

  defp sample_token(admitted, sample) do
    order = sample_order(sample, admitted.policy.event_time)

    if in_window?(order, admitted),
      do: {:ok, %{kind: :sample, order: order, sample: sample}},
      else: {:ok, nil}
  end

  defp exclusion_token(service, access, admitted, item, observed_at, reason) do
    identity =
      Projection.pseudonym(
        service.credentials,
        access.scope,
        "route-exclusion",
        admitted.thing_id <> ":" <> item["generation"] <> ":" <> reason
      )

    order = {observed_at, observed_at, identity, identity, identity}

    if in_window?(order, admitted) do
      {:ok,
       %{
         kind: :exclusion,
         order: order,
         exclusion: %{
           "schema" => "wtr.route-exclusion.v1",
           "id" => identity,
           "received_at" => Projection.scalar(observed_at),
           "reason" => reason
         }
       }}
    else
      {:ok, nil}
    end
  end

  defp replay(service, access, admitted, tokens) do
    samples = for %{kind: :sample, sample: sample} <- tokens, do: sample
    exclusions = for %{kind: :exclusion} = token <- tokens, do: token

    with {:ok, result} <- RouteReplay.evaluate(samples, admitted.policy) do
      {:ok, public_result(service, access, admitted, result, exclusions)}
    end
  end

  defp public_result(service, access, admitted, result, exclusions) do
    segments =
      Enum.flat_map(result["segments"], fn segment ->
        split_segment(service, access, segment, exclusions)
      end)

    service_breaks =
      Enum.flat_map(result["segments"], fn segment ->
        exclusion_breaks(service, access, segment, exclusions)
      end)

    points =
      result["segments"]
      |> Enum.flat_map(& &1["points"])
      |> Map.new(&{&1["sample_identity"], &1})

    breaks =
      result["breaks"]
      |> Enum.map(&public_break(service, access, &1, points))
      |> Kernel.++(service_breaks)
      |> Enum.sort_by(&break_order/1)

    rejected = Enum.map(result["rejected"], &public_rejection(service, access, &1))
    public_exclusions = Enum.map(exclusions, & &1.exclusion)
    point_count = Enum.reduce(segments, 0, &(&1["point_count"] + &2))
    partial = breaks != [] or rejected != [] or public_exclusions != []

    %{
      "schema" => "wtr.route-replay-public.v1",
      "algorithm" => @algorithm,
      "status" => status(point_count, partial),
      "reason" => reason(point_count, partial),
      "record_count" => result["sample_count"] + length(public_exclusions),
      "sample_count" => result["sample_count"],
      "point_count" => point_count,
      "segment_count" => length(segments),
      "break_count" => length(breaks),
      "rejected_count" => length(rejected),
      "excluded_count" => length(public_exclusions),
      "segments" => segments,
      "breaks" => breaks,
      "rejected" => rejected,
      "excluded" => public_exclusions,
      "policy" => result["policy"],
      "window" => %{"from_at" => admitted.from_at, "to_at" => admitted.to_at}
    }
  end

  defp split_segment(service, access, %{"points" => points}, exclusions) do
    points
    |> Enum.chunk_while([], &split_point(&1, &2, exclusions), &split_after/1)
    |> Enum.map(fn chunk ->
      public_points = Enum.map(chunk, &public_point(service, access, &1))

      %{
        "schema" => "wtr.route-segment-public.v1",
        "point_count" => length(public_points),
        "points" => public_points
      }
    end)
  end

  defp split_point(point, [], _exclusions), do: {:cont, [point]}

  defp split_point(point, [previous | _] = chunk, exclusions) do
    if exclusions_between?(previous, point, exclusions),
      do: {:cont, Enum.reverse(chunk), [point]},
      else: {:cont, [point | chunk]}
  end

  defp split_after([]), do: {:cont, []}
  defp split_after(chunk), do: {:cont, Enum.reverse(chunk), []}

  defp exclusion_breaks(service, access, %{"points" => points}, exclusions) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [from, to] ->
      between = between(from, to, exclusions)

      if between == [] do
        []
      else
        [
          %{
            "schema" => "wtr.route-break-public.v1",
            "after_point_id" => point_id(service, access, from["sample_identity"]),
            "before_point_id" => point_id(service, access, to["sample_identity"]),
            "after_event_at" => Projection.scalar(from["event_at"]),
            "before_event_at" => Projection.scalar(to["event_at"]),
            "gap_ms" => Projection.scalar(to["event_at"] - from["event_at"]),
            "center_distance_m" => Projection.scalar(distance(from, to)),
            "reason" => "unqualified_materialisations",
            "excluded_ids" => Enum.map(between, & &1.exclusion["id"]),
            "rejected_ids" => []
          }
        ]
      end
    end)
  end

  defp exclusions_between?(from, to, exclusions), do: between(from, to, exclusions) != []

  defp between(from, to, exclusions) do
    from_order = point_order(from)
    to_order = point_order(to)
    Enum.filter(exclusions, &(&1.order > from_order and &1.order < to_order))
  end

  defp public_point(service, access, point) do
    %{
      "schema" => "wtr.route-point-public.v1",
      "id" => point_id(service, access, point["sample_identity"]),
      "latitude" => Projection.scalar(point["latitude"]),
      "longitude" => Projection.scalar(point["longitude"]),
      "horizontal_accuracy_m" => Projection.scalar(point["horizontal_accuracy_m"]),
      "accuracy_kind" => point["accuracy_kind"],
      "source" => point["source"],
      "quality" => point["quality"],
      "event_at" => Projection.scalar(point["event_at"]),
      "event_time_basis" => point["event_time_basis"],
      "received_at" => Projection.scalar(point["received_at"])
    }
  end

  defp public_break(service, access, value, points) do
    from = Map.fetch!(points, value["after_sample_identity"])
    to = Map.fetch!(points, value["before_sample_identity"])

    %{
      "schema" => "wtr.route-break-public.v1",
      "after_point_id" => point_id(service, access, value["after_sample_identity"]),
      "before_point_id" => point_id(service, access, value["before_sample_identity"]),
      "after_event_at" => Projection.scalar(from["event_at"]),
      "before_event_at" => Projection.scalar(to["event_at"]),
      "gap_ms" => Projection.scalar(value["gap_ms"]),
      "center_distance_m" => Projection.scalar(value["center_distance_m"]),
      "reason" => value["reason"],
      "excluded_ids" => [],
      "rejected_ids" =>
        Enum.map(value["rejected_sample_identities"], &point_id(service, access, &1))
    }
  end

  defp public_rejection(service, access, value) do
    %{
      "schema" => "wtr.route-rejection-public.v1",
      "id" => point_id(service, access, value["sample_identity"]),
      "received_at" => Projection.scalar(value["received_at"]),
      "reason" => value["reason"]
    }
  end

  defp next_cursor(_service, _access, _admitted, %{"next" => nil}, _now), do: {:ok, nil}

  defp next_cursor(service, access, admitted, page, now) do
    Cursor.issue(
      Credentials.derive_key(service.credentials, :cursor),
      binding(service, access),
      %{
        "kind" => "route",
        "thing_id" => admitted.thing_id,
        "generation" => page["generation"],
        "after" => page["next"],
        "request_identity" => admitted.request_identity,
        "page_size" => admitted.page_size
      },
      now
    )
  end

  defp history_window(page, after_generation) do
    last_generation = page["items"] |> List.last() |> Map.fetch!("generation")

    %{
      "after_generation" => after_generation,
      "last_generation" => last_generation,
      "record_count" => length(page["items"])
    }
  end

  defp evidence(%{"claims" => claims, "public" => _public} = value)
       when map_size(value) == 2 and is_list(claims) do
    Enum.reduce_while(claims, {:ok, []}, fn claim, {:ok, values} ->
      case Evidence.from_map(claim) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        _ -> {:halt, {:error, :storage_unavailable}}
      end
    end)
  end

  defp evidence(_), do: {:error, :storage_unavailable}

  defp stored_observation(document) do
    case Observation.from_map(document) do
      {:ok, observation} -> {:ok, observation}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp source_observations(evidence),
    do: evidence |> Enum.flat_map(& &1.source_observation_ids) |> Enum.uniq()

  defp sample_order(sample, event_time) do
    claim = sample.position.claim
    received_at = claim["received_at"]

    event_at =
      case claim do
        %{"fix_at" => fix_at, "fix_clock" => "trusted"} when is_integer(fix_at) ->
          if fix_at <= received_at, do: fix_at, else: received_at

        %{"fix_at" => nil} when event_time == :trusted_fix_or_receiver ->
          received_at

        _ ->
          received_at
      end

    {
      event_at,
      received_at,
      sample.position.evidence_id,
      sample.position.bundle_identity,
      sample.identity
    }
  end

  defp point_order(point),
    do: {
      point["event_at"],
      point["received_at"],
      point["position_evidence_id"],
      point["position_bundle_identity"],
      point["sample_identity"]
    }

  defp in_window?({event_at, _, _, _, _}, admitted),
    do: event_at >= admitted.from_at and event_at < admitted.to_at

  defp point_id(service, access, identity),
    do: Projection.pseudonym(service.credentials, access.scope, "route-point", identity)

  defp break_order(break),
    do: {
      break["after_event_at"]["value"],
      break["before_event_at"]["value"],
      break["after_point_id"],
      break["before_point_id"],
      break["reason"]
    }

  defp status(0, _), do: "empty"
  defp status(_, true), do: "partial"
  defp status(_, false), do: "complete"
  defp reason(0, _), do: "no_qualified_positions"
  defp reason(_, true), do: "gaps_or_rejections"
  defp reason(_, false), do: "all_positions_qualified"

  defp event_time("trusted_fix"), do: {:ok, :trusted_fix}
  defp event_time("trusted_fix_or_receiver"), do: {:ok, :trusted_fix_or_receiver}
  defp event_time(_), do: {:error, :invalid_request}

  defp qualities(values) when is_list(values) and values != [] do
    values
    |> Enum.reduce_while({:ok, []}, fn
      "valid", {:ok, acc} -> {:cont, {:ok, [:valid | acc]}}
      "suspect", {:ok, acc} -> {:cont, {:ok, [:suspect | acc]}}
      _, _ -> {:halt, {:error, :invalid_request}}
    end)
    |> then(fn
      {:ok, admitted} ->
        admitted = Enum.reverse(admitted)

        if length(admitted) == length(Enum.uniq(admitted)),
          do: {:ok, admitted},
          else: {:error, :invalid_request}

      error ->
        error
    end)
  end

  defp qualities(_), do: {:error, :invalid_request}

  defp thing?("urn:uuid:" <> id), do: Identifier.operation?(id)
  defp thing?(_), do: false

  defp distance(from, to) do
    latitude_a = radians(from["latitude"])
    latitude_b = radians(to["latitude"])
    latitude_delta = latitude_b - latitude_a
    longitude_delta = radians(longitude_delta(from["longitude"], to["longitude"]))

    haversine =
      :math.pow(:math.sin(latitude_delta / 2), 2) +
        :math.cos(latitude_a) * :math.cos(latitude_b) *
          :math.pow(:math.sin(longitude_delta / 2), 2)

    @earth_radius_m * 2 * :math.asin(:math.sqrt(min(1.0, haversine)))
  end

  defp longitude_delta(from, to) do
    delta = to - from

    cond do
      delta > 180 -> delta - 360
      delta < -180 -> delta + 360
      true -> delta
    end
  end

  defp radians(value), do: value * :math.pi() / 180

  defp binding(service, access),
    do: %{
      instance: Credentials.instance_id(service.credentials),
      principal: access.principal,
      scope: access.scope,
      purpose: "route"
    }
end
