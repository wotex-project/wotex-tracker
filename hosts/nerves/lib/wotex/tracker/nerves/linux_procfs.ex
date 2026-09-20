defmodule Wotex.Tracker.Nerves.LinuxProcfs do
  @moduledoc """
  Reads the fixed Linux procfs fields used by the Nerves resource sampler.

  No caller-controlled path is accepted. Missing, oversized or malformed files
  make the whole sample unavailable instead of inventing a partial value.
  """

  @meminfo "/proc/meminfo"
  @status "/proc/self/status"
  @loadavg "/proc/loadavg"
  @maximum_bytes 65_536
  @maximum_value 9_223_372_036_854_775_807

  @doc false
  def sample(reader \\ &File.read/1)

  def sample(reader) when is_function(reader, 1) do
    with {:ok, meminfo} <- read(reader, @meminfo),
         {:ok, status} <- read(reader, @status),
         {:ok, loadavg} <- read(reader, @loadavg),
         {:ok, available} <- kilobytes(meminfo, "MemAvailable:"),
         {:ok, rss} <- kilobytes(status, "VmRSS:"),
         {:ok, load} <- load(loadavg) do
      {:ok,
       %{
         system_available_memory_bytes: available,
         process_rss_bytes: rss,
         load_1m_milli: load
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

  defp read(reader, path) do
    case reader.(path) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..@maximum_bytes ->
        {:ok, value}

      _ ->
        {:error, :unavailable}
    end
  end

  defp kilobytes(document, field) do
    document
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, field))
    |> parse_kilobytes(field)
  end

  defp parse_kilobytes(nil, _field), do: {:error, :unavailable}

  defp parse_kilobytes(line, field) do
    with value <- line |> String.replace_prefix(field, "") |> String.trim(),
         [number, "kB"] <- String.split(value, ~r/\s+/, trim: true),
         {kilobytes, ""} when kilobytes >= 0 <- Integer.parse(number),
         true <- kilobytes <= div(@maximum_value, 1_024) do
      {:ok, kilobytes * 1_024}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp load(document) do
    with [first | _] <- String.split(document),
         {value, ""} when value >= 0.0 <- Float.parse(first),
         true <- value <= @maximum_value / 1_000 do
      {:ok, round(value * 1_000)}
    else
      _ -> {:error, :unavailable}
    end
  end
end
