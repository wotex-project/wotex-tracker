defmodule Wotex.Tracker.Mobile.ShellTest do
  @moduledoc false

  use ExUnit.Case, async: false
  alias Wotex.Tracker.Mobile.{Config, ExternalURL, MobApp, MobScreen, WebSession}

  defmodule Device do
    def open_url(url) do
      send(self(), {:opened_external_url, url})
      :ok
    end
  end

  test "builds one capability-bound local WebView with an exact origin allow-list" do
    capability = Config.generate_capability()
    assert {:ok, session} = WebSession.new("http://127.0.0.1:4321", capability)

    assert %{
             url: "http://127.0.0.1:4321/_mobile/bootstrap/" <> ^capability,
             allow: ["http://127.0.0.1:4321/"]
           } = WebSession.target(session)

    refute inspect(session) =~ capability

    socket = Mob.Socket.new(MobScreen)
    assert {:ok, mounted} = MobScreen.mount(%{session: session}, %{}, socket)

    assert %{
             type: :web_view,
             props: %{
               url: "http://127.0.0.1:4321/_mobile/bootstrap/" <> ^capability,
               allow: "http://127.0.0.1:4321/",
               show_url: false
             },
             children: []
           } = MobScreen.render(mounted.assigns)

    assert {:error, :invalid_session} = MobScreen.mount(%{}, %{}, socket)
    assert {:noreply, ^mounted} = MobScreen.handle_info(:untrusted_message, mounted)

    assert {:noreply, ^mounted} =
             MobScreen.handle_info({:webview, :blocked, "javascript:alert(1)"}, mounted)
  end

  test "rejects widened local targets and malformed capabilities" do
    capability = Config.generate_capability()

    for {origin, candidate} <- [
          {"https://127.0.0.1:4321", capability},
          {"http://localhost:4321", capability},
          {"http://0.0.0.0:4321", capability},
          {"http://127.0.0.1:4321/", capability},
          {"http://user@127.0.0.1:4321", capability},
          {"http://127.0.0.1:4321?q=1", capability},
          {"http://127.0.0.1:4321#fragment", capability},
          {"http://127.0.0.1:0", capability},
          {"http://127.0.0.1:4321", "short"}
        ] do
      assert {:error, :invalid_configuration} = WebSession.new(origin, candidate)
    end

    assert {:error, :invalid_configuration} = WebSession.new(nil, nil)
  end

  test "admits only canonical HTTPS URLs for the OS-owned external browser" do
    assert {:ok, "https://example.com/path?q=1#part"} =
             ExternalURL.admit("https://example.com/path?q=1#part")

    for url <- [
          "http://example.com",
          "javascript:alert(1)",
          "file:///private/file",
          "https://user@example.com",
          "https://EXAMPLE.com",
          "https://example.com:443",
          "https://",
          String.duplicate("x", 2_049),
          nil
        ] do
      assert {:error, :invalid_url} = ExternalURL.admit(url)
    end

    assert :ok = MobScreen.open_external_url("https://example.com/path", Device)
    assert_received {:opened_external_url, "https://example.com/path"}
    assert :ok = MobScreen.open_external_url("http://example.com", Device)
    refute_received {:opened_external_url, _}
  end

  test "starts the native entry through contained runtime operations" do
    previous_host = Application.get_env(:wotex_tracker_mobile, :host)

    on_exit(fn ->
      if is_nil(previous_host),
        do: Application.delete_env(:wotex_tracker_mobile, :host),
        else: Application.put_env(:wotex_tracker_mobile, :host, previous_host)
    end)

    assert :ok = MobApp.configure([])
    assert {:error, _} = Wotex.Tracker.Mobile.Application.start(:normal, [])
    assert {:error, :native_runtime_unavailable} = MobApp.start()

    capability = Config.generate_capability()
    {:ok, session} = WebSession.new("http://127.0.0.1:4321", capability)

    operations = [
      install_logger: fn -> :ok end,
      start_application: fn -> {:ok, []} end,
      start_registry: fn -> {:ok, self()} end,
      web_session: fn -> session end,
      start_root: fn received ->
        send(self(), {:started_root, received})
        {:ok, self()}
      end
    ]

    assert {:ok, pid} = MobApp.start(operations)
    assert pid == self()
    assert_received {:started_root, ^session}

    assert {:ok, ^pid} =
             MobApp.start(
               Keyword.put(operations, :start_registry, fn ->
                 {:error, {:already_started, self()}}
               end)
             )

    assert {:error, :registry_failed} =
             MobApp.start(
               Keyword.put(operations, :start_registry, fn -> {:error, :registry_failed} end)
             )

    assert {:error, :native_runtime_unavailable} =
             MobApp.start(Keyword.put(operations, :start_registry, fn -> :invalid end))

    assert {:error, :application_failed} =
             MobApp.start(
               Keyword.put(operations, :start_application, fn ->
                 {:error, :application_failed}
               end)
             )

    assert {:error, :native_runtime_unavailable} =
             MobApp.start(Keyword.put(operations, :web_session, fn -> :invalid end))

    assert {:error, :native_runtime_unavailable} =
             MobApp.start(Keyword.put(operations, :install_logger, fn -> raise "failure" end))

    assert {:error, :native_runtime_unavailable} =
             MobApp.start(Keyword.put(operations, :install_logger, fn -> throw(:failure) end))
  end
end
