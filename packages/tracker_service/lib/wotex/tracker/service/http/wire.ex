defmodule Wotex.Tracker.Service.HTTP.Wire do
  @moduledoc false

  import Plug.Conn
  alias Plug.Conn.Utils
  alias Wotex.Tracker.Service.{Codec, Identifier}

  @statuses %{
    "unauthorized" => 401,
    "forbidden" => 403,
    "not_found" => 404,
    "conflict" => 409,
    "idempotency_conflict" => 409,
    "observation_conflict" => 409,
    "cursor_expired" => 410,
    "operation_expired" => 410,
    "unresolved" => 422,
    "revision_mismatch" => 409,
    "unsupported" => 501,
    "overloaded" => 429,
    "unsupported_version" => 404,
    "method_not_allowed" => 405,
    "unsupported_media_type" => 415,
    "not_acceptable" => 406,
    "response_too_large" => 503,
    "storage_unavailable" => 503,
    "storage_full" => 507,
    "busy" => 503,
    "capacity_exceeded" => 507,
    "internal_error" => 500,
    "unavailable" => 503,
    "deadline_exceeded" => 504
  }

  def error(code), do: {:error, %{"code" => Atom.to_string(code), "path" => "/"}}

  def mutation_error(code, operation) do
    {:error, error} = error(code)

    {:error,
     Map.merge(error, %{
       "outcome" => "not_committed",
       "operation_id" => valid_operation(operation)
     })}
  end

  def valid_operation(value), do: if(Identifier.operation?(value), do: value, else: nil)

  def send_result(conn, {:ok, result}) do
    status = if is_map(result) and result["outcome"] == "unknown", do: 202, else: 200
    json(conn, status, %{"schema" => "wtr.response.v1", "data" => result})
  end

  def send_result(conn, {:error, code}) when is_atom(code), do: send_result(conn, error(code))

  def send_result(conn, {:error, %{"code" => code} = error}) do
    conn =
      if code == "unauthorized",
        do: put_resp_header(conn, "www-authenticate", "Bearer"),
        else: conn

    json(conn, Map.get(@statuses, code, 400), %{"schema" => "wtr.response.v1", "error" => error})
  end

  def json(conn, status, document) do
    case Codec.encode(document, 4_194_304) do
      {:ok, bytes} -> bytes(conn, status, bytes, "application/json")
      {:error, _} -> send_result(conn, error(:response_too_large))
    end
  end

  def bytes(conn, status, bytes, type) do
    conn |> headers() |> put_resp_content_type(type) |> send_resp(status, bytes)
  end

  def headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("connection", "close")
  end

  def parameters(conn) do
    with true <- byte_size(conn.query_string) <= 8192,
         true <- not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, conn.query_string),
         pairs = URI.query_decoder(conn.query_string) |> Enum.to_list(),
         true <- length(pairs) <= 2 and length(pairs) == map_size(Map.new(pairs)),
         true <- Enum.all?(pairs, fn {k, v} -> String.valid?(k) and String.valid?(v) end) do
      {:ok, Map.new(pairs)}
    else
      _ -> error(:invalid_request)
    end
  rescue
    ArgumentError -> error(:invalid_request)
  end

  def path(conn) do
    if Enum.any?(conn.path_info, &Regex.match?(~r/%(?![0-9a-fA-F]{2})/, &1)),
      do: {:error, :invalid_request},
      else: {:ok, Enum.map(conn.path_info, &URI.decode/1)}
  end

  def single_header(conn, name) do
    case get_req_header(conn, name) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _ -> error(:invalid_header)
    end
  end

  def acceptable?(conn, media) do
    case get_req_header(conn, "accept") do
      [] ->
        true

      headers ->
        [type, subtype] = String.split(media, "/")

        headers
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&preference(&1, type, subtype))
        |> Enum.max(fn -> {-1, 0.0} end)
        |> then(fn {_, quality} -> quality > 0 end)
    end
  end

  defp preference(value, type, subtype) do
    case Utils.media_type(String.trim(value)) do
      {:ok, ^type, ^subtype, parameters} -> {2, quality(parameters)}
      {:ok, ^type, "*", parameters} -> {1, quality(parameters)}
      {:ok, "*", "*", parameters} -> {0, quality(parameters)}
      _ -> {-1, 0.0}
    end
  end

  defp quality(parameters) do
    value = Map.get(parameters, "q", "1")

    if Regex.match?(~r/\A(?:0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)\z/, value),
      do: elem(Float.parse(value), 0),
      else: 0.0
  end

  def body(conn) do
    with [type] <- get_req_header(conn, "content-type"),
         true <- type in ["application/json", "application/json; charset=utf-8"],
         [] <- get_req_header(conn, "content-encoding") do
      read_json(conn)
    else
      _ -> {:error, :unsupported_media_type, conn}
    end
  end

  defp read_json(conn) do
    case read_body(conn, length: 1_048_576, read_length: 65_536, read_timeout: 5000) do
      {:ok, bytes, conn} when byte_size(bytes) <= 1_048_576 ->
        case Codec.decode(bytes) do
          {:ok, value} -> {:ok, value, conn}
          _ -> {:error, :invalid_json, conn}
        end

      {:more, _, conn} ->
        {:error, :invalid_request, conn}

      {:ok, _, conn} ->
        {:error, :invalid_request, conn}

      {:error, _} ->
        {:error, :invalid_request, conn}
    end
  end
end
