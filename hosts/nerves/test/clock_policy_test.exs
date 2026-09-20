defmodule Wotex.Tracker.Nerves.ClockPolicyTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Nerves.ClockPolicy

  test "loopback operation never treats synchronization as a prerequisite" do
    assert :ok =
             ClockPolicy.admit([exposure: :loopback], false, fn -> flunk("clock read") end)
  end

  test "direct TLS requires this runtime to report synchronization" do
    assert :ok = ClockPolicy.admit([exposure: :tls], false, fn -> true end)

    for provider <- [
          fn -> false end,
          fn -> nil end,
          fn -> raise "private clock source" end,
          fn -> exit(:private_clock_exit) end,
          fn -> throw(:private_clock_throw) end
        ] do
      assert {:error, :clock_unsynchronized} =
               ClockPolicy.admit([exposure: :tls], false, provider)
    end
  end

  test "APNs provider tokens require synchronization even on loopback" do
    assert :ok = ClockPolicy.admit([exposure: :loopback], true, fn -> true end)

    for provider <- [fn -> false end, fn -> nil end, fn -> raise "private clock source" end] do
      assert {:error, :clock_unsynchronized} =
               ClockPolicy.admit([exposure: :loopback], true, provider)
    end
  end

  test "unknown exposure and malformed inputs fail as configuration" do
    assert {:error, :invalid_configuration} =
             ClockPolicy.admit([exposure: :proxy], false, fn -> true end)

    assert {:error, :invalid_configuration} = ClockPolicy.admit(nil, false, fn -> true end)

    assert {:error, :invalid_configuration} =
             ClockPolicy.admit([exposure: :tls], :not_a_boolean, fn -> true end)

    assert {:error, :invalid_configuration} =
             ClockPolicy.admit([exposure: :tls], false, :not_a_clock)
  end
end
