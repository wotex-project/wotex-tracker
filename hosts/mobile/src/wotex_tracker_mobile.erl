%% Native BEAM bootstrap invoked by the Mob iOS launcher.
-module(wotex_tracker_mobile).
-export([start/0]).

start() ->
    start_required(compiler),
    start_required(elixir),
    start_required(logger),
    _ = mob_nif:platform(),
    case 'Elixir.Wotex.Tracker.Mobile.MobApp':start() of
        {ok, _Pid} -> timer:sleep(infinity);
        _ -> erlang:error(native_runtime_unavailable)
    end.

start_required(Application) ->
    case application:ensure_all_started(Application) of
        {ok, _} -> ok;
        {error, {already_started, Application}} -> ok;
        {error, _} -> erlang:error(native_runtime_unavailable)
    end.
