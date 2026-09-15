defmodule Wotex.Tracker.Fixtures do
  @moduledoc false
  alias Wotex.Tracker.{Evidence, EvidenceBundle, Observation}

  def observation_input(changes \\ %{}) do
    Map.merge(
      %{
        id: "observation-1",
        observed_at: 1_700_000_000_000,
        ingress: "ble",
        source: %{"receiver_id" => "fixture-receiver"},
        addressing: %{"address_type" => "random"},
        payload: {:bytes, <<5, 0>>},
        radio: %{"rssi" => -70},
        transport: %{},
        provenance: %{"kind" => "fixture", "source" => "synthetic-test-v1"}
      },
      changes
    )
  end

  def observation(changes \\ %{}) do
    {:ok, value} = Observation.new(observation_input(changes))
    value
  end

  def evidence_input(changes \\ %{}) do
    Map.merge(
      %{
        id: "claim-1",
        kind: :measurement,
        claim: %{"value" => 0, "unit" => "Cel", "quality" => "valid"},
        source_observation_ids: ["observation-1"],
        evidence_ids: [],
        profile: {"synthetic", "1"},
        decoder: {"synthetic", "1"},
        confidence: :exact,
        reasons: ["synthetic"],
        association_id: nil
      },
      changes
    )
  end

  def evidence(changes \\ %{}) do
    {:ok, value} = Evidence.new(evidence_input(changes))
    value
  end

  def thing_id, do: "urn:uuid:aca49b80-1e09-40cf-929e-b193047f6ca9"

  def identity_input do
    %{
      thing_id: thing_id(),
      association_id: "enrollment-1",
      revision: "1",
      evidence_id: "identity-1"
    }
  end

  def identity_evidence do
    evidence(%{
      id: "identity-1",
      kind: :identity,
      association_id: "enrollment-1",
      claim: %{"thing_id" => thing_id(), "strategy" => "operator-pseudonym-v1", "revision" => "1"}
    })
  end

  def bundle do
    {:ok, bundle} = EvidenceBundle.new([observation()], [identity_evidence(), evidence()])
    bundle
  end
end
