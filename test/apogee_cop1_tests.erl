%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_cop1 FARM-1 state machine
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cop1_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

farm1_lifecycle_test() ->
    {ok, Farm} = apogee_cop1:start_link(#{scid => 1, vcid => 0, initial_vr => 0, window_w => 5}),
    ?assertEqual({open, 0}, apogee_cop1:get_state(Farm)),
    
    %% Frame 0: In-sequence
    F0 = apogee_tc:new_frame(0, 1, 0, 0, <<"CMD_0">>),
    ?assertEqual({accepted, <<"CMD_0">>}, apogee_cop1:process_frame(Farm, F0)),
    ?assertEqual({open, 1}, apogee_cop1:get_state(Farm)),

    %% Frame 1: In-sequence
    F1 = apogee_tc:new_frame(0, 1, 0, 1, <<"CMD_1">>),
    ?assertEqual({accepted, <<"CMD_1">>}, apogee_cop1:process_frame(Farm, F1)),
    ?assertEqual({open, 2}, apogee_cop1:get_state(Farm)),

    %% Duplicate Frame 1: Should report duplicate
    ?assertEqual({duplicate, 2}, apogee_cop1:process_frame(Farm, F1)),
    CLCW1 = apogee_cop1:get_clcw(Farm),
    ?assert(CLCW1#clcw.retransmit),

    %% Frame Gap: Send Frame 4 instead of Frame 2 (gap of 2 frames)
    F4 = apogee_tc:new_frame(0, 1, 0, 4, <<"CMD_4">>),
    ?assertEqual({rejected, frame_gap}, apogee_cop1:process_frame(Farm, F4)),

    %% Lockout Anomaly: Send Frame 50 (far outside window of 5)
    F50 = apogee_tc:new_frame(0, 1, 0, 50, <<"CMD_50">>),
    ?assertEqual({rejected, lockout_anomaly}, apogee_cop1:process_frame(Farm, F50)),
    ?assertEqual({lockout, 2}, apogee_cop1:get_state(Farm)),
    CLCW_Lockout = apogee_cop1:get_clcw(Farm),
    ?assert(CLCW_Lockout#clcw.lockout),

    %% Subsequent AD frame rejected in lockout
    ?assertEqual({rejected, in_lockout}, apogee_cop1:process_frame(Farm, F0)),

    %% Expedited frame accepted even in lockout
    F_Expedited = apogee_tc:new_frame(1, 1, 0, 0, <<"EXPEDITED_RESET">>),
    ?assertEqual({accepted, <<"EXPEDITED_RESET">>}, apogee_cop1:process_frame(Farm, F_Expedited)),

    %% UNLOCK control command recovers to OPEN
    UnlockCmd = apogee_tc:new_control_command(1, 0, <<16#00>>),
    ?assertEqual({accepted, unlocked}, apogee_cop1:process_frame(Farm, UnlockCmd)),
    ?assertEqual({open, 2}, apogee_cop1:get_state(Farm)),

    %% SET V(R) control command sets V(R) to 100
    SetVRCmd = apogee_tc:new_control_command(1, 0, <<16#01, 100:8/unsigned>>),
    ?assertEqual({accepted, {set_vr, 100}}, apogee_cop1:process_frame(Farm, SetVRCmd)),
    ?assertEqual({open, 100}, apogee_cop1:get_state(Farm)),

    ok = apogee_cop1:stop(Farm).
