defmodule Wotex.Tracker.UI.QueryWindow do
  @moduledoc "Bounded UTC window movement shared by structured and saved analytics."
  alias Wotex.Tracker.QuerySpec

  @max_browser_time 253_402_300_799_999

  @spec move(String.t(), integer(), integer()) :: {:ok, {integer(), integer()}} | :error
  def move(direction, from_at, to_at)
      when is_integer(from_at) and is_integer(to_at) and to_at > from_at do
    width = to_at - from_at

    case bounds(direction, from_at, to_at, width) do
      {start_at, end_at}
      when start_at >= 0 and end_at > start_at and end_at <= @max_browser_time ->
        {:ok, {start_at, end_at}}

      _ ->
        :error
    end
  end

  def move(_, _, _), do: :error

  @spec query(map(), String.t()) :: {:ok, map()} | :error
  def query(document, direction) when is_map(document) do
    with {:ok, spec} <- QuerySpec.from_map(document),
         {:ok, {from_at, to_at}} <- move(direction, spec.from_at, spec.to_at),
         input <-
           spec
           |> Map.from_struct()
           |> Map.delete(:identity)
           |> Map.merge(%{from_at: from_at, to_at: to_at}),
         {:ok, adjusted} <- QuerySpec.new(input),
         {:ok, serialized} <- QuerySpec.to_map(adjusted) do
      {:ok, serialized}
    else
      _ -> :error
    end
  end

  def query(_, _), do: :error

  defp bounds("earlier", from_at, to_at, width),
    do: {from_at - div(width, 2), to_at - div(width, 2)}

  defp bounds("later", from_at, to_at, width),
    do: {from_at + div(width, 2), to_at + div(width, 2)}

  defp bounds("zoom_in", from_at, to_at, width),
    do: {from_at + div(width, 4), to_at - div(width, 4)}

  defp bounds("zoom_out", from_at, to_at, width),
    do: {from_at - div(width, 2), to_at + div(width, 2)}

  defp bounds(_, _, _, _), do: :invalid
end
