%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for Metric Temporal Logic (MTL) runtime monitor.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_mtl_tests).

-include_lib("eunit/include/eunit.hrl").

predicate_and_boolean_logic_test() ->
    Trace = [
        {0.0,  #{bus_voltage => 28.2, battery_temp => 22.0}},
        {5.0,  #{bus_voltage => 28.0, battery_temp => 24.0}},
        {10.0, #{bus_voltage => 27.8, battery_temp => 25.0}}
    ],

    % Predicate: bus_voltage >= 24.0 (satisfied with +4.2V margin at t=0)
    Phi1 = apogee_mtl:predicate(bus_voltage, {ge, 24.0}),
    ?assert(apogee_mtl:eval(Phi1, Trace, 0.0)),
    ?assert(abs(apogee_mtl:eval_robustness(Phi1, Trace, 0.0) - 4.2) < 1.0e-4),

    % Predicate: battery_temp <= 23.0 (satisfied at t=0, violated at t=10 with margin -2.0)
    Phi2 = apogee_mtl:predicate(battery_temp, {le, 23.0}),
    ?assert(apogee_mtl:eval(Phi2, Trace, 0.0)),
    ?assertNot(apogee_mtl:eval(Phi2, Trace, 10.0)),
    ?assert(abs(apogee_mtl:eval_robustness(Phi2, Trace, 10.0) - (-2.0)) < 1.0e-4),

    % Conjunction: bus_voltage >= 24.0 AND battery_temp <= 23.0
    PhiAnd = apogee_mtl:conj(Phi1, Phi2),
    ?assert(apogee_mtl:eval(PhiAnd, Trace, 0.0)),
    ?assertNot(apogee_mtl:eval(PhiAnd, Trace, 10.0)).

temporal_always_and_eventually_test() ->
    Trace = [
        {0.0,  #{battery_soc => 0.80, solar_w => 0.0}},
        {10.0, #{battery_soc => 0.70, solar_w => 0.0}},
        {20.0, #{battery_soc => 0.60, solar_w => 50.0}},
        {30.0, #{battery_soc => 0.75, solar_w => 50.0}}
    ],

    % G_[0, 30] (battery_soc >= 0.50): always above 50% in interval [0, 30]
    PhiAlways = apogee_mtl:always(0.0, 30.0, apogee_mtl:predicate(battery_soc, {ge, 0.50})),
    ?assert(apogee_mtl:eval(PhiAlways, Trace, 0.0)),
    % Minimum SoC is 0.60, so robustness is 0.60 - 0.50 = +0.10
    ?assert(abs(apogee_mtl:eval_robustness(PhiAlways, Trace, 0.0) - 0.10) < 1.0e-4),

    % G_[0, 30] (battery_soc >= 0.70) fails because it dips to 0.60
    PhiAlwaysFail = apogee_mtl:always(0.0, 30.0, apogee_mtl:predicate(battery_soc, {ge, 0.70})),
    ?assertNot(apogee_mtl:eval(PhiAlwaysFail, Trace, 0.0)),
    ?assert(abs(apogee_mtl:eval_robustness(PhiAlwaysFail, Trace, 0.0) - (-0.10)) < 1.0e-4),

    % F_[0, 30] (solar_w >= 40.0): eventually sees sunlight within 30s
    PhiEventually = apogee_mtl:eventually(0.0, 30.0, apogee_mtl:predicate(solar_w, {ge, 40.0})),
    ?assert(apogee_mtl:eval(PhiEventually, Trace, 0.0)),
    % Peak is 50W, so robustness is 50 - 40 = +10.0
    ?assert(abs(apogee_mtl:eval_robustness(PhiEventually, Trace, 0.0) - 10.0) < 1.0e-4).
