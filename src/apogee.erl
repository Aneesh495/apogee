%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Apogee top-level API.
%%% Exposes core helpers, version queries, and initialization hooks.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee).

-export([
    version/0,
    start/0,
    stop/0,
    info/0
]).

-include("apogee.hrl").

-spec version() -> binary().
version() ->
    <<"0.1.0">>.

-spec start() -> {ok, [atom()]} | {error, term()}.
start() ->
    application:ensure_all_started(apogee).

-spec stop() -> ok | {error, term()}.
stop() ->
    application:stop(apogee).

-spec info() -> map().
info() ->
    #{
        version => version(),
        earth_radius_km => ?EARTH_RADIUS_KM,
        earth_mu => ?EARTH_MU,
        speed_of_light_km_s => ?SPEED_OF_LIGHT_KM_S,
        dtn_version => ?BPV7_VERSION
    }.
