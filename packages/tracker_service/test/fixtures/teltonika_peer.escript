#!/usr/bin/env escript
%%! -noinput
-mode(compile).

main([HostText, PortText, ImeiText, FrameHex]) ->
    {ok, Host} = inet:parse_address(HostText),
    Port = list_to_integer(PortText),
    Imei = list_to_binary(ImeiText),
    Frame = hex(FrameHex),
    Login = <<15:16/big-unsigned-integer, Imei/binary>>,
    <<0:32, _DataLength:32, _Codec, RecordCount, _/binary>> = Frame,
    Ack = <<RecordCount:32/big-unsigned-integer>>,

    ok = coalesced(Host, Port, Login, Frame, Ack),
    ok = split_logins(Host, Port, Login, Frame, Ack, 1),
    ok = split_frames(Host, Port, Login, Frame, Ack, 1),
    ok = concatenated(Host, Port, Login, Frame, Ack),
    io:format("ok ~B cases~n", [byte_size(Login) + byte_size(Frame)]),
    halt(0);
main(_) ->
    io:format(standard_error, "usage: teltonika_peer HOST PORT IMEI FRAME_HEX~n", []),
    halt(64).

coalesced(Host, Port, Login, Frame, Ack) ->
    {ok, Socket} = connect(Host, Port),
    ok = gen_tcp:send(Socket, <<Login/binary, Frame/binary>>),
    {ok, <<1>>} = gen_tcp:recv(Socket, 1, 2000),
    {ok, Ack} = gen_tcp:recv(Socket, 4, 2000),
    gen_tcp:close(Socket).

split_logins(_Host, _Port, Login, _Frame, _Ack, Split)
  when Split >= byte_size(Login) ->
    ok;
split_logins(Host, Port, Login, Frame, Ack, Split) ->
    {First, Second} = split_binary(Login, Split),
    {ok, Socket} = connect(Host, Port),
    ok = send_split(Socket, First, Second),
    {ok, <<1>>} = gen_tcp:recv(Socket, 1, 2000),
    ok = gen_tcp:send(Socket, Frame),
    {ok, Ack} = gen_tcp:recv(Socket, 4, 2000),
    ok = gen_tcp:close(Socket),
    split_logins(Host, Port, Login, Frame, Ack, Split + 1).

split_frames(_Host, _Port, _Login, Frame, _Ack, Split)
  when Split >= byte_size(Frame) ->
    ok;
split_frames(Host, Port, Login, Frame, Ack, Split) ->
    {First, Second} = split_binary(Frame, Split),
    {ok, Socket} = connect(Host, Port),
    ok = gen_tcp:send(Socket, Login),
    {ok, <<1>>} = gen_tcp:recv(Socket, 1, 2000),
    ok = send_split(Socket, First, Second),
    {ok, Ack} = gen_tcp:recv(Socket, 4, 2000),
    ok = gen_tcp:close(Socket),
    split_frames(Host, Port, Login, Frame, Ack, Split + 1).

concatenated(Host, Port, Login, Frame, Ack) ->
    {ok, Socket} = connect(Host, Port),
    ok = gen_tcp:send(Socket, Login),
    {ok, <<1>>} = gen_tcp:recv(Socket, 1, 2000),
    ok = gen_tcp:send(Socket, <<Frame/binary, Frame/binary>>),
    Expected = <<Ack/binary, Ack/binary>>,
    {ok, Expected} = gen_tcp:recv(Socket, 8, 2000),
    gen_tcp:close(Socket).

send_split(Socket, First, Second) ->
    ok = gen_tcp:send(Socket, First),
    timer:sleep(1),
    gen_tcp:send(Socket, Second).

connect(Host, Port) ->
    gen_tcp:connect(Host, Port, [binary, {active, false}, {nodelay, true}], 2000).

hex(Text) ->
    hex(Text, <<>>).

hex([], Acc) ->
    Acc;
hex([High, Low | Rest], Acc) ->
    hex(Rest, <<Acc/binary, (nibble(High) bsl 4 bor nibble(Low))>>).

nibble(Value) when Value >= $0, Value =< $9 -> Value - $0;
nibble(Value) when Value >= $A, Value =< $F -> Value - $A + 10;
nibble(Value) when Value >= $a, Value =< $f -> Value - $a + 10.
