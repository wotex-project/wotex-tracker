defmodule Wotex.Tracker.Host.DarwinSystemTools do
  @moduledoc """
  Reads a fixed bounded macOS resource sample from operating-system tools.

  The adapter invokes only absolute platform paths with fixed arguments. Missing,
  oversized or malformed output makes the complete sample unavailable.
  """

  @vm_stat "/usr/bin/vm_stat"
  @ps "/bin/ps"
  @sysctl "/usr/sbin/sysctl"
  @maximum_bytes 65_536
  @maximum_value 9_223_372_036_854_775_807

  @doc false
  def sample(runner \\ &command/2)

  def sample(runner) when is_function(runner, 2) do
    with {:ok, memory} <- run(runner, @vm_stat, []),
         {:ok, status} <- run(runner, @ps, ["-o", "rss=", "-p", System.pid()]),
         {:ok, load} <- run(runner, @sysctl, ["-n", "vm.loadavg"]),
         {:ok, available} <- available_memory(memory),
         {:ok, rss} <- resident_memory(status),
         {:ok, load_1m} <- load_1m(load) do
      {:ok,
       %{
         system_available_memory_bytes: available,
         process_rss_bytes: rss,
         load_1m_milli: load_1m
       }}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def sample(_), do: {:error, :unavailable}

  @doc false
  def command(executable, arguments),
    do: System.cmd(executable, arguments, stderr_to_stdout: true)

  defp run(runner, executable, arguments) do
    case runner.(executable, arguments) do
      {output, 0} when is_binary(output) and byte_size(output) in 1..@maximum_bytes ->
        {:ok, output}

      _ ->
        {:error, :unavailable}
    end
  end

  defp available_memory(document) do
    with [_, encoded_size] <-
           Regex.run(
             ~r/\AMach Virtual Memory Statistics: \(page size of ([0-9]+) bytes\)\n/,
             document
           ),
         {:ok, page_size} <- integer(encoded_size),
         {:ok, free} <- pages(document, "Pages free:"),
         {:ok, inactive} <- pages(document, "Pages inactive:"),
         {:ok, speculative} <- pages(document, "Pages speculative:"),
         pages when pages <= div(@maximum_value, page_size) <- free + inactive + speculative do
      {:ok, pages * page_size}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp pages(document, field) do
    pattern = Regex.compile!("^" <> Regex.escape(field) <> "[[:space:]]+([0-9]+)\\.$", "m")

    case Regex.run(pattern, document) do
      [_, encoded] -> integer(encoded)
      _ -> {:error, :unavailable}
    end
  end

  defp resident_memory(document) do
    with {:ok, kilobytes} <- document |> String.trim() |> integer(),
         true <- kilobytes <= div(@maximum_value, 1_024) do
      {:ok, kilobytes * 1_024}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp load_1m(document) do
    with [_, encoded] <-
           Regex.run(
             ~r/\A\{\s*([0-9]+(?:\.[0-9]+)?)\s+[0-9]+(?:\.[0-9]+)?\s+[0-9]+(?:\.[0-9]+)?\s*\}\s*\z/,
             document
           ),
         {value, ""} when value >= 0.0 <- Float.parse(encoded),
         true <- value <= @maximum_value / 1_000 do
      {:ok, round(value * 1_000)}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp integer(encoded) do
    case Integer.parse(encoded) do
      {value, ""} when value >= 0 and value <= @maximum_value -> {:ok, value}
      _ -> {:error, :unavailable}
    end
  end
end
