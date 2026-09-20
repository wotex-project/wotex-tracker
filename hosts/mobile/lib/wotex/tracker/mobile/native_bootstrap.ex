defmodule Wotex.Tracker.Mobile.NativeBootstrap do
  @moduledoc """
  Converts the native app's non-secret server selection into an ephemeral host.

  Every process start generates a new loopback capability and Phoenix signing
  secret. Only the selected canonical HTTPS origin survives process death.
  """

  import Bitwise

  alias Wotex.Tracker.Mobile.Application, as: MobileApplication
  alias Wotex.Tracker.Mobile.{Config, NativeConfiguration, Runtime, WebSession}

  @application_id "org.wotex.tracker"
  @directory_name "wotex_tracker"
  @maximum_ancestor_links 32

  @doc "Starts the configured host or reports that first-run setup is required."
  @spec boot(keyword()) :: {:ok, WebSession.t()} | :missing | {:error, atom()}
  def boot(options \\ []) when is_list(options) do
    case Process.whereis(Runtime) do
      pid when is_pid(pid) -> current_session(options)
      nil -> boot_configured(options)
    end
  end

  @doc "Persists an admitted server choice and replaces the ephemeral host."
  @spec configure(term(), keyword()) :: {:ok, WebSession.t()} | {:error, atom()}
  def configure(origin, options \\ [])

  def configure(origin, options) when is_list(options) do
    with {:ok, directory} <- directory(options),
         {:ok, config} <- NativeConfiguration.new(origin),
         :ok <- NativeConfiguration.save(directory, config),
         {:ok, host_options} <- host_options(config, directory, options),
         {:ok, _} <- replace_host(host_options, options),
         {:ok, session} <- current_session(options) do
      {:ok, session}
    else
      {:error, _} = error -> error
      _ -> {:error, :native_runtime_unavailable}
    end
  rescue
    _ -> {:error, :native_runtime_unavailable}
  catch
    _, _ -> {:error, :native_runtime_unavailable}
  end

  def configure(_, _), do: {:error, :invalid_configuration}

  defp boot_configured(options) do
    with {:ok, directory} <- directory(options) do
      case NativeConfiguration.load(directory) do
        {:ok, config} -> start_configured(config, directory, options)
        :missing -> :missing
        {:error, _} = error -> error
      end
    end
  rescue
    _ -> {:error, :native_runtime_unavailable}
  catch
    _, _ -> {:error, :native_runtime_unavailable}
  end

  defp start_configured(config, directory, options) do
    with {:ok, host_options} <- host_options(config, directory, options),
         {:ok, _} <- start_host(host_options, options),
         {:ok, session} <- current_session(options) do
      {:ok, session}
    else
      {:error, _} = error -> error
      _ -> {:error, :native_runtime_unavailable}
    end
  end

  defp directory(options) do
    root = invoke(Keyword.get(options, :data_directory, &Mob.data_dir/0))

    with true <- is_binary(root) and byte_size(root) in 1..4_096,
         true <- Path.type(root) == :absolute and Path.expand(root) == root,
         {:ok, root} <- canonical_root(root),
         directory = Path.join(root, @directory_name),
         :ok <- create_private_directory(root, directory) do
      {:ok, directory}
    else
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp canonical_root(root) do
    with {:ok, parent} <- canonical_directory(Path.dirname(root), 0),
         root = Path.join(parent, Path.basename(root)),
         :ok <- bounded_path(root),
         {:ok, %{type: :directory}} <- File.lstat(root) do
      {:ok, root}
    else
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp canonical_directory(path, followed_links) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 == "/"))
    |> resolve_components("/", followed_links)
  end

  defp resolve_components([], resolved, _followed_links), do: {:ok, resolved}

  defp resolve_components([component | remaining], resolved, followed_links) do
    candidate = Path.join(resolved, component)

    case File.lstat(candidate) do
      {:ok, %{type: :directory}} ->
        resolve_components(remaining, candidate, followed_links)

      {:ok, %{type: :symlink}} when followed_links < @maximum_ancestor_links ->
        resolve_link(candidate, resolved, remaining, followed_links + 1)

      _ ->
        {:error, :configuration_unavailable}
    end
  end

  defp resolve_link(candidate, resolved, remaining, followed_links) do
    with {:ok, target} <- File.read_link(candidate),
         :ok <- bounded_path(target),
         target <- canonical_link_target(target, resolved),
         :ok <- bounded_path(target) do
      target
      |> Path.split()
      |> Enum.reject(&(&1 == "/"))
      |> Kernel.++(remaining)
      |> resolve_components("/", followed_links)
    else
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp canonical_link_target(target, resolved) do
    if Path.type(target) == :absolute,
      do: Path.expand(target),
      else: Path.expand(target, resolved)
  end

  defp bounded_path(path),
    do: if(byte_size(path) in 1..4_096, do: :ok, else: {:error, :configuration_unavailable})

  defp create_private_directory(root, directory) do
    with true <- real_directories(root),
         {:ok, %{type: :directory}} <- File.lstat(root),
         :ok <- mkdir(directory),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(directory),
         true <- (mode &&& 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp mkdir(directory) do
    case File.mkdir(directory) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      _ -> {:error, :configuration_unavailable}
    end
  end

  defp real_directories(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        parent = Path.dirname(path)
        parent == path or real_directories(parent)

      _ ->
        false
    end
  end

  defp host_options(config, directory, options) do
    with {:ok, port} <- port(options),
         capability when is_binary(capability) <- Config.generate_capability() do
      base = [
        directory: directory,
        remote_origin: config.remote_origin,
        port: port,
        secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
        capability: capability
      ]

      {:ok, base ++ notification_options(options)}
    else
      _ -> {:error, :native_runtime_unavailable}
    end
  end

  defp notification_options(options) do
    environment =
      Keyword.get_lazy(options, :notification_environment, fn ->
        Elixir.Application.get_env(:wotex_tracker_mobile, :notification_environment)
      end)

    if environment in ~w(sandbox production) do
      [notification_app_id: @application_id, notification_environment: environment]
    else
      []
    end
  end

  defp port(options) do
    case Keyword.get(options, :port) do
      function when is_function(function, 0) -> admit_port(invoke(function))
      nil -> available_port()
      value -> admit_port(value)
    end
  end

  defp available_port do
    with {:ok, socket} <-
           :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false]),
         {:ok, {{127, 0, 0, 1}, port}} <- :inet.sockname(socket),
         :ok <- :gen_tcp.close(socket) do
      {:ok, port}
    else
      _ -> {:error, :native_runtime_unavailable}
    end
  end

  defp admit_port(port) when port in 1..65_535, do: {:ok, port}
  defp admit_port(_), do: {:error, :native_runtime_unavailable}

  defp start_host(options, bootstrap_options) do
    function = Keyword.get(bootstrap_options, :start_host, &MobileApplication.start_host/1)
    invoke(fn -> function.(options) end)
  end

  defp replace_host(options, bootstrap_options) do
    function = Keyword.get(bootstrap_options, :replace_host, &MobileApplication.replace_host/1)
    invoke(fn -> function.(options) end)
  end

  defp current_session(options) do
    function = Keyword.get(options, :web_session, &Runtime.web_session/0)

    case invoke(function) do
      %WebSession{} = session -> {:ok, session}
      _ -> {:error, :native_runtime_unavailable}
    end
  rescue
    _ -> {:error, :native_runtime_unavailable}
  catch
    _, _ -> {:error, :native_runtime_unavailable}
  end

  defp invoke(function), do: function.()
end
