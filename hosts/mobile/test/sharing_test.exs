defmodule Wotex.Tracker.Mobile.SharingTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.Mobile.{MobScreen, Sharing}

  defmodule Native do
    def text(socket, content) do
      send(self(), {:shared, content})
      Mob.Socket.assign(socket, :shared, true)
    end
  end

  defmodule FailingNative do
    def text(_, _), do: raise("private native share failure")
  end

  defmodule ThrowingNative do
    def text(_, _), do: throw(:private_native_share_failure)
  end

  test "shares only the fixed authorized export contracts" do
    socket = Mob.Socket.new(MobScreen)

    exports = [
      {"wotex-query-result.json", %{"schema" => "wtr.query-result.v1"}},
      {"wotex-history-page.json", %{"schema" => "wtr.history-page-export.v1"}},
      {"wotex-retained-history.json", %{"schema" => "wtr.history-export.v1"}},
      {"wotex-route-page.json", %{"schema" => "wtr.route-page-export.v1"}},
      {"wotex-trip-events.json", %{"schema" => "wtr.trip-event-page-export.v1"}},
      {"wotex-trip-summary.json", %{"schema" => "wtr.trip-summary-export.v1"}},
      {"wotex-native-observation.json", %{"native" => true}},
      {"wotex-raw-evidence.json", [%{"claim" => "public"}]}
    ]

    for {filename, document} <- exports do
      content = Jason.encode!(document)

      assert %{assigns: %{shared: true}} =
               Sharing.share(socket, payload(filename, content), Native)

      assert_received {:shared, ^content}
    end
  end

  test "rejects widened or malformed share requests and contains native failures" do
    socket = Mob.Socket.new(MobScreen)
    valid = payload("wotex-route-page.json", ~s({"schema":"wtr.route-page-export.v1"}))

    invalid = [
      %{},
      Map.put(valid, "extra", "field"),
      %{valid | "schema" => "other"},
      %{valid | "filename" => "arbitrary.json"},
      %{valid | "media_type" => "text/plain"},
      %{valid | "content" => "not-json"},
      %{valid | "content" => ~s({"schema":"wrong"})},
      payload("wotex-native-observation.json", "42"),
      payload("wotex-native-observation.json", <<255>>),
      payload("wotex-native-observation.json", String.duplicate("x", 1_048_577))
    ]

    for request <- invalid do
      assert Sharing.share(socket, request, Native) == socket
    end

    assert Sharing.share(socket, valid, FailingNative) == socket
    assert Sharing.share(socket, valid, ThrowingNative) == socket
    assert Sharing.share(socket, valid, 42) == socket
    refute_received {:shared, _}
  end

  defp payload(filename, content) do
    %{
      "schema" => "wtr.mobile-share.v1",
      "filename" => filename,
      "media_type" => "application/json",
      "content" => content
    }
  end
end
