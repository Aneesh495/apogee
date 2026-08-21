%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for Electrical Power Subsystem (EPS).
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_eps_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

sun_position_and_eclipse_test() ->
    JD = 2451545.0, % J2000 epoch
    SunPos = apogee_eps:sun_position_eci(JD),
    Dist = apogee_vec3:magnitude(SunPos),
    % Distance should be approximately 1 AU (~149.6 million km)
    ?assert(Dist > 147000000.0 andalso Dist < 152000000.0),

    % Satellite at LEO 7000 km on the day side
    SatDay = #vector3{x = 7000.0, y = 0.0, z = 0.0},
    ?assertEqual(1.0, apogee_eps:eclipse_factor(SatDay, SunPos)),

    % Satellite at LEO 7000 km directly behind Earth on night side
    SatNight = apogee_vec3:scale(apogee_vec3:normalize(SunPos), -7000.0),
    ?assertEqual(0.0, apogee_eps:eclipse_factor(SatNight, SunPos)).

solar_power_generation_test() ->
    EPS = apogee_eps:new([
        {solar_array_area_m2, 0.5},
        {solar_array_normal, #vector3{x = 1.0, y = 0.0, z = 0.0}}
    ]),
    SunPos = #vector3{x = 1.5e8, y = 0.0, z = 0.0},
    SatPos = #vector3{x = 7000.0, y = 0.0, z = 0.0},
    
    % Aligned attitude: solar normal points directly at Sun
    IdentityAtt = apogee_mat3:identity(),
    Power = apogee_eps:solar_power_generated(EPS, SatPos, SunPos, IdentityAtt),
    % 0.5 m^2 * 1361 W/m^2 * 0.30 efficiency = 204.15 W
    ?assert(abs(Power - 204.15) < 1.0),

    % In full eclipse -> power is zero
    SatEclipse = #vector3{x = -7000.0, y = 0.0, z = 0.0},
    ?assertEqual(0.0, apogee_eps:solar_power_generated(EPS, SatEclipse, SunPos, IdentityAtt)).

battery_charge_and_load_shedding_test() ->
    EPS0 = apogee_eps:new([{battery_capacity_wh, 100.0}, {battery_soc, 0.60}]),
    ?assertEqual(normal, apogee_eps:power_mode(EPS0)),

    % Excess power: 50W solar, 20W load -> 30W surplus for 3600s = 30 Wh added
    % SoC goes from 60 Wh to 90 Wh (0.90 SoC)
    {EPS1, _} = apogee_eps:step_power(EPS0, 50.0, 20.0, 3600.0),
    ?assert(abs(EPS1#eps_state.battery_soc - 0.90) < 1.0e-3),
    ?assertEqual(normal, apogee_eps:power_mode(EPS1)),

    % High load in eclipse (0W solar, 50W load for 3600s) -> 50 Wh drained
    % SoC goes from 90 Wh to 40 Wh (0.40 SoC) -> Degraded mode
    {EPS2, _} = apogee_eps:step_power(EPS1, 0.0, 50.0, 3600.0),
    ?assert(abs(EPS2#eps_state.battery_soc - 0.40) < 1.0e-3),
    ?assertEqual(degraded, apogee_eps:power_mode(EPS2)),

    % Further drain to critical (< 0.25 SoC)
    {EPS3, _ActualLoad} = apogee_eps:step_power(EPS2, 0.0, 30.0, 3600.0),
    ?assert(EPS3#eps_state.battery_soc < 0.25),
    ?assertEqual(critical, apogee_eps:power_mode(EPS3)),
    % In critical mode, next step request should shed down to 8.0W
    {_EPS4, ShedLoad} = apogee_eps:step_power(EPS3, 0.0, 100.0, 10.0),
    ?assertEqual(8.0, ShedLoad).
