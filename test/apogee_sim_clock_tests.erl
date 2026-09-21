%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_sim_clock.
%%%-------------------------------------------------------------------
-module(apogee_sim_clock_tests).

-include_lib("eunit/include/eunit.hrl").

sim_clock_lifecycle_test() ->
    {ok, Pid} = apogee_sim_clock:start_link(100.0, 1.0),
    ?assertEqual(100.0, apogee_sim_clock:now_virtual()),
    ?assertEqual(1.0, apogee_sim_clock:get_time_scale()),
    ok = apogee_sim_clock:set_time_scale(5.0),
    ?assertEqual(5.0, apogee_sim_clock:get_time_scale()),
    ok = apogee_sim_clock:pause(),
    ok = apogee_sim_clock:resume(),
    ok = apogee_sim_clock:stop(Pid).

sim_clock_step_and_events_test() ->
    {ok, Pid} = apogee_sim_clock:start_link(0.0, 0.0), % zero scale so it only moves on step
    ok = apogee_sim_clock:pause(),
    
    %% Schedule events
    Ref1 = apogee_sim_clock:schedule_event(10.0, event_ten),
    Ref2 = apogee_sim_clock:schedule_event(25.0, event_twenty_five),

    %% Subscribe
    ok = apogee_sim_clock:subscribe(),

    %% Step 5 seconds: no events fired
    T1 = apogee_sim_clock:step(5.0),
    ?assertEqual(5.0, T1),
    receive
        {sim_tick, 5.0, 5.0} -> ok
    after 100 ->
        ?assert(false)
    end,

    %% Verify no sim_event yet
    receive
        {sim_event, _, _} -> ?assert(false)
    after 50 ->
        ok
    end,

    %% Step 10 seconds: reach 15.0, Ref1 should fire
    T2 = apogee_sim_clock:step(10.0),
    ?assertEqual(15.0, T2),
    receive
        {sim_event, Ref1, event_ten} -> ok
    after 100 ->
        ?assert(false)
    end,

    %% Step 15 seconds: reach 30.0, Ref2 should fire
    T3 = apogee_sim_clock:step(15.0),
    ?assertEqual(30.0, T3),
    receive
        {sim_event, Ref2, event_twenty_five} -> ok
    after 100 ->
        ?assert(false)
    end,

    ok = apogee_sim_clock:unsubscribe(),
    ok = apogee_sim_clock:stop(Pid).
