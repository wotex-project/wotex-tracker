defmodule Wotex.Tracker.ReleaseProcess do
  @moduledoc false
  use GenServer

  def start_link(executable, environment, log),
    do: GenServer.start_link(__MODULE__, {executable, environment, log})

  def status(process), do: GenServer.call(process, :status)
  def os_pid(process), do: GenServer.call(process, :os_pid)
  def drain(process), do: GenServer.call(process, :drain)

  @impl true
  def init({executable, environment, log}) do
    {:ok, file} = File.open(log, [:append, :binary])

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start"],
        env:
          Enum.map(environment, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
      ])

    {:ok, %{port: port, file: file, status: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:os_pid, _from, state) do
    {:os_pid, pid} = Port.info(state.port, :os_pid)
    {:reply, pid, state}
  end

  def handle_call(:drain, _from, state) do
    :ok = :file.sync(state.file)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({_port, {:data, bytes}}, state) do
    :ok = IO.binwrite(state.file, bytes)
    {:noreply, state}
  end

  def handle_info({_port, {:exit_status, status}}, state) do
    :ok = :file.sync(state.file)
    {:noreply, %{state | status: status}}
  end

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    File.close(state.file)
  end
end

defmodule Wotex.Tracker.ReleaseProbe do
  @moduledoc false

  alias Wotex.Tracker.HTTPConsumer
  alias Wotex.Tracker.ReleaseProcess
  alias Wotex.Tracker.Service.{Codec, Identifier}

  @scope "workshop"
  @body_limit 4_194_304

  def main(arguments) do
    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [readonly_directory: :string, native_consumer: :string, browser: :boolean]
      )

    unless invalid == [] and length(rest) == 2,
      do:
        raise(
          "usage: release_probe.exs RELEASE FIXTURES [--readonly-directory PATH] [--native-consumer PATH] [--browser]"
        )

    [release, fixtures] = Enum.map(rest, &Path.expand/1)
    assert_clean_path!()
    assert_licenses!(release)
    File.mkdir_p!(fixtures)
    File.chmod!(fixtures, 0o700)
    release = File.cd!(release, fn -> File.cwd!() end)
    fixtures = File.cd!(fixtures, fn -> File.cwd!() end)
    {:ok, _} = Application.ensure_all_started(:inets)
    load_http_consumer()

    report =
      %{
        "runtime_licenses" => "pass",
        "external_beam_tools_absent" => true,
        "external_compiler_absent" => is_nil(System.find_executable("gcc"))
      }
      |> Map.merge(
        lifecycle(release, Path.join(fixtures, "persistent"), options[:browser] == true)
      )
      |> Map.merge(failures(release, fixtures, options[:readonly_directory]))
      |> Map.merge(native_consumer(release, fixtures, options[:native_consumer]))

    write_json(Path.join(fixtures, "result.json"), report)
    IO.puts("RELEASE_PROBE_PASS " <> Jason.encode!(report))
  end

  defp lifecycle(release, directory, browser?) do
    instance = new_instance(release, directory, browser?)

    try do
      instance = start(instance)
      HTTPConsumer.main([instance.descriptor])
      thing = request(instance, "/things")["items"] |> hd() |> Map.fetch!("id")
      browser_cookie = browser_workflow(instance, thing)
      generation = request(instance, "/state")["generation"]
      first = cli_sample(instance, thing)
      expected_snapshot = "property:snapshot:#{generation}:#{generation}"
      ^expected_snapshot = first["event"]
      operation = Identifier.uuid()
      body = %{"thing_id" => thing, "expected_generation" => generation}
      receipt = request(instance, "/materialisations", body: body, operation: operation)
      next_generation = generation |> String.to_integer() |> Kernel.+(1) |> Integer.to_string()
      expected_event = "property:event:#{next_generation}:#{next_generation}"
      ^expected_event = cli_sample(instance, thing, first["cursor"])["event"]
      snapshot = request(instance, "/state")
      td = request(instance, "/things/" <> encode_segment(thing))
      stream = open_stream(instance, snapshot["stream_cursor"])
      stream = consume_ready(stream)
      watcher = Task.async(fn -> await_stream_close(stream) end)
      {instance, shutdown} = stop(instance)
      :closed = Task.await(watcher, 5_000)
      instance = start(instance)
      browser_session_expired(instance, browser_cookie)
      ^receipt = request(instance, "/operations/" <> operation)
      ^receipt = request(instance, "/materialisations", body: body, operation: operation)
      ^td = request(instance, "/things/" <> encode_segment(thing))
      ^next_generation = request(instance, "/state")["generation"]

      %{"code" => "unauthorized"} =
        request(instance, "/state", token: instance.reader, status: 401)

      {instance, _elapsed} = stop(instance, true)
      instance = start(instance)
      ^receipt = request(instance, "/operations/" <> operation)
      history = request(instance, "/things/" <> encode_segment(thing) <> "/history")
      ["3", "6", "7", "8", "9", ^next_generation] = Enum.map(history["items"], & &1["generation"])
      {instance, _elapsed} = stop(instance)
      assert_redacted!(instance)

      %{
        "http_openapi_sse" => "pass",
        "property_observation" => "pass",
        "cli_property_resume" => "pass",
        "history" => "pass",
        "sigterm_active_stream" => "pass",
        "shutdown_seconds" => Float.round(shutdown / 1_000, 3),
        "restart_and_idempotency" => "pass",
        "sigkill_recovery" => "pass",
        "retained_revocation" => "pass",
        "browser" => if(browser_cookie, do: "pass", else: "not-in-artifact")
      }
    after
      terminate(instance)
    end
  end

  defp failures(release, root, readonly_directory) do
    invalid = new_instance(release, Path.join(root, "invalid-storage"))
    File.chmod!(invalid.document["data_directory"], 0o755)
    invalid = start(invalid, true)
    assert_redacted!(invalid)
    full = new_instance(release, Path.join(root, "full-storage"))
    full = put_in(full, [:document, "storage_limits"], %{"max_pages" => 40})

    try do
      full = start(full)

      observation = %{
        "schema" => "wtr.observation.v1",
        "id" => "full-disk-fixture",
        "observed_at" => 0,
        "ingress" => "imported",
        "source" => %{},
        "addressing" => %{},
        "radio" => %{},
        "transport" => %{},
        "provenance" => %{},
        "payload" => %{
          "kind" => "bytes",
          "encoding" => "base64",
          "data" => Base.encode64(:binary.copy("x", 65_536))
        }
      }

      %{"code" => "storage_full", "outcome" => "not_committed"} =
        request(full, "/observations",
          body: %{"observation" => observation, "expected_generation" => "0"},
          status: 507
        )

      "0" = request(full, "/observations")["generation"]
      {full, _elapsed} = stop(full)
      assert_redacted!(full)
    after
      terminate(full)
    end

    readonly = readonly_failure(release, root, readonly_directory)

    %{
      "invalid_storage_permissions" => "pass",
      "sqlite_full_rollback" => "pass",
      "readonly_filesystem" => readonly
    }
  end

  defp readonly_failure(_release, _root, nil), do: "not-executed"

  defp readonly_failure(release, root, directory) do
    instance = new_instance(release, Path.join(root, "readonly-storage"))
    instance = put_in(instance, [:document, "data_directory"], directory)
    instance = start(instance, true)
    assert_redacted!(instance)
    "pass"
  end

  defp native_consumer(_release, _fixtures, nil), do: %{}

  defp native_consumer(release, fixtures, executable) do
    instance = new_instance(release, Path.join(fixtures, "native-client"))

    try do
      instance = start(instance)

      {output, status} =
        System.cmd(executable, [instance.descriptor], stderr_to_stdout: true)

      unless status == 0 and String.contains?(output, "NATIVE_PROTOCOL_PASS"),
        do: raise("native protocol client failed: #{output}")

      IO.puts(String.trim(output))
      {instance, _elapsed} = stop(instance)
      assert_redacted!(instance)
      %{"native_protocol_client" => "pass"}
    after
      terminate(instance)
    end
  end

  defp new_instance(release, directory, browser? \\ false) do
    File.mkdir_p!(Path.dirname(directory))
    port = available_port()
    cli = Path.join([release, "bin", "trackerctl"])

    {output, 0} =
      System.cmd(
        cli,
        [
          "--scope",
          @scope,
          "init",
          "--directory",
          directory,
          "--instance-id",
          Identifier.uuid(),
          "--bind",
          "127.0.0.1",
          "--port",
          Integer.to_string(port)
        ],
        stderr_to_stdout: true
      )

    descriptor = Codec.decode!(output)
    config = descriptor["config"]

    token =
      config |> Path.dirname() |> Path.join("operator.token") |> File.read!() |> String.trim()

    reader = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    document = config |> File.read!() |> Codec.decode!()
    [admin] = document["credentials"]
    admin = %{admin | "id" => "admin"}

    reader_entry = %{
      "id" => "reader",
      "principal" => "reader",
      "token_sha256" => :crypto.hash(:sha256, reader) |> Base.encode16(case: :lower),
      "grants" => %{@scope => ["read"]},
      "expires_at" => System.system_time(:millisecond) + 3_600_000
    }

    client = Path.join(directory, "client.json")

    write_json(client, %{
      "url" => "http://127.0.0.1:#{port}",
      "scope" => @scope,
      "token" => token,
      "reader" => reader,
      "now" => 1_700_000_000_000
    })

    browser = if browser?, do: browser_configuration(directory), else: nil

    %{
      release: release,
      directory: directory,
      config: config,
      token: token,
      reader: reader,
      document: %{document | "credentials" => [admin, reader_entry]},
      origin: "http://127.0.0.1:#{port}",
      descriptor: client,
      browser: browser,
      process: nil
    }
  end

  defp browser_configuration(directory) do
    port = available_port()
    origin = "http://127.0.0.1:#{port}"
    secret = Base.encode64(:crypto.strong_rand_bytes(64))
    config = Path.join(directory, "browser.json")

    write_json(config, %{
      "schema" => "wtr.browser.v1",
      "listen" => %{"ip" => "127.0.0.1", "port" => port},
      "exposure" => "loopback",
      "public_origin" => origin,
      "secret_key_base" => secret
    })

    %{config: config, origin: origin, secret: secret}
  end

  defp browser_workflow(%{browser: nil}, _thing), do: nil

  defp browser_workflow(instance, thing) do
    origin = instance.browser.origin
    {200, headers, sign_in} = browser_request(:get, origin <> "/sign-in", [], nil)
    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, sign_in)
    cookie = browser_cookie(headers)

    {302, login_headers, body} =
      browser_request(
        :post,
        origin <> "/session",
        [{~c"cookie", cookie}],
        URI.encode_query(%{"_csrf_token" => csrf, "scope" => @scope, "token" => instance.token})
      )

    false = String.contains?(body, instance.token)
    false = String.contains?(inspect(login_headers), instance.token)
    cookie = browser_cookie(login_headers)
    {200, _headers, assets} = browser_request(:get, origin <> "/", [{~c"cookie", cookie}], nil)
    true = String.contains?(assets, thing)

    {302, setup_headers, _body} =
      browser_request(:get, origin <> "/setup", [{~c"cookie", cookie}], nil)

    setup_location = setup_headers |> List.keyfind(~c"location", 0) |> elem(1) |> to_string()
    true = String.contains?(setup_location, "/setup?operation=")

    {200, _headers, setup} =
      browser_request(
        :get,
        URI.merge(origin, setup_location) |> to_string(),
        [{~c"cookie", cookie}],
        nil
      )

    true = String.contains?(setup, "Import an observation capture")
    true = String.contains?(setup, "id=\"import-capture\"")
    false = String.contains?(setup, instance.token)

    {302, detail_headers, _body} =
      browser_request(
        :get,
        origin <> "/assets/" <> URI.encode(thing, &URI.char_unreserved?/1),
        [{~c"cookie", cookie}],
        nil
      )

    location = detail_headers |> List.keyfind(~c"location", 0) |> elem(1) |> to_string()
    true = String.contains?(location, "?operation=")

    {200, _headers, detail} =
      browser_request(
        :get,
        URI.merge(origin, location) |> to_string(),
        [{~c"cookie", cookie}],
        nil
      )

    true = String.contains?(detail, "Recorded measurements")
    true = String.contains?(detail, "Measurement history")
    false = String.contains?(detail, instance.token)

    observation =
      request(instance, "/enrollments/" <> encode_segment(thing))["value"]["observation_id"]

    selector = "/assets/" <> encode_segment(thing) <> "/observations"

    {200, _headers, choices} =
      browser_request(:get, origin <> selector, [{~c"cookie", cookie}], nil)

    true = String.contains?(choices, "Inspect observation")
    true = String.contains?(choices, observation)

    {302, association_headers, _body} =
      browser_request(
        :get,
        origin <> selector <> "/" <> encode_segment(observation),
        [{~c"cookie", cookie}],
        nil
      )

    association_location =
      association_headers |> List.keyfind(~c"location", 0) |> elem(1) |> to_string()

    true = String.contains?(association_location, "?operation=")

    {200, _headers, association} =
      browser_request(
        :get,
        URI.merge(origin, association_location) |> to_string(),
        [{~c"cookie", cookie}],
        nil
      )

    true = String.contains?(association, "Confirm association")
    false = String.contains?(association, instance.token)

    {200, _headers, analytics} =
      browser_request(
        :get,
        origin <> "/assets/" <> encode_segment(thing) <> "/analytics",
        [{~c"cookie", cookie}],
        nil
      )

    true = String.contains?(analytics, "Run query")
    false = String.contains?(analytics, instance.token)

    for path <-
          ~w(/assets/tracker.js /assets/tracker.css /assets/phoenix/phoenix.min.js /assets/liveview/phoenix_live_view.min.js) do
      {200, _headers, bytes} = browser_request(:get, origin <> path, [], nil)
      true = byte_size(bytes) > 100
    end

    cookie
  end

  defp browser_session_expired(%{browser: nil}, nil), do: :ok

  defp browser_session_expired(instance, cookie) do
    origin = instance.browser.origin
    {302, headers, _body} = browser_request(:get, origin <> "/", [{~c"cookie", cookie}], nil)
    location = headers |> List.keyfind(~c"location", 0) |> elem(1) |> to_string()
    true = String.ends_with?(location, "/sign-in")
    :ok
  end

  defp browser_request(method, url, headers, body) do
    request =
      if body,
        do: {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body},
        else: {String.to_charlist(url), headers}

    {:ok, {{_version, status, _reason}, response_headers, response}} =
      :httpc.request(method, request, [timeout: 5_000, autoredirect: false], body_format: :binary)

    {status, response_headers, response}
  end

  defp browser_cookie(headers) do
    headers
    |> List.keyfind(~c"set-cookie", 0)
    |> elem(1)
    |> to_string()
    |> String.split(";")
    |> hd()
    |> String.to_charlist()
  end

  defp start(instance, expected_failure \\ false) do
    write_json(instance.config, instance.document)
    executable = Path.join([instance.release, "bin", "wotex_tracker"])

    environment =
      System.get_env()
      |> Map.delete("WOTEX_TRACKER_UI_CONFIG")
      |> Map.put("WOTEX_TRACKER_CONFIG", instance.config)

    environment =
      if instance.browser,
        do: Map.put(environment, "WOTEX_TRACKER_UI_CONFIG", instance.browser.config),
        else: environment

    log = Path.join(instance.directory, "release.log")
    {:ok, process} = ReleaseProcess.start_link(executable, environment, log)
    instance = %{instance | process: process}

    if expected_failure do
      status = await_exit(process, 10_000)
      if status == 0, do: raise("invalid storage unexpectedly started")
      terminate(instance)
      instance
    else
      await_readiness!(instance, 20_000)
      instance
    end
  end

  defp stop(instance, crash \\ false)
  defp stop(%{process: nil} = instance, _crash), do: {instance, 0}

  defp stop(instance, crash) do
    started = System.monotonic_time(:millisecond)

    if is_nil(ReleaseProcess.status(instance.process)) do
      signal = if crash, do: "-KILL", else: "-TERM"

      {_output, 0} =
        System.cmd("/bin/sh", [
          "-c",
          "kill #{signal} \"$1\"",
          "sh",
          Integer.to_string(ReleaseProcess.os_pid(instance.process))
        ])

      _status = await_exit(instance.process, 10_000)
    end

    ReleaseProcess.drain(instance.process)
    GenServer.stop(instance.process)
    {%{instance | process: nil}, System.monotonic_time(:millisecond) - started}
  end

  defp terminate(%{process: nil}), do: :ok

  defp terminate(instance) do
    if Process.alive?(instance.process) do
      try do
        stop(instance, true)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp await_readiness!(instance, remaining) when remaining > 0 do
    if ReleaseProcess.status(instance.process) do
      ReleaseProcess.drain(instance.process)
      assert_redacted!(instance)
      raise("bundled release exited before readiness")
    end

    case :httpc.request(
           :get,
           {String.to_charlist(instance.origin <> "/health/live"), []},
           [timeout: 500],
           body_format: :binary
         ) do
      {:ok, {{_version, 200, _reason}, _headers, _body}} ->
        :ok

      _ ->
        Process.sleep(100)
        await_readiness!(instance, remaining - 100)
    end
  end

  defp await_readiness!(_instance, _remaining),
    do: raise("bundled release startup exceeded 20 seconds")

  defp await_exit(process, remaining) when remaining > 0 do
    case ReleaseProcess.status(process) do
      nil ->
        Process.sleep(50)
        await_exit(process, remaining - 50)

      status ->
        status
    end
  end

  defp await_exit(_process, _remaining),
    do: raise("bundled release shutdown exceeded ten seconds")

  defp request(instance, path, options \\ []) do
    status = Keyword.get(options, :status, 200)
    token = Keyword.get(options, :token, instance.token)
    body = Keyword.get(options, :body)

    headers = [
      {~c"authorization", ~c"Bearer " ++ to_charlist(token)},
      {~c"accept", ~c"application/json"}
    ]

    {method, input} =
      if body do
        bytes = Codec.encode!(body)
        operation = Keyword.get(options, :operation, Identifier.uuid())
        headers = [{~c"idempotency-key", to_charlist(operation)} | headers]

        {:post,
         {to_charlist(instance.origin <> "/api/v1/scopes/#{@scope}" <> path), headers,
          ~c"application/json", bytes}}
      else
        {:get, {to_charlist(instance.origin <> "/api/v1/scopes/#{@scope}" <> path), headers}}
      end

    {:ok, {{_version, actual, _reason}, _headers, bytes}} =
      :httpc.request(method, input, [timeout: 5_000], body_format: :binary)

    if actual != status, do: raise("release returned HTTP #{actual}, expected #{status}")
    if byte_size(bytes) > @body_limit, do: raise("release response exceeded body limit")
    %{"schema" => "wtr.response.v1"} = value = Codec.decode!(bytes)
    if status < 400, do: value["data"], else: value["error"]
  end

  defp cli_sample(instance, thing, cursor \\ nil) do
    arguments = [
      "--url",
      instance.origin,
      "--scope",
      @scope,
      "--token-file",
      Path.join(instance.directory, "operator.token"),
      "observe",
      thing,
      "temperature",
      "--seconds",
      "3",
      "--max-events",
      "1"
    ]

    arguments = if cursor, do: arguments ++ ["--cursor", cursor], else: arguments

    {output, 0} =
      System.cmd(Path.join([instance.release, "bin", "trackerctl"]), arguments,
        stderr_to_stdout: true
      )

    false = String.contains?(output, instance.token)
    %{"schema" => "wtr.property.v1", "value" => 24.3} = Codec.decode!(output)
  end

  defp open_stream(instance, cursor) do
    uri = URI.parse(instance.origin)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [:binary, active: false], 5_000)

    path = "/api/v1/scopes/#{@scope}/events/stream?" <> URI.encode_query(%{"cursor" => cursor})

    request = [
      "GET ",
      path,
      " HTTP/1.1\r\nHost: ",
      uri.host,
      "\r\nAuthorization: Bearer ",
      instance.token,
      "\r\nAccept: text/event-stream\r\nConnection: close\r\n\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {head, rest} = receive_head(socket, <<>>)
    true = String.starts_with?(head, "HTTP/1.1 200 ")
    %{socket: socket, buffer: rest}
  end

  defp receive_head(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] when byte_size(bytes) <= 8_192 ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        receive_head(socket, bytes <> chunk)

      _ ->
        raise("artifact stream headers exceeded limit")
    end
  end

  defp consume_ready(stream) do
    case :binary.match(stream.buffer, ["\n\n", "\r\n\r\n"]) do
      {index, length} ->
        <<frame::binary-size(index), _separator::binary-size(length), rest::binary>> =
          stream.buffer

        true = String.contains?(frame, "event: ready")
        %{stream | buffer: rest}

      :nomatch when byte_size(stream.buffer) <= 32_768 ->
        {:ok, chunk} = :gen_tcp.recv(stream.socket, 0, 5_000)
        consume_ready(%{stream | buffer: stream.buffer <> chunk})

      _ ->
        raise("artifact stream ready frame exceeded limit")
    end
  end

  defp await_stream_close(stream) do
    case :gen_tcp.recv(stream.socket, 0, 5_000) do
      {:error, :closed} -> :closed
      {:ok, _bytes} -> await_stream_close(stream)
      {:error, reason} -> raise("artifact stream did not close: #{inspect(reason)}")
    end
  end

  defp assert_redacted!(instance) do
    log = Path.join(instance.directory, "release.log")

    if File.exists?(log) do
      bytes = File.read!(log)

      secrets = [instance.token, instance.reader, instance.document["secret_key"]]
      secrets = if instance.browser, do: [instance.browser.secret | secrets], else: secrets

      for secret <- secrets,
          String.contains?(bytes, secret),
          do: raise("release log failed secret redaction")
    end
  end

  defp assert_clean_path! do
    root = System.fetch_env!("WOTEX_TRACKER_RELEASE_ROOT") |> File.cd!(fn -> File.cwd!() end)

    for tool <- ~w(elixir erl mix), executable = System.find_executable(tool), executable do
      unless String.starts_with?(Path.expand(executable), root <> "/"),
        do: raise("release probe found external BEAM tool #{tool}")
    end
  end

  defp assert_licenses!(release) do
    components =
      ~w(wotex_tracker_host wotex_tracker wotex_tracker_service wotex wotex_runtime wotex_binding_http exqlite mint elixir erlang-OTP-27.3.4.15)

    components =
      if Path.wildcard(Path.join(release, "lib/wotex_tracker_ui-*")) != [],
        do:
          components ++
            ~w(wotex_tracker_ui phoenix phoenix_live_view phoenix_html phoenix_pubsub phoenix_template),
        else: components

    for component <- components do
      licenses = Path.join([release, "licenses", component, "LICENSE*"]) |> Path.wildcard()
      if licenses == [], do: raise("release omitted a runtime license for #{component}")
    end
  end

  defp load_http_consumer do
    System.put_env("WOTEX_TRACKER_HTTP_NO_MAIN", "1")
    Code.require_file(Path.join(__DIR__, "http_consumer.exs"))
    System.delete_env("WOTEX_TRACKER_HTTP_NO_MAIN")
  end

  defp write_json(path, value) do
    File.write!(path, Codec.encode!(value))
    File.chmod!(path, 0o600)
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end

unless System.get_env("WOTEX_TRACKER_RELEASE_PROBE_NO_MAIN") == "1" do
  Wotex.Tracker.ReleaseProbe.main(System.argv())
end
