%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for 4-node lumped thermal capacitance model.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_thermal_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

thermal_equilibrium_and_limits_test() ->
    S0 = apogee_thermal:new(),
    {T_SA, T_PL, T_AV, T_BT} = apogee_thermal:to_celsius(S0),
    ?assert(abs(T_SA - 20.0) < 1.0e-3),
    ?assert(abs(T_PL - 20.0) < 1.0e-3),
    ?assert(abs(T_AV - 20.0) < 1.0e-3),
    ?assert(abs(T_BT - 20.0) < 1.0e-3),
    ?assert(apogee_thermal:is_within_limits(S0)),

    % Test limit violation for overheated battery (> 45C)
    S_hot = S0#thermal_state{temp_battery_k = 325.0},
    ?assertNot(apogee_thermal:is_within_limits(S_hot)).

sunlight_heating_and_eclipse_cooling_test() ->
    S0 = apogee_thermal:new(),
    InternalHeat = #{avionics => 15.0, payload => 5.0, battery => 1.0},

    % Step 100 seconds in sunlight (200W solar flux)
    S1 = apogee_thermal:step_thermal(S0, 200.0, InternalHeat, 100.0),
    % Solar array should warm up
    ?assert(S1#thermal_state.temp_solar_array_k > S0#thermal_state.temp_solar_array_k),
    % Avionics should warm up due to internal dissipation
    ?assert(S1#thermal_state.temp_avionics_k > S0#thermal_state.temp_avionics_k),

    % Step 600 seconds in total eclipse (0W solar flux)
    S2 = apogee_thermal:step_thermal(S1, 0.0, #{avionics => 5.0, payload => 0.0, battery => 0.5}, 600.0),
    % Solar array should cool down significantly due to radiative heat loss to deep space
    ?assert(S2#thermal_state.temp_solar_array_k < S1#thermal_state.temp_solar_array_k).
