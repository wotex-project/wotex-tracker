defmodule Wotex.Tracker.UI.SessionGuardTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.UI.SessionGuard

  defmodule Guard do
    @behaviour SessionGuard

    @impl true
    def valid_session?(:raise, _), do: raise("private guard failure")
    def valid_session?(:throw, _), do: throw(:private_guard_failure)
    def valid_session?(:bad_retain, _), do: true
    def valid_session?(expected, %{"binding" => expected}), do: true
    def valid_session?(_, _), do: false

    @impl true
    def retained_session(:bad_retain, _), do: %{"binding" => self()}
    def retained_session(expected, _), do: %{"binding" => expected}
  end

  test "admits an absent guard and an exact host-owned session binding" do
    assert :ok = SessionGuard.admit(nil, %{})
    assert :ok = SessionGuard.admit({Guard, "expected"}, %{"binding" => "expected"})
    assert %{} = SessionGuard.retain(nil, %{})

    assert %{"binding" => "expected"} =
             SessionGuard.retain({Guard, "expected"}, %{"binding" => "expected"})
  end

  test "fails closed for malformed, rejected and failing guards" do
    for guard <- [
          :invalid,
          {String, nil},
          {Guard, "different"},
          {Guard, :raise},
          {Guard, :throw}
        ] do
      assert :error = SessionGuard.admit(guard, %{"binding" => "expected"})
    end

    assert :error = SessionGuard.admit(nil, :not_a_session)
    assert %{} = SessionGuard.retain({Guard, "different"}, %{"binding" => "expected"})
    assert %{} = SessionGuard.retain({Guard, :bad_retain}, %{"binding" => "expected"})
    assert %{} = SessionGuard.retain(:invalid, %{})
  end
end
