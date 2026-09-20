defmodule Wotex.Tracker.Mobile.NotificationRegistrationTest do
  @moduledoc false

  use ExUnit.Case, async: true
  alias Wotex.Tracker.Mobile.{MobScreen, NotificationRegistration, Notifications}

  @operation ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defmodule Credentials do
    def notification_context(agent), do: Agent.get(agent, & &1)
  end

  defmodule Sessions do
    def request(agent, session_id, action, arguments) do
      Agent.get_and_update(agent, fn state ->
        call = %{session_id: session_id, action: action, arguments: arguments}

        result =
          case action do
            :list ->
              {:ok, %{"generation" => state.generation, "items" => state.items}}

            _ ->
              state.result
          end

        {result, %{state | calls: [call | state.calls]}}
      end)
    end
  end

  defmodule Permissions do
    def request(socket, capability) do
      send(self(), {:permission_requested, capability})
      Mob.Socket.assign(socket, :permission_requested, true)
    end
  end

  defmodule Notify do
    def register_push(socket) do
      send(self(), :push_registration_requested)
      Mob.Socket.assign(socket, :push_registration_requested, true)
    end
  end

  defmodule WebView do
    def eval_js(socket, script) do
      send(self(), {:notification_navigation, script})
      Mob.Socket.assign(socket, :notification_navigation, true)
    end
  end

  defmodule FailingNative do
    def request(_, _), do: raise("private permission failure")
    def register_push(_), do: throw(:private_push_failure)
    def eval_js(_, _), do: raise("private webview failure")
  end

  defmodule InvalidNative do
    def request(_, _), do: :not_a_socket
    def eval_js(_, _), do: throw(:private_webview_failure)
  end

  setup do
    credentials = start_supervised!({Agent, fn -> context() end})

    sessions =
      start_supervised!(
        Supervisor.child_spec(
          {Agent,
           fn ->
             %{
               generation: "4",
               items: [],
               result: {:ok, %{"outcome" => "committed"}},
               calls: []
             }
           end},
          id: :notification_sessions
        )
      )

    registrar =
      start_supervised!(
        {NotificationRegistration,
         sessions: {Sessions, sessions},
         credentials: {Credentials, credentials},
         app_id: "org.wotex.tracker",
         environment: "sandbox"}
      )

    %{credentials: credentials, registrar: registrar, sessions: sessions}
  end

  test "registers and rotates one installation-bound token without retaining it", c do
    token = "private-apns-token"
    assert :ok = NotificationRegistration.register(c.registrar, :ios, token)
    assert %{state: :registered} = NotificationRegistration.status(c.registrar)

    [list, register] = calls(c.sessions)
    assert list.action == :list
    assert list.session_id == "browser-session"
    assert register.action == :register_notification_endpoint

    assert %{
             "operation" => operation,
             "request" => %{
               "id" => "ios-installation",
               "provider" => "apns",
               "app_id" => "org.wotex.tracker",
               "environment" => "sandbox",
               "token" => ^token,
               "expected_generation" => "4"
             }
           } = register.arguments

    assert operation =~ @operation
    refute inspect(:sys.get_status(c.registrar)) =~ token
    refute inspect(NotificationRegistration.status(c.registrar)) =~ token

    Agent.update(c.sessions, &%{&1 | generation: "5", result: {:ok, %{"outcome" => "unknown"}}})
    assert :ok = NotificationRegistration.register(c.registrar, :ios, token <> "-rotated")
    assert %{state: :unknown} = NotificationRegistration.status(c.registrar)
  end

  test "removes only an existing endpoint and contains malformed or unavailable work", c do
    Agent.update(c.sessions, &%{&1 | generation: "7", items: [%{"id" => "ios-installation"}]})
    assert :ok = NotificationRegistration.unregister(c.registrar)
    assert %{state: :removed} = NotificationRegistration.status(c.registrar)

    [remove | _] = calls(c.sessions) |> Enum.reverse()
    assert remove.action == :unregister_notification_endpoint

    assert remove.arguments["request"] == %{
             "id" => "ios-installation",
             "expected_generation" => "7"
           }

    assert remove.arguments["operation"] =~ @operation
    refute inspect(remove.arguments) =~ "token"

    Agent.update(c.sessions, &%{&1 | generation: "8", items: [], calls: []})
    assert :ok = NotificationRegistration.unregister(c.registrar)
    assert %{state: :absent} = NotificationRegistration.status(c.registrar)
    assert [%{action: :list}] = calls(c.sessions)

    Agent.update(c.sessions, &%{&1 | calls: []})
    assert :ok = NotificationRegistration.register(c.registrar, :android, "ignored")
    assert [] == calls(c.sessions)
    assert :ok = NotificationRegistration.register(c.registrar, :ios, "invalid token")
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)
    assert [] == calls(c.sessions)

    Agent.update(c.credentials, fn _ -> {:error, :unavailable} end)
    assert :ok = NotificationRegistration.register(c.registrar, :ios, "valid-token")
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)

    Agent.update(c.credentials, fn _ -> context() end)
    assert :ok = NotificationRegistration.retry(c.registrar)
    assert %{state: :registered} = NotificationRegistration.status(c.registrar)
  end

  test "rejects malformed endpoint pages and contains remote failures", c do
    Agent.update(c.sessions, &%{&1 | items: [%{"id" => "another-installation"}]})
    assert :ok = NotificationRegistration.unregister(c.registrar)
    assert %{state: :absent} = NotificationRegistration.status(c.registrar)

    Agent.update(c.sessions, &%{&1 | generation: "not-a-generation"})
    assert :ok = NotificationRegistration.register(c.registrar, :ios, "valid-token")
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)

    Agent.update(c.sessions, &%{&1 | generation: 4})
    assert :ok = NotificationRegistration.retry(c.registrar)
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)

    Agent.update(c.sessions, &%{&1 | generation: "4", result: {:error, :offline}})
    assert :ok = NotificationRegistration.retry(c.registrar)
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)

    Agent.update(c.sessions, &%{&1 | result: {:ok, %{}}})
    assert :ok = NotificationRegistration.retry(c.registrar)
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)

    assert :ok = NotificationRegistration.register(c.registrar, :ios, :not_a_token)
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)

    Agent.update(c.credentials, fn _ -> {:error, :unavailable} end)
    assert :ok = NotificationRegistration.unregister(c.registrar)
    assert %{state: :unavailable} = NotificationRegistration.status(c.registrar)
  end

  test "rejects widened registration configuration", c do
    for options <- [
          [],
          [
            sessions: {Sessions, c.sessions},
            credentials: {Credentials, c.credentials},
            app_id: "invalid",
            environment: "sandbox"
          ],
          [
            sessions: {Sessions, c.sessions},
            credentials: {Credentials, c.credentials},
            app_id: "org.wotex.tracker",
            environment: "other"
          ],
          [
            sessions: {String, c.sessions},
            credentials: {Credentials, c.credentials},
            app_id: "org.wotex.tracker",
            environment: "sandbox"
          ]
        ] do
      assert {:error, :invalid_configuration} = NotificationRegistration.start_link(options)
    end

    assert {:error, :invalid_configuration} = NotificationRegistration.start_link(:invalid)
    assert %{state: :unavailable} = NotificationRegistration.status(:missing_registrar)
    assert :ok = NotificationRegistration.unregister(:missing_registrar)
  end

  test "contains native permission APIs and routes only an exact opaque reference" do
    socket = Mob.Socket.new(MobScreen)

    assert %{assigns: %{permission_requested: true}} =
             Notifications.request_permission(socket, Permissions)

    assert_received {:permission_requested, :notifications}

    assert %{assigns: %{push_registration_requested: true}} =
             Notifications.register_push(socket, Notify)

    assert_received :push_registration_requested

    payload = %{
      source: :push,
      data: %{schema: "wtr.notification-reference.v1", event_ref: "alert/one"}
    }

    assert %{assigns: %{notification_navigation: true}} =
             Notifications.route(socket, payload, WebView)

    assert_received {:notification_navigation,
                     ~s|window.location.assign("/protection/alerts/alert%2Fone")|}

    assert %{assigns: %{notification_navigation: true}} =
             Notifications.route(
               socket,
               %{
                 "data" => %{
                   "schema" => "wtr.notification-reference.v1",
                   "event_ref" => "old-alert"
                 }
               },
               WebView
             )

    for invalid <- [
          %{},
          %{data: %{schema: "wrong", event_ref: "alert"}},
          %{data: %{schema: "wtr.notification-reference.v1", event_ref: ""}},
          %{
            data: %{
              schema: "wtr.notification-reference.v1",
              event_ref: "alert",
              location: "private"
            }
          }
        ] do
      assert Notifications.route(socket, invalid, WebView) == socket
    end

    assert Notifications.request_permission(socket, FailingNative) == socket
    assert Notifications.register_push(socket, FailingNative) == socket
    assert Notifications.route(socket, payload, FailingNative) == socket
    assert Notifications.request_permission(socket, InvalidNative) == socket
    assert Notifications.route(socket, payload, InvalidNative) == socket

    assert Notifications.route(
             socket,
             %{data: %{schema: "wtr.notification-reference.v1", event_ref: <<255>>}},
             WebView
           ) == socket

    assert Notifications.route(
             socket,
             %{data: %{schema: "wtr.notification-reference.v1", event_ref: 42}},
             WebView
           ) == socket

    assert :ok = Notifications.register_endpoint("token", self())
    assert_receive {:"$gen_cast", {:register, "token"}}
    assert :ok = Notifications.unregister_endpoint(self())
    assert_receive {:"$gen_cast", :unregister}
    assert :ok = Notifications.retry_registration(self())
    assert_receive {:"$gen_cast", :retry}

    assert :ok = Notifications.register_endpoint("token", 42)
    assert :ok = Notifications.unregister_endpoint(42)
    assert :ok = Notifications.retry_registration(42)
  end

  test "pins and activates the signed iOS notification plugin manifest" do
    manifest_path = Application.app_dir(:mob_notify, "priv/mob_plugin.exs")
    {manifest, _} = Code.eval_file(manifest_path)

    assert Application.spec(:mob_notify, :vsn) == ~c"0.1.2"
    assert Application.get_env(:mob, :plugins) == [:mob_notify, :wotex_mobile_secure_store]
    assert manifest.name == :mob_notify
    assert manifest.plugin_spec_version == 1
    assert manifest.ios.frameworks == ["UserNotifications"]

    assert Enum.any?(manifest.nifs, fn nif ->
             match?(%{module: :mob_notify_nif, lang: :objc, platform: :ios}, nif)
           end)

    assert Enum.any?(manifest.host_requirements, &String.contains?(&1, "mob_send_push_token"))
    assert File.regular?(Application.app_dir(:mob_notify, "priv/mob_plugin.pub"))
    assert File.regular?(Application.app_dir(:mob_notify, "priv/mob_plugin.sig"))
  end

  defp context,
    do: {:ok, %{session_id: "browser-session", endpoint_id: "ios-installation"}}

  defp calls(agent), do: agent |> Agent.get(& &1.calls) |> Enum.reverse()
end
