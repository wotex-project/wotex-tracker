defmodule Wotex.Tracker.UI.PresenceEvidenceTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.UI.PresenceEvidence

  @thing "urn:uuid:11111111-1111-4111-8111-111111111111"

  test "public projections are exact, bounded and three-valued" do
    value = %{
      "schema" => "wtr.owner-presence.v1",
      "thing_id" => @thing,
      "status" => "unknown",
      "revision" => "owner-presence-7",
      "observed_at" => 10,
      "admitted_at" => 11,
      "admitted_by" => "wtr1_actor-digest"
    }

    assert PresenceEvidence.public?(value, @thing)
    assert PresenceEvidence.label(value) == "Unknown"
    assert PresenceEvidence.label(%{"status" => "present"}) == "Present"
    assert PresenceEvidence.label(%{"status" => "absent"}) == "Absent"
    assert PresenceEvidence.label(%{}) == "Unknown"

    refute PresenceEvidence.public?(Map.put(value, "private", true), @thing)
    refute PresenceEvidence.public?(Map.put(value, "revision", "owner-presence-07"), @thing)
    refute PresenceEvidence.public?(Map.put(value, "admitted_by", "actor"), @thing)
    refute PresenceEvidence.public?(Map.put(value, "status", "missing"), @thing)
    refute PresenceEvidence.public?(value, "other")
    refute PresenceEvidence.public?(:invalid, @thing)
  end

  test "admission rejects values before they reach the service" do
    assert :error = PresenceEvidence.admission(%{}, @thing)
    assert :error = PresenceEvidence.admission("private", @thing)
    assert :error = PresenceEvidence.admission(%{}, nil)
  end
end
