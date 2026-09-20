defmodule Wotex.Tracker.IntegratedProductDevelopment do
  @moduledoc false

  alias Wotex.Tracker.Mobile.{Cache, Client, CredentialManager, RemoteTransport}
  alias Wotex.Tracker.Mobile.Development.NativeSimulator

  alias Wotex.Tracker.Service.{
    Codec,
    Credentials,
    Identifier,
    PassiveAdvertisement,
    PassiveIngress,
    PassiveScanner
  }

  alias Wotex.Tracker.Service.Development.PassiveSimulator
  alias Wotex.Tracker.Service.HTTP.{Config, Server}
  alias Wotex.Tracker.UI.{Local, Remote, RemoteMintTransport, Sessions}

  @now 1_700_000_000_000
  @scope "workshop"
  @payload Base.decode16!("0512FC5394C37C0004FFFC040CAC364200CDCBB8334C884F")

  def main do
    {:ok, _} = Application.ensure_all_started(:wotex_tracker_mobile)
    directory = temporary_directory!()
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)

    try do
      native_protocol!(supervisor, Path.join(directory, "native-protocol"))
      report = run!(supervisor, directory)
      IO.puts("INTEGRATED_PRODUCT_SIMULATOR_PASS " <> Jason.encode!(report))
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      File.rm_rf!(directory)
    end
  end

  defp native_protocol!(supervisor, directory) do
    credentials = credentials!()
    port = available_port!()
    directory = private_directory!(directory)
    service_directory = private_directory!(Path.join(directory, "service"))
    server = start_server!(supervisor, server_options(service_directory, credentials, port))
    descriptor = Path.join(directory, "descriptor.json")

    File.write!(
      descriptor,
      Codec.encode!(%{
        "url" => "http://127.0.0.1:#{port}",
        "scope" => @scope,
        "token" => credentials.admin.token,
        "reader" => credentials.reader.token
      })
    )

    File.chmod!(descriptor, 0o600)

    {output, status} =
      System.cmd(native_consumer_executable!(), [descriptor], stderr_to_stdout: true)

    File.rm!(descriptor)
    stop_child(supervisor, server)

    expect!(
      status == 0 and String.contains?(output, "NATIVE_PROTOCOL_PASS"),
      "Zig protocol consumer: #{String.trim(output)}"
    )
  end

  defp run!(supervisor, directory) do
    credentials = credentials!()
    port = available_port!()
    service_directory = private_directory!(Path.join(directory, "service"))
    mobile_directory = private_directory!(Path.join(directory, "mobile"))
    options = server_options(service_directory, credentials, port)
    server = start_server!(supervisor, options)
    service = service!(server, options)
    service_ref = start_child!(supervisor, {Agent, fn -> service end})
    origin = "http://127.0.0.1:#{port}"
    web = remote!(origin)
    mobile_remote = mobile_remote!(origin)
    provider = fn -> Agent.get(service_ref, &{:ok, &1}) end
    %{admin: admin, reader: reader} = credentials

    capture = capture()
    {ingress, scanner} = scan!(supervisor, service, admin, capture)
    scanner_status = await_scanner!(scanner)
    expect!(scanner_status.accepted == 1 and scanner_status.duplicate == 1, "passive replay")

    observation =
      web
      |> request!(admin, :list, %{"resource" => "observations", "params" => %{}})
      |> one_item!("observation")

    enrolled =
      request!(web, admin, :enroll, %{
        "operation" => Identifier.uuid(),
        "request" => %{
          "observation_id" => observation["id"],
          "title" => "Integrated development sensor",
          "owner_confirmed" => true,
          "expected_generation" => "1"
        }
      })

    thing = get_in(enrolled, ["data", "thing_id"])
    expect!(is_binary(thing), "enrollment Thing identity")

    materialized =
      request!(web, admin, :materialize, %{
        "operation" => Identifier.uuid(),
        "request" => %{"thing_id" => thing, "expected_generation" => "2"}
      })

    expect!(materialized["generation"] == "3", "materialization generation")

    web_sessions =
      start_child!(supervisor, {Sessions, client: {Remote, web}, clock: fn -> @now end})

    pi_sessions =
      start_child!(supervisor, {Sessions, client: {Local, provider}, clock: fn -> @now end})

    web_session = login!(web_sessions, reader)
    pi_session = login!(pi_sessions, reader)
    property_arguments = %{"thing" => thing, "name" => "temperature"}

    expect!(
      session_request!(web_sessions, web_session, :read_property, property_arguments) ==
        %{"value" => 24.3, "generation" => "3"},
      "web Property"
    )

    expect!(
      session_request!(pi_sessions, pi_session, :read_property, property_arguments) ==
        %{"value" => 24.3, "generation" => "3"},
      "Pi Property"
    )

    credential_origin = String.replace_prefix(origin, "http://", "https://")

    {mobile, manager, mobile_credential} =
      mobile!(supervisor, mobile_directory, mobile_remote, credential_origin, reader)

    list_arguments = %{"resource" => "enrollments", "params" => %{}}
    mobile_list = mobile_request!(mobile, reader, :list, list_arguments)
    expect!(item?(mobile_list, thing), "mobile live projection")
    :ok = NativeSimulator.subscribe([:app, :network])

    stop_child(supervisor, scanner)
    stop_child(supervisor, ingress)
    stop_child(supervisor, server)
    :ok = NativeSimulator.emit(:offline)
    expect_message!({:mob_device, :connectivity_changed, %{online: false}})

    expect!(
      session_error(web_sessions, web_session, :read_property, property_arguments) ==
        "storage_unavailable",
      "web disconnect"
    )

    offline = mobile_request!(mobile, reader, :list, list_arguments)
    expect!(get_in(offline, ["_offline", "source"]) == "offline_cache", "mobile offline cache")
    expect!(item?(offline, thing), "mobile cached Thing")

    server = start_server!(supervisor, options)
    service = service!(server, options)
    Agent.update(service_ref, fn _ -> service end)
    :ok = NativeSimulator.emit(:online)
    expect_message!({:mob_device, :connectivity_changed, %{online: true}})

    expect!(
      session_request!(web_sessions, web_session, :read_property, property_arguments) ==
        %{"value" => 24.3, "generation" => "3"},
      "web restart recovery"
    )

    expect!(
      session_request!(pi_sessions, pi_session, :read_property, property_arguments) ==
        %{"value" => 24.3, "generation" => "3"},
      "Pi restart recovery"
    )

    expect!(
      item?(mobile_request!(mobile, reader, :list, list_arguments), thing),
      "mobile reconnect"
    )

    duplicate_ingress =
      start_child!(
        supervisor,
        {PassiveIngress,
         service: service,
         token: admin.token,
         scope: @scope,
         adapter: "integrated-passive-simulator"}
      )

    admitted = ok!(PassiveAdvertisement.new(capture), "passive advertisement")
    duplicate = ok!(PassiveIngress.submit(duplicate_ingress, admitted), "durable duplicate")
    expect!(duplicate.disposition == :duplicate, "duplicate after restart")
    stop_child(supervisor, duplicate_ingress)

    state = request!(web, admin, :list, %{"resource" => "state", "params" => %{}})
    expect!(state["generation"] == "3", "duplicate generation")

    revoked =
      request!(web, admin, :revoke, %{
        "operation" => Identifier.uuid(),
        "request" => %{"credential_id" => "reader", "expected_generation" => "3"}
      })

    expect!(revoked["generation"] == "4", "revocation generation")

    expect!(
      session_error(web_sessions, web_session, :read_property, property_arguments) ==
        "unauthorized",
      "web revocation"
    )

    expect!(
      session_error(pi_sessions, pi_session, :read_property, property_arguments) == "unauthorized",
      "Pi revocation"
    )

    expect!(
      mobile_error(mobile, reader, :list, list_arguments) == "unauthorized",
      "mobile revocation"
    )

    :ok = CredentialManager.release(manager, mobile_credential)
    expect!(CredentialManager.status(manager).credential == false, "mobile credential purge")

    history =
      request!(web, admin, :history, %{"resource" => "things", "id" => thing, "params" => %{}})

    expect!(Enum.any?(history["items"], &(&1["generation"] == "3")), "durable Thing history")
    privacy = request!(web, admin, :privacy, %{})
    expect!(get_in(privacy, ["retained", "action_intents"]) == 0, "physical Action absence")

    operator_context = request!(mobile_remote, admin, :session_context, %{})
    operator_credential = credential(admin.token, operator_context["access"])
    :ok = CredentialManager.retain(manager, operator_credential)

    expect!(
      item?(mobile_request!(mobile, admin, :list, list_arguments), thing),
      "mobile recovery"
    )

    native_output = native_consumer!(directory, origin, admin.token, reader.token, thing)
    expect!(String.contains?(native_output, "NATIVE_INTEGRATED_PASS"), "native consumer")

    %{
      "schema" => "wtr.integrated-product-development.v1",
      "evidence_class" => "simulator",
      "surfaces" => %{
        "web_remote" => "pass",
        "pi_local" => "pass",
        "mobile_native_cache" => "pass",
        "non_elixir_http" => "pass"
      },
      "recovery" => %{
        "service_restart" => "pass",
        "network_disconnect" => "pass",
        "credential_revocation" => "pass",
        "durable_history" => "pass"
      },
      "ingress" => %{"accepted" => 1, "duplicate" => 2, "generation_delta" => 1},
      "physical_actions" => %{"configured" => false, "intents" => 0},
      "budgets" => %{
        "passive_captures_in_flight" => 1,
        "service_connections" => 16,
        "mobile_cache_entries" => 32,
        "native_response_bytes" => 4_194_304
      }
    }
  end

  defp credentials! do
    admin_token = Credentials.generate_token()
    reader_token = Credentials.generate_token()
    {:ok, admin_digest} = Credentials.token_digest(admin_token)
    {:ok, reader_digest} = Credentials.token_digest(reader_token)

    value =
      ok!(
        Credentials.new(%{
          instance_id: "integrated-development",
          secret_key: :crypto.strong_rand_bytes(32),
          entries: [
            %{
              id: "operator",
              principal: "owner",
              token_sha256: admin_digest,
              grants: %{@scope => ~w(admin enroll ingest interact raw read)},
              expires_at: 9_007_199_254_740_991
            },
            %{
              id: "reader",
              principal: "viewer",
              token_sha256: reader_digest,
              grants: %{@scope => ["read"]},
              expires_at: 9_007_199_254_740_991
            }
          ]
        }),
        "credentials"
      )

    %{value: value, admin: %{token: admin_token}, reader: %{token: reader_token}}
  end

  defp server_options(directory, credentials, port) do
    [
      directory: directory,
      credentials: credentials.value,
      ip: {127, 0, 0, 1},
      port: port,
      public_origin: :listener,
      exposure: :loopback,
      clock: fn -> @now end,
      store_options: [max_rows: 1_000, max_pages: 1_024]
    ]
  end

  defp start_server!(supervisor, options, attempts \\ 20)
  defp start_server!(_supervisor, _options, 0), do: raise("service restart failed")

  defp start_server!(supervisor, options, attempts) do
    case start_child(supervisor, {Server, options}) do
      {:ok, server} ->
        server

      {:error, reason} when attempts == 1 ->
        raise "service restart failed: #{inspect(reason)}"

      {:error, _reason} ->
        Process.sleep(10)
        start_server!(supervisor, options, attempts - 1)
    end
  end

  defp service!(server, options) do
    config = ok!(Config.new(options), "service configuration")
    ok!(Server.context(server, config), "service context")
  end

  defp scan!(supervisor, service, admin, capture) do
    ingress =
      start_child!(
        supervisor,
        {PassiveIngress,
         service: service,
         token: admin.token,
         scope: @scope,
         adapter: "integrated-passive-simulator"}
      )

    scanner =
      start_child!(
        supervisor,
        {PassiveScanner,
         adapter: {PassiveSimulator, [capture, capture]},
         ingress: ingress,
         interval_ms: 0,
         timeout_ms: 1_000}
      )

    {ingress, scanner}
  end

  defp await_scanner!(scanner, attempts \\ 100)
  defp await_scanner!(_scanner, 0), do: raise("passive scanner did not finish")

  defp await_scanner!(scanner, attempts) do
    status = PassiveScanner.status(scanner)

    if status.lifecycle == :stopped do
      status
    else
      Process.sleep(10)
      await_scanner!(scanner, attempts - 1)
    end
  end

  defp mobile!(supervisor, directory, remote, origin, reader) do
    _native = start_child!(supervisor, {NativeSimulator, []})

    cache =
      start_child!(
        supervisor,
        {Cache,
         directory: directory,
         max_entries: 32,
         max_bytes: 1_048_576,
         max_entry_bytes: 262_144,
         max_age_ms: 86_400_000}
      )

    sessions =
      start_child!(supervisor, {Sessions, client: {Remote, remote}, clock: fn -> @now end})

    manager =
      start_child!(
        supervisor,
        {CredentialManager,
         sessions: sessions,
         cache: cache,
         origin: origin,
         secure_store: {Wotex.Mobile.SecureStore, NativeSimulator},
         clock: fn -> @now end}
      )

    context = request!(remote, reader, :session_context, %{})
    stored = credential(reader.token, context["access"])
    :ok = CredentialManager.retain(manager, stored)
    {Client.new(remote, manager), manager, stored}
  end

  defp credential(token, access) do
    %{
      token: token,
      scope: @scope,
      access: access,
      session_id: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    }
  end

  defp remote!(origin),
    do: ok!(Remote.new(origin: origin, allow_loopback: true), "web remote")

  defp mobile_remote!(origin) do
    transport =
      {RemoteTransport,
       %{
         resolver: {Wotex.Tracker.Mobile.Resolver, nil},
         transport: {RemoteMintTransport, nil}
       }}

    ok!(
      Remote.new(origin: origin, allow_loopback: true, transport: transport),
      "mobile remote"
    )
  end

  defp request!(remote, credential, action, arguments) do
    ok!(
      Remote.request(remote, credential.token, @scope, action, arguments, @now),
      Atom.to_string(action)
    )
  end

  defp login!(sessions, credential) do
    result = ok!(Sessions.login(sessions, credential.token, @scope), "surface login")
    result["id"] || raise("surface login returned no session")
  end

  defp session_request!(sessions, id, action, arguments),
    do: ok!(Sessions.request(sessions, id, action, arguments), Atom.to_string(action))

  defp session_error(sessions, id, action, arguments) do
    case Sessions.request(sessions, id, action, arguments) do
      {:error, %{"code" => code}} -> code
      _ -> raise("surface request did not fail closed")
    end
  end

  defp mobile_request!(client, credential, action, arguments),
    do:
      ok!(
        Client.request(client, credential.token, @scope, action, arguments, @now + 1),
        "mobile #{action}"
      )

  defp mobile_error(client, credential, action, arguments) do
    case Client.request(client, credential.token, @scope, action, arguments, @now + 1) do
      {:error, %{"code" => code}} -> code
      _ -> raise("mobile request did not fail closed")
    end
  end

  defp native_consumer!(directory, origin, token, revoked, thing) do
    executable = native_consumer_executable!()
    descriptor = Path.join(directory, "native-integrated.json")

    File.write!(
      descriptor,
      Codec.encode!(%{
        "mode" => "integrated_product",
        "url" => origin,
        "scope" => @scope,
        "token" => token,
        "revoked" => revoked,
        "thing" => thing,
        "generation" => "4",
        "history_generation" => "3"
      })
    )

    File.chmod!(descriptor, 0o600)
    {output, status} = System.cmd(executable, [descriptor], stderr_to_stdout: true)
    File.rm!(descriptor)
    expect!(status == 0, "Zig consumer execution: #{String.trim(output)}")
    output
  end

  defp native_consumer_executable! do
    root = Path.expand("../../..", __DIR__)

    executable =
      Path.join(
        root,
        "_build/native/protocol-consumer/darwin/bin/wotex-tracker-protocol-consumer"
      )

    expect!(File.regular?(executable), "built Zig consumer")
    executable
  end

  defp capture do
    %{
      id: "integrated-ruuvi-capture",
      observed_at: @now,
      receiver: "pi-development-simulator",
      address: "private-address-one",
      address_type: :random_private_resolvable,
      manufacturer_id: 1_177,
      payload: @payload,
      rssi: -42,
      provenance: %{
        "evidence_class" => "simulator",
        "scenario" => "integrated-product-development"
      }
    }
  end

  defp one_item!(%{"generation" => "1", "items" => [item]}, _name), do: item
  defp one_item!(_, name), do: raise("expected one #{name}")

  defp item?(%{"items" => items}, id) when is_list(items),
    do: Enum.any?(items, &(&1["id"] == id))

  defp item?(_, _), do: false

  defp expect_message!(message) do
    receive do
      ^message -> :ok
    after
      1_000 -> raise("native lifecycle event was not delivered")
    end
  end

  defp ok!({:ok, value}, _name), do: value
  defp ok!({:error, %{"code" => code}}, name), do: raise("#{name} failed: #{code}")
  defp ok!(_, name), do: raise("#{name} failed")

  defp expect!(true, _name), do: :ok
  defp expect!(false, name), do: raise("#{name} failed")

  defp start_child!(supervisor, child) do
    case start_child(supervisor, child) do
      {:ok, pid} -> pid
      {:error, _} -> raise("development child failed to start")
    end
  end

  defp start_child(supervisor, child) do
    spec = Supervisor.child_spec(child, restart: :temporary)
    DynamicSupervisor.start_child(supervisor, spec)
  end

  defp stop_child(supervisor, pid) do
    if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid), else: :ok
  end

  defp temporary_directory! do
    directory =
      Path.expand(
        "_build/integrated-product/#{System.unique_integer([:positive])}",
        File.cwd!()
      )

    File.mkdir_p!(Path.dirname(directory))
    private_directory!(directory)
  end

  defp private_directory!(directory) do
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end

  defp available_port! do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end

Wotex.Tracker.IntegratedProductDevelopment.main()
