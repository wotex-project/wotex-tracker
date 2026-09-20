defmodule Wotex.Tracker.Protocols.Teltonika.TCPSession do
  @moduledoc """
  Pure, bounded Teltonika TCP login and acknowledgement decisions.

  A device begins a TCP connection with a two-byte big-endian length followed
  by its 15 ASCII IMEI digits. `feed_login/2` handles arbitrary split boundaries
  and returns bytes coalesced after the login separately, so a host can decide
  admission before feeding those bytes to the AVL decoder.

  An IMEI is routing evidence, not authentication. The returned value is private
  host input and must not be logged, exported or used as a public Thing ID.
  `identity_digest/2` derives a keyed configuration lookup value so hosts need
  not retain the raw IMEI.

  Data acknowledgement is deliberately outcome-driven: accepted and duplicate
  durable commits acknowledge the complete decoded packet, a known rejection
  acknowledges zero records, and an unknown commit closes without an ACK so a
  reconnect can reconcile or retransmit safely.
  """

  alias Wotex.Tracker.Error
  alias Wotex.Tracker.Protocols.Teltonika.Codec8Extended

  @imei_bytes 15
  @login_bytes @imei_bytes + 2
  @max_frame_bytes 1292
  @max_batch_frames 16
  @max_feed_bytes @login_bytes + @max_frame_bytes * @max_batch_frames

  defmodule Login do
    @moduledoc "Bounded partial IMEI negotiation state."

    @type t :: %__MODULE__{buffer: binary()}
    @enforce_keys [:buffer]
    defstruct [:buffer]
  end

  @type disposition :: :accepted | :duplicate | :rejected | :unknown
  @type reply :: {:send, binary()} | :close

  @doc "Returns an empty TCP login state."
  @spec new_login() :: Login.t()
  def new_login, do: %Login{buffer: <<>>}

  @doc "Feeds one bounded login chunk, retaining only an incomplete login."
  @spec feed_login(term(), term()) ::
          {:ok, Login.t()} | {:login, String.t(), binary()} | {:error, Error.t()}
  def feed_login(%Login{buffer: buffer}, chunk)
      when is_binary(buffer) and byte_size(buffer) < @login_bytes and is_binary(chunk) and
             byte_size(chunk) <= @max_feed_bytes do
    parse_login(buffer <> chunk)
  end

  def feed_login(%Login{}, chunk) when is_binary(chunk), do: fail(:limit_exceeded)
  def feed_login(_, _), do: fail(:invalid_input)

  @doc "Rejects EOF while a partial login remains buffered."
  @spec finish_login(term()) :: :ok | {:error, Error.t()}
  def finish_login(%Login{buffer: <<>>}), do: :ok

  def finish_login(%Login{buffer: buffer})
      when is_binary(buffer) and byte_size(buffer) < @login_bytes,
      do: fail(:malformed_frame, "/login")

  def finish_login(_), do: fail(:invalid_input)

  @doc "Encodes the one-byte server decision for a syntactically valid login."
  @spec login_reply(:accepted | :rejected) :: binary()
  def login_reply(:accepted), do: <<1>>
  def login_reply(:rejected), do: <<0>>

  @doc "Derives a fixed-size private configuration key from a valid IMEI."
  @spec identity_digest(term(), term()) :: {:ok, String.t()} | {:error, Error.t()}
  def identity_digest(imei, key) when is_binary(key) and byte_size(key) == 32 do
    if imei?(imei) do
      digest = :crypto.mac(:hmac, :sha256, key, ["wtr.teltonika-imei.v1:", imei])
      {:ok, Base.encode16(digest, case: :lower)}
    else
      fail(:invalid_input, "/imei")
    end
  end

  def identity_digest(_, _), do: fail(:invalid_input)

  @doc "Chooses a wire ACK only from the decoded count and durable outcome."
  @spec data_reply(term(), term()) :: {:ok, reply()} | {:error, Error.t()}
  def data_reply(count, disposition)
      when is_integer(count) and count in 1..33 and disposition in [:accepted, :duplicate] do
    with {:ok, acknowledgement} <- Codec8Extended.acknowledgement(count),
         do: {:ok, {:send, acknowledgement}}
  end

  def data_reply(count, :rejected) when is_integer(count) and count in 1..33,
    do: {:ok, {:send, <<0::unsigned-big-32>>}}

  def data_reply(count, :unknown) when is_integer(count) and count in 1..33,
    do: {:ok, :close}

  def data_reply(_, _), do: fail(:invalid_input)

  defp parse_login(bytes) when byte_size(bytes) < 2, do: {:ok, %Login{buffer: bytes}}

  defp parse_login(<<length::unsigned-big-16, _::binary>>) when length > @imei_bytes,
    do: fail(:limit_exceeded, "/login/length")

  defp parse_login(<<length::unsigned-big-16, _::binary>>) when length < @imei_bytes,
    do: fail(:malformed_frame, "/login/length")

  defp parse_login(bytes) when byte_size(bytes) < @login_bytes,
    do: {:ok, %Login{buffer: bytes}}

  defp parse_login(<<@imei_bytes::unsigned-big-16, imei::binary-size(@imei_bytes), tail::binary>>) do
    if imei?(imei), do: {:login, imei, tail}, else: fail(:malformed_frame, "/login/imei")
  end

  defp imei?(imei) when is_binary(imei) and byte_size(imei) == @imei_bytes,
    do: digits?(imei)

  defp imei?(_), do: false

  defp digits?(<<>>), do: true
  defp digits?(<<digit, rest::binary>>) when digit in ?0..?9, do: digits?(rest)
  defp digits?(_), do: false

  defp fail(code, path \\ "/"), do: {:error, Error.new(code, :decode, path)}
end
