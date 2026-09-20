defmodule Wotex.Tracker.Service.APNsHostConfigTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.Service.{APNsAdapter, APNsHostConfig}

  @p256_oid {1, 2, 840, 10_045, 3, 1, 7}

  setup do
    key = :public_key.generate_key({:namedCurve, @p256_oid})
    entry = :public_key.pem_entry_encode(:PrivateKeyInfo, key)
    %{pem: :public_key.pem_encode([entry])}
  end

  test "admits one closed provider and dispatcher document without inspectable secrets", c do
    document = document(c.pem)
    assert {:ok, config} = APNsHostConfig.new(document)
    output = inspect(config)
    refute output =~ c.pem
    refute output =~ document["title"]
    refute output =~ document["body"]
    assert output =~ "org.wotex.tracker"
    assert output =~ "workshop"

    options = APNsHostConfig.dispatcher_options(config)
    assert options[:scopes] == ["workshop"]
    assert options[:interval_ms] == 10_000
    assert options[:retry_after_ms] == 60_000
    assert options[:max_batch] == 8
    assert options[:timeout_ms] == 6_000
    assert {APNsAdapter, adapter} = options[:adapter]
    assert {:ok, ^adapter} = APNsAdapter.validate(adapter)
    refute inspect(options) =~ c.pem
  end

  test "rejects open, malformed and unsafe host documents", c do
    valid = document(c.pem)

    invalid = [
      nil,
      %{},
      Map.delete(valid, "team_id"),
      Map.put(valid, "extra", true),
      Map.put(valid, "schema", "wtr.apns-host.v2"),
      Map.put(valid, "private_key", "not a key"),
      Map.put(valid, "topics", ["org.wotex.tracker", "org.wotex.tracker"]),
      Map.put(valid, "scopes", []),
      Map.put(valid, "scopes", ["workshop", "alpha"]),
      Map.put(valid, "provider_timeout_ms", 0),
      Map.put(valid, "interval_ms", 60_001),
      Map.put(valid, "retry_after_ms", 86_400_001),
      Map.put(valid, "max_batch", 33),
      Map.put(valid, "dispatch_timeout_ms", 4_999),
      Map.put(valid, "title", "unsafe\nheader")
    ]

    Enum.each(invalid, fn value ->
      assert {:error, :invalid_configuration} = APNsHostConfig.new(value)
    end)
  end

  defp document(pem),
    do: %{
      "schema" => "wtr.apns-host.v1",
      "team_id" => "TEAMID1234",
      "key_id" => "KEYID12345",
      "private_key" => pem,
      "topics" => ["org.wotex.tracker"],
      "scopes" => ["workshop"],
      "title" => "WotEx alert",
      "body" => "Open WotEx to review this alert.",
      "provider_timeout_ms" => 5_000,
      "interval_ms" => 10_000,
      "retry_after_ms" => 60_000,
      "max_batch" => 8,
      "dispatch_timeout_ms" => 6_000
    }
end
