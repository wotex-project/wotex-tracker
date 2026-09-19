%% Device implementation is statically linked by Mob. Host development keeps
%% this module loadable and exposes only explicit nif_not_loaded failures.
-module(wotex_secure_store_nif).
-export([fetch/1, put/2, delete/1]).
-on_load(init/0).

init() ->
    case erlang:load_nif("wotex_secure_store_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

fetch(_Key) ->
    erlang:nif_error(nif_not_loaded).

put(_Key, _Value) ->
    erlang:nif_error(nif_not_loaded).

delete(_Key) ->
    erlang:nif_error(nif_not_loaded).
