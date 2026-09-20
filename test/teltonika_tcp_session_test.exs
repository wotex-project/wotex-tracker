defmodule Wotex.Tracker.TeltonikaTCPSessionTest do
  use ExUnit.Case, async: true

  alias Wotex.Tracker.Error
  alias Wotex.Tracker.Protocols.Teltonika.TCPSession
  alias Wotex.Tracker.Protocols.Teltonika.TCPSession.Login

  @imei "123456789012345"
  @login <<15::unsigned-big-16, @imei::binary>>

  test "login negotiation survives every split boundary and preserves coalesced data" do
    for split <- 0..(byte_size(@login) - 1) do
      <<first::binary-size(^split), second::binary>> = @login
      assert {:ok, state} = TCPSession.feed_login(TCPSession.new_login(), first)
      assert {:login, @imei, <<1, 2, 3>>} = TCPSession.feed_login(state, second <> <<1, 2, 3>>)
    end

    {state, result} =
      @login
      |> :binary.bin_to_list()
      |> Enum.reduce({TCPSession.new_login(), nil}, fn byte, {state, _result} ->
        case TCPSession.feed_login(state, <<byte>>) do
          {:ok, next} -> {next, nil}
          {:login, @imei, <<>>} = login -> {state, login}
        end
      end)

    assert %Login{} = state
    assert {:login, @imei, <<>>} = result
    assert :ok = TCPSession.finish_login(TCPSession.new_login())
  end

  test "login EOF, length, digits, state and feed size fail with typed bounds" do
    for size <- 1..(byte_size(@login) - 1) do
      bytes = binary_part(@login, 0, size)
      assert {:ok, state} = TCPSession.feed_login(TCPSession.new_login(), bytes)

      assert {:error, %Error{code: :malformed_frame, path: "/login"}} =
               TCPSession.finish_login(state)
    end

    assert {:error, %Error{code: :malformed_frame, path: "/login/length"}} =
             TCPSession.feed_login(TCPSession.new_login(), <<14::16>>)

    assert {:error, %Error{code: :limit_exceeded, path: "/login/length"}} =
             TCPSession.feed_login(TCPSession.new_login(), <<16::16>>)

    assert {:error, %Error{code: :malformed_frame, path: "/login/imei"}} =
             TCPSession.feed_login(
               TCPSession.new_login(),
               <<15::16, "12345678901234x">>
             )

    assert {:error, %Error{code: :limit_exceeded}} =
             TCPSession.feed_login(TCPSession.new_login(), :binary.copy(<<0>>, 20_690))

    assert {:error, %Error{code: :limit_exceeded}} =
             TCPSession.feed_login(%Login{buffer: @login}, <<>>)

    assert {:error, %Error{code: :invalid_input}} = TCPSession.feed_login(:forged, <<>>)
    assert {:error, %Error{code: :invalid_input}} = TCPSession.feed_login(Login, :forged)
    assert {:error, %Error{code: :invalid_input}} = TCPSession.finish_login(:forged)
    assert {:error, %Error{code: :invalid_input}} = TCPSession.finish_login(%Login{buffer: :bad})
  end

  test "login replies and keyed identity lookup retain no raw identifier" do
    key = :binary.copy(<<7>>, 32)

    assert TCPSession.login_reply(:accepted) == <<1>>
    assert TCPSession.login_reply(:rejected) == <<0>>

    assert {:ok, digest} = TCPSession.identity_digest(@imei, key)
    assert digest == "f486c0fcb20b79bf7f46e5c950f1850efa051eb94e56c22984807c60560b98f1"
    refute digest =~ @imei

    assert {:ok, other} = TCPSession.identity_digest("123456789012346", key)
    refute other == digest

    assert {:error, %Error{code: :invalid_input, path: "/imei"}} =
             TCPSession.identity_digest("123", key)

    assert {:error, %Error{code: :invalid_input}} =
             TCPSession.identity_digest(@imei, :binary.copy(<<0>>, 31))
  end

  test "data acknowledgement is derived from the durable commit disposition" do
    for disposition <- [:accepted, :duplicate] do
      assert {:ok, {:send, <<0, 0, 0, 3>>}} = TCPSession.data_reply(3, disposition)
    end

    assert {:ok, {:send, <<0, 0, 0, 0>>}} = TCPSession.data_reply(3, :rejected)
    assert {:ok, :close} = TCPSession.data_reply(3, :unknown)

    for invalid <- [0, 34, "1", nil] do
      assert {:error, %Error{code: :invalid_input}} = TCPSession.data_reply(invalid, :accepted)
    end

    assert {:error, %Error{code: :invalid_input}} = TCPSession.data_reply(1, :decoded)
  end
end
