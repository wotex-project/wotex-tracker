defmodule Wotex.Tracker.Admission do
  @moduledoc false
  alias Wotex.Tracker.{Error, Limits}

  @spec fields(term(), [atom()], [atom()]) :: :ok | {:error, Error.t()}
  def fields(value, required, optional \\ []) do
    allowed = required ++ optional

    if is_map(value) and not is_struct(value) and map_size(value) <= length(allowed) and
         Enum.all?(required, &Map.has_key?(value, &1)) and
         Enum.all?(Map.keys(value), &(&1 in allowed)),
       do: :ok,
       else: fail(:invalid_input)
  end

  @spec id(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def id(value, limits) do
    if is_binary(value) and byte_size(value) in 1..limits.max_id_bytes and String.valid?(value),
      do: :ok,
      else: fail(:invalid_id)
  end

  @spec json(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def json(value, limits) do
    case Wotex.JSON.validate(value, Limits.json(limits)) do
      :ok -> :ok
      {:error, _} -> fail(:invalid_json)
    end
  end

  @spec object(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def object(value, limits) when is_map(value), do: json(value, limits)
  def object(_, _), do: fail(:invalid_json)

  @spec bounded_list(term(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def bounded_list([], _remaining), do: :ok

  def bounded_list([_ | rest], remaining) when remaining > 0,
    do: bounded_list(rest, remaining - 1)

  def bounded_list([_ | _], 0), do: fail(:limit_exceeded)
  def bounded_list(_, _), do: fail(:invalid_input)

  @spec ids(term(), Limits.t(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def ids(values, limits, max) do
    with :ok <- bounded_list(values, max),
         :ok <- each(values, &id(&1, limits)) do
      if length(Enum.uniq(values)) == length(values), do: :ok, else: fail(:duplicate_id)
    end
  end

  @spec revision(term(), Limits.t()) :: :ok | {:error, Error.t()}
  def revision({id, version}, limits) do
    with :ok <- id(id, limits), do: id(version, limits)
  end

  def revision(_, _), do: fail(:invalid_input)

  @spec each(list(), (term() -> :ok | {:error, Error.t()})) :: :ok | {:error, Error.t()}
  def each(values, check) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case check.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @spec digest(Wotex.JSON.json_value(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def digest(value, options) do
    case Wotex.JSON.encode(value, options) do
      {:ok, bytes} ->
        {:ok, "wtr-json-v1:sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}

      {:error, _} ->
        fail(:invalid_json)
    end
  end

  @spec fail(atom()) :: {:error, Error.t()}
  def fail(code), do: {:error, Error.new(code, :admission)}
end
