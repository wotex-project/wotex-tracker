defmodule Wotex.Tracker.Mobile.APNsSimulatorTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wotex.Tracker.Mobile.Development.APNsSimulator

  defmodule Delivery do
    def notification(owner, payload, launch_state) do
      send(owner, {:notification_tap, payload, launch_state})
      :ok
    end
  end

  defmodule FailingDelivery do
    def notification(_context, _payload, _launch_state), do: {:error, :unavailable}
  end

  @endpoint %{
    "id" => "ios-development",
    "provider" => "apns",
    "app_id" => "org.wotex.tracker",
    "environment" => "sandbox",
    "token" => String.duplicate("01", 32)
  }

  test "keeps provider acceptance, delivery and launch-state taps distinct" do
    server = start_supervised!({APNsSimulator, name: nil, delivery: {Delivery, self()}})

    receipts =
      for {reference, launch_state} <- [
            {"cold-alert", :cold},
            {"warm-alert", :warm},
            {"background-alert", :background}
          ] do
        assert {:accepted, receipt} = APNsSimulator.dispatch(@endpoint, reference, server)
        assert {:error, :not_delivered} = APNsSimulator.tap(receipt, launch_state, server)
        assert {:error, :not_delivered} = APNsSimulator.mark_old(receipt, server)
        assert :ok = APNsSimulator.deliver(receipt, server)
        assert :ok = APNsSimulator.tap(receipt, launch_state, server)

        assert_receive {:notification_tap,
                        %{
                          source: :push,
                          data: %{
                            schema: "wtr.notification-reference.v1",
                            event_ref: ^reference
                          }
                        }, ^launch_state}

        receipt
      end

    [cold | _] = receipts
    assert :ok = APNsSimulator.tap(cold, :cold, server)
    assert :ok = APNsSimulator.mark_old(cold, server)
    assert :ok = APNsSimulator.tap(cold, :warm, server)

    assert %{event_ref: "cold-alert"} = receive_tap(:cold)
    assert %{event_ref: "cold-alert"} = receive_tap(:warm)

    status = APNsSimulator.status(server)
    assert status.provider.accepted == 3
    assert status.receipts.delivered == 3
    assert status.launches == %{cold: 2, warm: 2, background: 1}
    assert status.duplicate_taps == 2
    assert status.old_taps == 1
    refute inspect(status) =~ @endpoint["token"]
    refute inspect(status) =~ "cold-alert"
  end

  test "covers invalid-token, permanent rejection and retryable provider failures" do
    server = start_supervised!({APNsSimulator, name: nil, delivery: {Delivery, self()}})

    for {scenario, expected} <- [
          {:invalid_token, :invalid_token},
          {:rejected, :rejected},
          {:rate_limited, {:retry, :rate_limited}},
          {:offline, {:retry, :offline}}
        ] do
      assert :ok = APNsSimulator.set_scenario(scenario, server)
      result = APNsSimulator.dispatch(@endpoint, "provider-failure", server)

      case expected do
        outcome when outcome in [:invalid_token, :rejected] ->
          assert {^outcome, receipt} = result
          assert is_binary(receipt)

        retry ->
          assert ^retry = result
      end
    end

    status = APNsSimulator.status(server)

    assert status.provider == %{
             accepted: 0,
             invalid_token: 1,
             rejected: 1,
             rate_limited: 1,
             offline: 1
           }

    for invalid <- [
          {%{@endpoint | "token" => "not-hex"}, "alert"},
          {Map.put(@endpoint, "private", true), "alert"},
          {@endpoint, ""},
          {@endpoint, <<255>>}
        ] do
      assert {:error, :invalid_request} =
               APNsSimulator.dispatch(elem(invalid, 0), elem(invalid, 1), server)
    end

    assert {:error, :invalid_receipt} = APNsSimulator.deliver("unknown", server)
    assert {:error, :invalid_receipt} = APNsSimulator.tap("unknown", :warm, server)
    assert {:error, :invalid_receipt} = APNsSimulator.mark_old("unknown", server)
    assert {:error, :invalid_launch_state} = APNsSimulator.tap("unknown", :other, server)
    assert {:error, :invalid_scenario} = APNsSimulator.set_scenario(:other, server)
  end

  test "rejects invalid peers and contains unavailable processes" do
    assert {:error, :invalid_configuration} = APNsSimulator.start_link([])
    assert {:error, :invalid_configuration} = APNsSimulator.start_link(:invalid)

    assert {:error, :invalid_configuration} =
             APNsSimulator.start_link(delivery: {String, self()})

    assert %{mode: :development, state: :unavailable} = APNsSimulator.status(:missing)
    assert {:retry, :offline} = APNsSimulator.dispatch(@endpoint, "alert", :missing)
    assert {:error, :unavailable} = APNsSimulator.deliver("receipt", :missing)

    failing =
      start_supervised!(
        {APNsSimulator, name: nil, delivery: {FailingDelivery, self()}},
        id: :failing_apns
      )

    assert {:accepted, receipt} = APNsSimulator.dispatch(@endpoint, "alert", failing)
    assert :ok = APNsSimulator.deliver(receipt, failing)
    assert {:error, :delivery_unavailable} = APNsSimulator.tap(receipt, :warm, failing)

    assert %{state: :redacted, message: :redacted, log: []} =
             APNsSimulator.format_status(%{state: :secret, message: :secret, log: [:secret]})
  end

  defp receive_tap(launch_state) do
    assert_receive {:notification_tap, %{data: %{schema: "wtr.notification-reference.v1"} = data},
                    ^launch_state}

    data
  end
end
