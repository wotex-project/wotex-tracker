%% Device implementation is statically linked by Mob. Host development keeps
%% this module loadable and exposes only explicit nif_not_loaded failures.
-module(wotex_ble_central_nif).
-export([scan/3, stop_scan/1, connect/2, disconnect/2, discover/3, read/4, write/5]).
-on_load(init/0).

init() ->
    case erlang:load_nif("wotex_ble_central_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

scan(_Request, _ServiceUUIDs, _TimeoutMs) -> erlang:nif_error(nif_not_loaded).
stop_scan(_Request) -> erlang:nif_error(nif_not_loaded).
connect(_Request, _Peripheral) -> erlang:nif_error(nif_not_loaded).
disconnect(_Request, _Peripheral) -> erlang:nif_error(nif_not_loaded).
discover(_Request, _Peripheral, _ServiceUUIDs) -> erlang:nif_error(nif_not_loaded).
read(_Request, _Peripheral, _ServiceUUID, _CharacteristicUUID) -> erlang:nif_error(nif_not_loaded).
write(_Request, _Peripheral, _ServiceUUID, _CharacteristicUUID, _Value) -> erlang:nif_error(nif_not_loaded).
