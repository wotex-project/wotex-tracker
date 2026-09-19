defmodule Wotex.Tracker.Service.ProjectionTest do
  @moduledoc false
  use ExUnit.Case, async: true
  import Wotex.Tracker.Service.Fixtures
  alias Wotex.Tracker
  alias Wotex.Tracker.Decoders.RuuviRawV2
  alias Wotex.Tracker.Service.{Codec, Credentials, Projection}

  test "ordinary projections omit raw source/addresses/provenance and raw decoder interpretation" do
    token = Credentials.generate_token()
    {:ok, digest} = Credentials.token_digest(token)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "server",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "credential",
            principal: "owner",
            token_sha256: digest,
            grants: %{"workshop" => ["read"]},
            expires_at: 1000
          }
        ]
      })

    observation = observation()
    id = Projection.pseudonym(credentials, "workshop", "observation", observation.id)
    assert id == Projection.pseudonym(credentials, "workshop", "observation", observation.id)
    refute id == Projection.pseudonym(credentials, "other", "observation", observation.id)
    refute id == Projection.pseudonym(credentials, "workshop", "thing", observation.id)
    {:ok, profile} = RuuviRawV2.profile()
    {:ok, catalogue} = Tracker.catalogue([profile])

    {:ok, imported} =
      Tracker.import_observation(
        observation,
        catalogue,
        {RuuviRawV2.revision(), &RuuviRawV2.decode/1}
      )

    projected = %{
      "observation" => Projection.observation(observation, id),
      "resolution" => Projection.resolution(imported.resolution),
      "measurements" => Enum.map(imported.decoded.measurements, &Projection.measurement/1)
    }

    assert projected["resolution"]["status"] == "resolved"
    assert [%{"confidence" => "exact"}] = projected["resolution"]["candidates"]
    bytes = Codec.encode!(projected)

    for secret <- [
          "private-receiver",
          "private-hardware",
          "cbb8334c884f",
          "protocol_mac",
          "provenance",
          "\"raw\""
        ],
        do: refute(bytes =~ secret)
  end

  test "browser scalars preserve zero/false/null, number versus integer, and wide counters explicitly" do
    assert Projection.scalar(0) == %{"type" => "integer", "value" => 0}
    assert Projection.scalar(false) == %{"type" => "boolean", "value" => false}
    assert Projection.scalar(true) == %{"type" => "boolean", "value" => true}
    assert Projection.scalar(nil) == %{"type" => "null", "value" => nil}
    assert Projection.scalar(1) == %{"type" => "integer", "value" => 1}
    assert Projection.scalar(1.0) == %{"type" => "number", "value" => 1.0}

    assert Projection.scalar(9_007_199_254_740_991) == %{
             "type" => "integer",
             "value" => 9_007_199_254_740_991
           }

    assert Projection.scalar(9_007_199_254_740_992) == %{
             "type" => "wide_integer",
             "value" => "9007199254740992"
           }

    assert Projection.scalar(-9_007_199_254_740_992) == %{
             "type" => "wide_integer",
             "value" => "-9007199254740992"
           }
  end

  test "legacy state projections gain an explicit empty position collection" do
    legacy = %{
      "public" => %{
        "id" => "asset",
        "observation_id" => "observation",
        "observed_at" => Projection.scalar(0),
        "measurements" => []
      }
    }

    assert Projection.resource("state", legacy)["positions"] == []
    refute Map.has_key?(legacy["public"], "positions")
  end
end
