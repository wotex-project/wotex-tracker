defmodule Wotex.Tracker.Nerves.ClockPolicyTest do
  use ExUnit.Case, async: true
  alias Wotex.Tracker.Nerves.ClockPolicy

  test "loopback operation never treats synchronization as a prerequisite" do
    assert :ok = ClockPolicy.admit([exposure: :loopback], fn -> flunk("clock read") end)
  end

  test "direct TLS requires this runtime to report synchronization" do
    assert :ok = ClockPolicy.admit([exposure: :tls], fn -> true end)

    for provider <- [
          fn -> false end,
          fn -> nil end,
          fn -> raise "private clock source" end,
          fn -> exit(:private_clock_exit) end,
          fn -> throw(:private_clock_throw) end
        ] do
      assert {:error, :clock_unsynchronized} = ClockPolicy.admit([exposure: :tls], provider)
    end
  end

  test "unknown exposure and malformed inputs fail as configuration" do
    assert {:error, :invalid_configuration} =
             ClockPolicy.admit([exposure: :proxy], fn -> true end)

    assert {:error, :invalid_configuration} = ClockPolicy.admit(nil, fn -> true end)
    assert {:error, :invalid_configuration} = ClockPolicy.admit([exposure: :tls], :not_a_clock)
  end
end
