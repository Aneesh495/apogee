%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for real-time timed automata engine.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_timed_automata_tests).

-include_lib("eunit/include/eunit.hrl").

timed_automata_burn_sequence_test() ->
    % Model a rocket thruster burn sequence
    % idle -> arming -> firing -> cooldown
    TA0 = apogee_timed_automata:new(idle, [x]),
    
    % Invariant: arming cannot exceed 30 seconds
    TA1 = apogee_timed_automata:set_invariant(
        TA0,
        arming,
        fun(Clocks) -> maps:get(x, Clocks) =< 30.0 end
    ),

    % Transitions:
    % idle -> arming on 'arm', resets x
    TA2 = apogee_timed_automata:add_transition(
        TA1, idle, arm,
        fun(_Clocks) -> true end,
        [x], arming
    ),
    % arming -> firing on 'fire', requires x >= 5.0s, resets x
    TA3 = apogee_timed_automata:add_transition(
        TA2, arming, fire,
        fun(Clocks) -> maps:get(x, Clocks) >= 5.0 end,
        [x], firing
    ),
    % firing -> cooldown on 'shutdown', requires x >= 10.0s
    TA4 = apogee_timed_automata:add_transition(
        TA3, firing, shutdown,
        fun(Clocks) -> maps:get(x, Clocks) >= 10.0 end,
        [x], cooldown
    ),

    ?assertEqual(idle, apogee_timed_automata:current_location(TA4)),

    % Trigger arm -> transitions to arming, clock x is 0
    {ok, TA5} = apogee_timed_automata:trigger(TA4, arm),
    ?assertEqual(arming, apogee_timed_automata:current_location(TA5)),
    ?assertEqual(0.0, apogee_timed_automata:get_clock(TA5, x)),

    % Advance 3 seconds (x = 3.0)
    {ok, TA6} = apogee_timed_automata:advance_time(TA5, 3.0),
    ?assertEqual(3.0, apogee_timed_automata:get_clock(TA6, x)),

    % Attempt fire too early -> guard fails (x < 5.0)
    ?assertEqual({error, guard_not_satisfied}, apogee_timed_automata:trigger(TA6, fire)),

    % Advance another 3 seconds (x = 6.0 >= 5.0)
    {ok, TA7} = apogee_timed_automata:advance_time(TA6, 3.0),
    ?assertEqual(6.0, apogee_timed_automata:get_clock(TA7, x)),

    % Fire succeeds! Clock x resets to 0.0 in firing location
    {ok, TA8} = apogee_timed_automata:trigger(TA7, fire),
    ?assertEqual(firing, apogee_timed_automata:current_location(TA8)),
    ?assertEqual(0.0, apogee_timed_automata:get_clock(TA8, x)),

    % Burn for 12 seconds and shutdown
    {ok, TA9} = apogee_timed_automata:advance_time(TA8, 12.0),
    {ok, TA10} = apogee_timed_automata:trigger(TA9, shutdown),
    ?assertEqual(cooldown, apogee_timed_automata:current_location(TA10)).

location_invariant_violation_test() ->
    TA0 = apogee_timed_automata:new(arming, [x]),
    TA1 = apogee_timed_automata:set_invariant(
        TA0,
        arming,
        fun(Clocks) -> maps:get(x, Clocks) =< 10.0 end
    ),

    % Advance 8 seconds -> ok
    {ok, TA2} = apogee_timed_automata:advance_time(TA1, 8.0),
    ?assertEqual(8.0, apogee_timed_automata:get_clock(TA2, x)),

    % Advance 5 more seconds -> total 13s > 10s invariant -> error!
    ?assertEqual({error, invariant_violated}, apogee_timed_automata:advance_time(TA2, 5.0)).
