defmodule Wotex.Tracker.Host.Browser.RenderTelemetryTest do
  use ExUnit.Case, async: false

  alias Wotex.Tracker.Host.Browser.RenderTelemetry
  alias Wotex.Tracker.Host.Browser.Endpoint
  alias Wotex.Tracker.Service.OperationalHistory

  @stop [:phoenix, :live_view, :render, :stop]
  @exception [:phoenix, :live_view, :render, :exception]
  @connection [:phoenix, :socket_connected]

  test "browser renders record only fixed metadata and ignore unrelated views and components" do
    collector = start_supervised!({OperationalHistory, []})
    _bridge = start_supervised!({RenderTelemetry, []})
    socket = %Phoenix.LiveView.Socket{view: Wotex.Tracker.UI.AnalyticsLive}
    duration = System.convert_time_unit(4_000, :microsecond, :native)

    :telemetry.execute(@stop, %{duration: duration}, %{socket: socket, asset_id: "private"})

    :telemetry.execute(
      @stop,
      %{duration: duration},
      %{socket: socket, component: Wotex.Tracker.UI.Components}
    )

    :telemetry.execute(@stop, %{duration: duration}, %{
      socket: %Phoenix.LiveView.Socket{view: OtherLive},
      asset_id: "private"
    })

    :telemetry.execute(@exception, %{duration: duration}, %{
      socket: socket,
      exception: "private"
    })

    :telemetry.execute(@stop, %{duration: -1}, %{socket: socket})

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [_, _]}},
        OperationalHistory.snapshot(collector, event: "render.stop")
      )
    end)

    assert {:ok, %{"samples" => samples}} =
             OperationalHistory.snapshot(collector, event: "render.stop")

    assert Enum.map(samples, & &1["metadata"]) == [
             %{"surface" => "browser", "outcome" => "ok"},
             %{"surface" => "browser", "outcome" => "unavailable"}
           ]

    assert Enum.map(samples, & &1["measurements"]) == [
             %{"duration_us" => 4_000},
             %{"duration_us" => 4_000}
           ]

    stop_supervised!(RenderTelemetry)
    :telemetry.execute(@stop, %{duration: duration}, %{socket: socket})

    assert {:ok, %{"samples" => [_, _]}} =
             OperationalHistory.snapshot(collector, event: "render.stop")
  end

  test "marked reconnects record no socket, route or credential metadata" do
    collector = start_supervised!({OperationalHistory, []})
    _bridge = start_supervised!({RenderTelemetry, []})
    duration = System.convert_time_unit(3_000, :microsecond, :native)

    base = %{
      endpoint: Endpoint,
      log: false,
      user_socket: Phoenix.LiveView.Socket,
      params: %{
        "wotex_reconnect" => "1",
        "_csrf_token" => "private-token",
        "path" => "/private/path"
      }
    }

    :telemetry.execute(@connection, %{duration: duration}, Map.put(base, :result, :ok))
    :telemetry.execute(@connection, %{duration: duration}, Map.put(base, :result, :error))

    :telemetry.execute(
      @connection,
      %{duration: duration},
      base |> put_in([:params, "wotex_reconnect"], "0") |> Map.put(:result, :ok)
    )

    :telemetry.execute(
      @connection,
      %{duration: duration},
      base |> Map.put(:endpoint, OtherEndpoint) |> Map.put(:result, :ok)
    )

    :telemetry.execute(@connection, %{duration: -1}, Map.put(base, :result, :ok))

    eventually(fn ->
      match?(
        {:ok, %{"samples" => [_, _]}},
        OperationalHistory.snapshot(collector, event: "connection.stop")
      )
    end)

    assert {:ok, %{"samples" => samples}} =
             OperationalHistory.snapshot(collector, event: "connection.stop")

    assert Enum.map(samples, & &1["metadata"]) == [
             %{"surface" => "browser", "kind" => "reconnect", "outcome" => "ok"},
             %{"surface" => "browser", "kind" => "reconnect", "outcome" => "unavailable"}
           ]

    assert Enum.map(samples, & &1["measurements"]) == [
             %{"duration_us" => 3_000},
             %{"duration_us" => 3_000}
           ]
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(5)
      eventually(check, attempts - 1)
    end
  end
end
