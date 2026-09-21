defmodule Wotex.Tracker.Nerves.PanelAcceptance do
  @moduledoc """
  Exercises the shared control panel through the appliance's real loopback HTTP boundary.

  The QEMU kiosk lane uses this finite probe after deterministic ingress. It
  authenticates through the same single-use launch nonce as Cog, materializes
  the fixture asset through the browser session owner, renders every shared
  route, checks the route/analytics/provisioning input surfaces, and restarts
  only the browser supervisor while retaining the service store.
  """

  require Logger

  alias Wotex.Tracker.Nerves.Browser
  alias Wotex.Tracker.Nerves.Browser.{DeviceSession, Endpoint}
  alias Wotex.Tracker.Service.HTTP.Server
  alias Wotex.Tracker.UI.{QueryWindow, RouteViewport, Sessions}

  @enroll_operation "11111111-1111-4111-8111-111111111111"
  @materialize_operation "22222222-2222-4222-8222-222222222222"
  @missing "33333333-3333-4333-8333-333333333333"
  @maximum_document_bytes 1_048_576

  @type report :: %{
          route_count: pos_integer(),
          authenticated_activation: true,
          keyboard_controls: true,
          local_assets: true,
          isolated_restart: true
        }

  @doc "Runs the finite kiosk acceptance probe with explicit private/runtime owners."
  @spec run(keyword()) :: {:ok, report()} | {:error, atom()}
  def run(options) when is_list(options) do
    with {:ok, config} <- configuration(options),
         {:ok, token} <- read_token(config.token_path),
         {:ok, %{"id" => session}} <- Sessions.login(config.sessions, token, config.scope),
         {:ok, observation} <- observation(config.sessions, session),
         {:ok, thing} <- materialize(config.sessions, session, observation),
         {:ok, cookie, nonce} <- activate(config.origin, config.device_session),
         {:ok, documents} <- render_routes(config.origin, cookie, thing, observation),
         :ok <- audit_routes(documents, token, nonce),
         :ok <- input_surfaces(documents),
         :ok <- restart_browser(config, thing, token) do
      Sessions.logout(config.sessions, session)

      {:ok,
       %{
         route_count: map_size(documents),
         authenticated_activation: true,
         keyboard_controls: true,
         local_assets: true,
         isolated_restart: true
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :panel_acceptance_failed}
    end
  rescue
    _ -> {:error, :panel_acceptance_failed}
  catch
    _, _ -> {:error, :panel_acceptance_failed}
  end

  def run(_), do: {:error, :panel_acceptance_failed}

  @doc false
  def routes(thing, observation) when is_binary(thing) and is_binary(observation) do
    thing = segment(thing)
    observation = segment(observation)
    missing = segment(@missing)
    operation = URI.encode_query(%{"operation" => @missing})

    [
      "/safety",
      "/",
      "/setup?" <> operation,
      "/dashboards",
      "/dashboards/compare?" <> operation,
      "/operations",
      "/access",
      "/privacy",
      "/activity",
      "/protection",
      "/protection/alerts",
      "/protection/alerts/" <> missing,
      "/protection/" <> missing,
      "/dashboards/" <> missing,
      "/observations/" <> observation <> "?" <> operation,
      "/assets/" <> thing <> "/observations",
      "/assets/" <> thing <> "/observations/" <> observation <> "?" <> operation,
      "/assets/" <> thing <> "/analytics",
      "/assets/" <> thing <> "/route",
      "/assets/" <> thing <> "/trips/" <> missing,
      "/assets/" <> thing <> "/trips",
      "/assets/" <> thing <> "/arming",
      "/assets/" <> thing <> "/presence",
      "/assets/" <> thing <> "/interactions",
      "/assets/" <> thing <> "/provisioning",
      "/assets/" <> thing <> "/protection?" <> operation,
      "/assets/" <> thing <> "/remove?" <> operation,
      "/assets/" <> thing <> "?" <> operation
    ]
  end

  @doc false
  def audit_document(document, secrets \\ [])

  def audit_document(document, secrets) when is_binary(document) and is_list(secrets) do
    local_assets =
      Regex.scan(~r/(?:src|href)="([^"]+)"/, document, capture: :all_but_first)
      |> List.flatten()
      |> Enum.all?(&(String.starts_with?(&1, "/") or String.starts_with?(&1, "#")))

    if byte_size(document) in 128..@maximum_document_bytes and
         String.contains?(document, "<!DOCTYPE html>") and
         String.contains?(document, ~s(<html lang="en">)) and
         String.contains?(document, ~s(<main id="main")) and
         Regex.match?(~r/<h1(?:\s|>)/, document) and
         String.contains?(document, ~s(href="#main">Skip to content)) and local_assets and
         Enum.all?(secrets, &(not String.contains?(document, &1))) do
      :ok
    else
      {:error, :invalid_render}
    end
  end

  def audit_document(_, _), do: {:error, :invalid_render}

  defp configuration(options) do
    config = %{
      token_path: options[:token_path],
      scope: options[:scope],
      origin: options[:origin],
      sessions: Keyword.get(options, :sessions, Wotex.Tracker.Nerves.Browser.Sessions),
      device_session: Keyword.get(options, :device_session, DeviceSession),
      supervisor: options[:supervisor]
    }

    if Path.type(config.token_path || "") == :absolute and is_binary(config.scope) and
         loopback_origin?(config.origin) and not is_nil(config.supervisor),
       do: {:ok, config},
       else: {:error, :invalid_configuration}
  end

  defp read_token(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 45)) do
      {:ok, <<token::binary-size(43), "\n">>} -> {:ok, token}
      _ -> {:error, :invalid_token}
    end
  end

  defp observation(sessions, session) do
    case Sessions.request(sessions, session, :list, %{
           "resource" => "observations",
           "params" => %{"limit" => 2}
         }) do
      {:ok, %{"items" => [%{"id" => id}]}} when is_binary(id) -> {:ok, id}
      _ -> {:error, :observation_unavailable}
    end
  end

  defp materialize(sessions, session, observation) do
    with {:ok, %{"data" => %{"thing_id" => thing}}} when is_binary(thing) <-
           Sessions.request(sessions, session, :enroll, %{
             "operation" => @enroll_operation,
             "request" => %{
               "observation_id" => observation,
               "title" => "QEMU kiosk cargo-bike tracker",
               "owner_confirmed" => true,
               "expected_generation" => "1"
             }
           }),
         {:ok, %{"outcome" => "committed"}} <-
           Sessions.request(sessions, session, :materialize, %{
             "operation" => @materialize_operation,
             "request" => %{"thing_id" => thing, "expected_generation" => "2"}
           }) do
      {:ok, thing}
    else
      _ -> {:error, :materialization_failed}
    end
  end

  defp activate(origin, device_session) do
    launch = DeviceSession.launch_url(origin, device_session)
    nonce = launch |> URI.parse() |> Map.get(:query) |> decode_nonce()

    with true <- is_binary(nonce) and byte_size(nonce) == 43,
         {:ok, {{_, 303, _}, headers, "See Other\n"}} <- get(launch, nil),
         "/setup" <- header(headers, "location"),
         cookie when is_binary(cookie) <- header(headers, "set-cookie"),
         {:ok, {{_, 404, _}, _, "Not found\n"}} <- get(launch, nil) do
      {:ok, cookie |> String.split(";", parts: 2) |> hd(), nonce}
    else
      _ -> {:error, :activation_failed}
    end
  end

  defp render_routes(origin, cookie, thing, observation) do
    routes(thing, observation)
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, documents} ->
      case get(origin <> path, cookie) do
        {:ok, {{_, 200, _}, headers, body}} when is_binary(body) ->
          if String.starts_with?(header(headers, "content-type") || "", "text/html") do
            {:cont, {:ok, Map.put(documents, path, body)}}
          else
            {:halt, {:error, :invalid_content_type}}
          end

        other ->
          Logger.error("QEMU kiosk route probe failed for #{path}: #{route_failure(other)}")
          {:halt, {:error, :route_failed}}
      end
    end)
  end

  defp audit_routes(documents, token, nonce) do
    if map_size(documents) == 28 and
         Enum.all?(documents, fn {_path, document} ->
           audit_document(document, [token, nonce, "wtrc1."]) == :ok
         end),
       do: :ok,
       else: {:error, :render_audit_failed}
  end

  defp input_surfaces(documents) do
    with {:ok, zoomed} <- RouteViewport.update(RouteViewport.new(), "zoom-in"),
         {:ok, panned} <- RouteViewport.update(zoomed, "pan-left"),
         true <- zoomed != panned,
         {:ok, {21_600_000, 64_800_000}} <- QueryWindow.move("zoom_in", 0, 86_400_000) do
      values = Map.values(documents)

      required = [
        analytics_form: ~s(id="analytics-query"),
        route_form: ~s(id="route-query"),
        tat140_plan: ~s(id="tat140-plan"),
        ble_hook: ~s(phx-hook="TargetBLEHook")
      ]

      missing =
        Enum.reject(required, fn {_name, marker} ->
          Enum.any?(values, &String.contains?(&1, marker))
        end)

      case missing do
        [] ->
          :ok

        _ ->
          names = missing |> Keyword.keys() |> Enum.join(",")
          Logger.error("QEMU kiosk input probe missing #{names}")
          {:error, :input_surface_missing}
      end
    else
      _ -> {:error, :input_model_failed}
    end
  end

  defp restart_browser(config, thing, token) do
    with {:ok, server} <- Server.child(config.supervisor, Server),
         {:ok, store} <- Server.child(server, :store),
         browser when is_pid(browser) <- child(config.supervisor, Browser),
         :ok <- Supervisor.terminate_child(config.supervisor, Browser),
         false <- Process.alive?(browser),
         true <- Process.alive?(store),
         {:ok, restarted} when is_pid(restarted) and restarted != browser <-
           Supervisor.restart_child(config.supervisor, Browser),
         {:ok, ^store} <- Server.child(server, :store),
         {:ok, cookie, nonce} <- activate(config.origin, config.device_session),
         {:ok, {{_, 200, _}, _, document}} <-
           get(config.origin <> "/assets/" <> segment(thing) <> "?operation=" <> @missing, cookie),
         :ok <- audit_document(document, [token, nonce, "wtrc1."]),
         {:ok, {_ip, _port}} <- Endpoint.server_info(:http) do
      :ok
    else
      _ -> {:error, :browser_restart_failed}
    end
  end

  defp child(supervisor, id) do
    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      {^id, pid, :supervisor, _} -> pid
      _ -> nil
    end
  end

  defp get(url, cookie) do
    headers = if cookie, do: [{~c"cookie", String.to_charlist(cookie)}], else: []

    :httpc.request(
      :get,
      {String.to_charlist(url), headers},
      [timeout: 5_000, autoredirect: false],
      body_format: :binary
    )
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp route_failure({:ok, {{_, status, _}, _, _}}), do: "HTTP #{status}"
  defp route_failure({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp route_failure(_), do: "invalid response"

  defp decode_nonce(nil), do: nil

  defp decode_nonce(query) do
    case URI.decode_query(query) do
      %{"nonce" => nonce} -> nonce
      _ -> nil
    end
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp loopback_origin?(origin) do
    case URI.parse(origin || "") do
      %URI{scheme: "http", host: host, port: port, path: path, query: nil, fragment: nil}
      when host in ["127.0.0.1", "localhost"] and port in 1..65_535 and path in [nil, ""] ->
        true

      _ ->
        false
    end
  end
end
