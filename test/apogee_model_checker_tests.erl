%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_model_checker (Explicit-State Verification).
%%%-------------------------------------------------------------------
-module(apogee_model_checker_tests).

-include_lib("eunit/include/eunit.hrl").

spacecraft_fsm_deadlock_free_test() ->
    Model = apogee_model_checker:build_spacecraft_fsm(),
    ?assertMatch({ok, _}, apogee_model_checker:verify_deadlock_freedom(Model)),
    {ok, Count} = apogee_model_checker:verify_deadlock_freedom(Model),
    ?assertEqual(5, Count).

deadlock_detection_test() ->
    Init = [state_a],
    Trans = #{
        state_a => [{step, state_b}],
        state_b => [] % Deadlock state
    },
    Model = apogee_model_checker:new_model(Init, Trans),
    ?assertEqual({error, {deadlock, state_b}}, apogee_model_checker:verify_deadlock_freedom(Model)).

safety_invariant_holds_test() ->
    Model = apogee_model_checker:build_spacecraft_fsm(),
    %% Invariant: Whenever in safe_hold, power must be low_power
    SafetyPred = fun
        ({safe_hold, Power, _}) -> Power =:= low_power;
        (_) -> true
    end,
    ?assertEqual(ok, apogee_model_checker:verify_safety(Model, SafetyPred)).

safety_invariant_violation_counterexample_test() ->
    Model = apogee_model_checker:build_spacecraft_fsm(),
    %% Invariant that fails: Never reach science_ops
    NoScience = fun
        ({science_ops, _, _}) -> false;
        (_) -> true
    end,
    Res = apogee_model_checker:verify_safety(Model, NoScience),
    ?assertMatch({error, {counterexample, _}}, Res),
    {error, {counterexample, Trace}} = Res,
    ?assertEqual({safe_hold, low_power, detumble}, hd(Trace)),
    ?assertEqual({science_ops, nominal_power, pointing}, lists:last(Trace)),
    ?assertEqual(4, length(Trace)).

liveness_reachability_test() ->
    Model = apogee_model_checker:build_spacecraft_fsm(),
    %% Liveness: From any reachable state, safe_hold must be reachable (contingency path)
    SafeHoldPred = fun({safe_hold, _, _}) -> true; (_) -> false end,
    ?assertEqual(ok, apogee_model_checker:verify_liveness_reachability(Model, SafeHoldPred)).

liveness_trap_detection_test() ->
    %% Model with a trap state where safe_hold cannot be reached
    Init = [state_s],
    Trans = #{
        state_s => [{go_trap, state_trap}, {go_safe, state_safe}],
        state_trap => [{spin, state_trap}],
        state_safe => [{reboot, state_s}]
    },
    Model = apogee_model_checker:new_model(Init, Trans),
    SafePred = fun(St) -> St =:= state_safe end,
    ?assertEqual({error, {unreachable_from, state_trap}},
                 apogee_model_checker:verify_liveness_reachability(Model, SafePred)).

add_transition_test() ->
    Init = [idle],
    M0 = apogee_model_checker:new_model(Init, #{}),
    M1 = apogee_model_checker:add_transition(M0, idle, run, active),
    M2 = apogee_model_checker:add_transition(M1, active, stop, idle),
    ?assertEqual({ok, 2}, apogee_model_checker:verify_deadlock_freedom(M2)).
