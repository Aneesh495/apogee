%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Apogee OTP Application Callback
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    apogee_sup:start_link().

stop(_State) ->
    ok.
