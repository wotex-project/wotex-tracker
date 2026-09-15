defmodule Wotex.Tracker.Service.Fixtures do
  @moduledoc false

  alias Wotex.Tracker.Observation
  alias Wotex.Tracker.Service
  alias Wotex.Tracker.Service.{Credentials, Store, Update}

  def directory do
    path = Path.expand("_build/test/stores/#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  def store(options \\ []) do
    directory = Keyword.get_lazy(options, :directory, &directory/0)
    options = Keyword.put(options, :directory, directory)

    pid =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Store, options}, id: make_ref(), restart: :temporary)
      )

    {Store.handle(pid), directory}
  end

  def observation(changes \\ %{}) do
    input =
      Map.merge(
        %{
          id: "observation-1",
          observed_at: 1_700_000_000_000,
          ingress: "ble",
          source: %{"receiver" => "private-receiver"},
          addressing: %{"mac" => "private-hardware"},
          payload: {:bytes, Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")},
          radio: %{"rssi" => -70},
          transport: %{"manufacturer_id" => 1177},
          provenance: %{"kind" => "fixture"}
        },
        changes
      )

    {:ok, observation} = Observation.new(input)
    observation
  end

  def update_input(changes \\ %{}) do
    Map.merge(
      %{
        principal: "operator",
        scope: "workshop",
        operation_id: "operation-1",
        expected_generation: "0",
        request: %{"operation" => "observe", "id" => "observation-1"},
        now: 1_700_000_000_000,
        observation: observation(),
        records: [%{kind: "state", id: "sensor", value: %{"temperature" => 24.3}}],
        events: [%{"type" => "observation.admitted", "data" => %{"id" => "observation-1"}}],
        publication: nil
      },
      changes
    )
  end

  def update(changes \\ %{}) do
    {:ok, update} = Update.new(update_input(changes))
    update
  end

  def query(changes \\ %{}),
    do:
      Map.merge(
        %{scope: "workshop", kind: "state", generation: nil, after: "", limit: 100},
        changes
      )

  def replay(changes \\ %{}),
    do: Map.merge(%{scope: "workshop", after: "0", limit: 100, now: 1_700_000_000_000}, changes)

  def service(options \\ []) do
    {admin_grants, options} =
      Keyword.pop(options, :admin_grants, ~w(read raw ingest enroll admin interact))

    now = 1_700_000_000_000
    admin = Credentials.generate_token()
    reader = Credentials.generate_token()
    {:ok, admin_digest} = Credentials.token_digest(admin)
    {:ok, reader_digest} = Credentials.token_digest(reader)

    {:ok, credentials} =
      Credentials.new(%{
        instance_id: "service-fixture",
        secret_key: :crypto.strong_rand_bytes(32),
        entries: [
          %{
            id: "admin",
            principal: "owner",
            token_sha256: admin_digest,
            grants: %{"workshop" => admin_grants},
            expires_at: now + 1_000_000_000
          },
          %{
            id: "reader",
            principal: "viewer",
            token_sha256: reader_digest,
            grants: %{"workshop" => ~w(read)},
            expires_at: now + 1_000_000_000
          }
        ]
      })

    {store, directory} = store(Keyword.put(options, :credentials, credentials))

    {:ok, service} =
      Service.new(%{store: store, credentials: credentials, base_url: "http://127.0.0.1:45678"})

    %{
      service: service,
      store: store,
      directory: directory,
      credentials: credentials,
      admin: admin,
      reader: reader,
      now: now,
      scope: "workshop"
    }
  end

  def import_request(changes \\ %{}, generation \\ "0") do
    {:ok, document} = Observation.to_map(observation(changes))
    %{"observation" => document, "expected_generation" => generation}
  end
end
