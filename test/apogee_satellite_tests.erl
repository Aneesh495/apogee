%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for top-level autonomous satellite coordinator.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_satellite_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

satellite_simulation_step_test() ->
    Line1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927",
    Line2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    {ok, TLE} = apogee_tle:parse(Line1, Line2),

    {ok, Pid} = apogee_satellite:start_link(<<"apogee-1">>, TLE, [{start_jd, 2451545.0}]),
    
    Telem0 = apogee_satellite:get_telemetry(Pid),
    ?assertEqual(<<"apogee-1">>, maps:get(sat_id, Telem0)),
    ?assertEqual(science_ops, maps:get(mode, Telem0)),
    ?assertEqual(0, maps:get(total_steps, Telem0)),

    % Step 60 seconds
    {ok, Telem1} = apogee_satellite:step(Pid, 60.0),
    ?assertEqual(1, maps:get(total_steps, Telem1)),
    % Position should have moved along orbit
    Pos0 = maps:get(pos_km, Telem0),
    Pos1 = maps:get(pos_km, Telem1),
    ?assert(apogee_vec3:distance(Pos0, Pos1) > 100.0),

    % Battery and thermal should be populated
    ?assert(maps:get(battery_soc, Telem1) > 0.0),
    ?assert(maps:is_key(temp_c, Telem1)),

    % Manual mode change
    ?assertEqual(ok, apogee_satellite:set_mode(Pid, ground_downlink)),
    Telem2 = apogee_satellite:get_telemetry(Pid),
    ?assertEqual(ground_downlink, maps:get(mode, Telem2)),

    ok = apogee_satellite:stop(Pid).
