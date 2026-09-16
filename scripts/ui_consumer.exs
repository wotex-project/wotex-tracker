# Isolated production-archive consumer. It imports no repository or host code.
alias Wotex.Tracker.UI.{Presenter, Sessions}

defmodule ArchiveBrowserClient do
  @moduledoc false
  @behaviour Wotex.Tracker.UI.Client

  @impl true
  def request(:fixture, "archive-test-token", "archive", :authorize, %{}, _) do
    {:ok, %{"scope" => "archive", "can_enroll" => false, "can_ingest" => false}}
  end

  def request(:fixture, "archive-test-token", "archive", :list, %{"resource" => "things"}, _) do
    {:ok, %{"items" => [], "generation" => "0", "cursor" => nil}}
  end

  def request(_, _, _, _, _, _), do: {:error, %{"code" => "unauthorized"}}
end

[] = Application.spec(:wotex_tracker_ui, :mod)
false = Code.ensure_loaded?(Wotex.Tracker.Host.Browser)
true = File.regular?(Application.app_dir(:wotex_tracker_ui, "priv/static/tracker.css"))
true = File.regular?(Application.app_dir(:wotex_tracker_ui, "priv/static/tracker.js"))
{:ok, _} = Application.ensure_all_started(:wotex_tracker_ui)

{:ok, sessions} = Sessions.start_link(client: {ArchiveBrowserClient, :fixture})

try do
  {:error, %{"code" => "unauthorized"}} = Sessions.login(sessions, "invalid", "archive")
  {:ok, %{"id" => id}} = Sessions.login(sessions, "archive-test-token", "archive")
  false = String.contains?(id, "archive-test-token")

  {:ok, %{"items" => [], "generation" => "0"}} =
    Sessions.request(sessions, id, :list, %{"resource" => "things"})

  "0" = Presenter.scalar(%{"value" => 0})
  "false" = Presenter.scalar(%{"value" => false})
  "Unavailable" = Presenter.scalar(%{"value" => nil})
  "/assets/urn%3Auuid%3Aasset" = Presenter.path(:asset, "urn:uuid:asset")
  :ok = Sessions.logout(sessions, id)
  {:error, %{"code" => "unauthorized"}} = Sessions.request(sessions, id, :authorize)
  IO.puts("UI_COHORT_PASS inert=true assets=true custody=true denied=true")
after
  GenServer.stop(sessions)
end
