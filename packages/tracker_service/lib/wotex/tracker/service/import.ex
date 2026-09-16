defmodule Wotex.Tracker.Service.Import do
  @moduledoc false

  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.{Evidence, Observation}
  alias Wotex.Tracker.Service.{Codec, OperationalTelemetry, Projection, Update}

  def admit(request) do
    started = System.monotonic_time()

    result =
      with true <-
             is_map(request) and map_size(request) == 2 and Map.has_key?(request, "observation"),
           {:ok, _} <- Codec.generation(Map.get(request, "expected_generation")),
           {:ok, observation} <- Observation.from_map(request["observation"]) do
        {:ok, observation}
      else
        false -> {:error, :invalid_request}
        :error -> {:error, :invalid_request}
        {:error, _} -> {:error, :invalid_observation}
      end

    OperationalTelemetry.ingest(:admission, result, started)
    result
  end

  def prepare(service, access, operation, request, observation, now) do
    started = System.monotonic_time()

    result =
      case Tracker.import_observation(
             observation,
             service.catalogue,
             {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
           ) do
        {:ok, imported} -> update(service, access, operation, request, now, imported)
        {:error, _} -> {:error, :invalid_observation}
      end

    OperationalTelemetry.ingest(:decode, result, started)
    result
  end

  defp update(service, access, operation, request, now, imported) do
    id =
      Projection.pseudonym(
        service.credentials,
        access.scope,
        "observation",
        imported.observation.id
      )

    measurements =
      if imported.decoded,
        do: Enum.map(imported.decoded.measurements, &Projection.measurement/1),
        else: []

    evidence = if imported.decoded, do: evidence(imported.decoded), else: []

    public = %{
      "observation" => Projection.observation(imported.observation, id),
      "resolution" => Projection.resolution(imported.resolution)
    }

    index = %{
      "observation_id" => imported.observation.id,
      "catalogue_identity" => service.catalogue.identity,
      "public" => public
    }

    state = %{
      "id" => id,
      "observation_id" => id,
      "observed_at" => Projection.scalar(imported.observation.observed_at),
      "measurements" => measurements
    }

    Update.new(%{
      principal: access.principal,
      scope: access.scope,
      authority: access,
      operation_id: operation,
      expected_generation: request["expected_generation"],
      now: now,
      request: %{"operation" => "import", "body" => request},
      observation: imported.observation,
      publication: nil,
      response: %{"observation_id" => id},
      records: [
        %{kind: "resolutions", id: id, value: index},
        %{
          kind: "evidence",
          id: id,
          value: %{
            "claims" => evidence,
            "public" => %{"id" => id, "claim_count" => length(evidence)}
          }
        },
        %{kind: "state", id: id, value: %{"public" => state}}
      ],
      events: [
        %{
          "type" => "observation.admitted",
          "data" => %{"id" => id, "status" => Atom.to_string(imported.resolution.status)}
        }
      ]
    })
  end

  defp evidence(decoded) do
    decoded.bundle.evidence
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn evidence ->
      {:ok, map} = Evidence.to_map(evidence)
      map
    end)
  end
end
