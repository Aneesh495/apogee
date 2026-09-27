%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_chaos (Aerospace Fault Injector).
%%%-------------------------------------------------------------------
-module(apogee_chaos_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

seu_bit_flip_test() ->
    Data = <<0:64>>,
    Flipped = apogee_chaos:inject_seu(Data, 1),
    ?assertNotEqual(Data, Flipped),
    ?assertEqual(8, byte_size(Flipped)),
    %% Zero flips should return identical binary
    ?assertEqual(Data, apogee_chaos:inject_seu(Data, 0)).

burst_error_test() ->
    Data = <<0:16>>,
    %% Flip 3 bits starting at bit 2
    Burst = apogee_chaos:inject_burst_errors(Data, 2, 3),
    ?assertNotEqual(Data, Burst),
    %% Bit 2, 3, 4 should be 1: 00111000 00000000 = 0x3800
    ?assertEqual(<<16#38, 16#00>>, Burst).

gilbert_elliott_channel_test() ->
    %% Always good channel with 0% loss
    ChanGood = apogee_chaos:new_gilbert_elliott(0.0, 1.0, 0.0, 1.0),
    Pkts = [1, 2, 3, 4, 5],
    {DeliveredGood, _} = apogee_chaos:gilbert_elliott_filter(ChanGood, Pkts),
    ?assertEqual(5, length(DeliveredGood)),

    %% Always bad channel with 100% loss
    ChanBad0 = apogee_chaos:new_gilbert_elliott(1.0, 0.0, 1.0, 1.0),
    {_, ChanBad1} = apogee_chaos:gilbert_elliott_filter(ChanBad0, [1]),
    {DeliveredBad, _} = apogee_chaos:gilbert_elliott_filter(ChanBad1, [2, 3, 4]),
    ?assertEqual(0, length(DeliveredBad)).

solar_storm_test() ->
    Eps0 = #eps_state{
        solar_array_area_m2 = 1.0,
        temperature_c = 20.0,
        mode = normal
    },
    %% Storm with K-index 8.0 (severe)
    EpsStorm = apogee_chaos:solar_storm(8.0, Eps0),
    ?assert(EpsStorm#eps_state.solar_array_area_m2 < 1.0),
    ?assert(EpsStorm#eps_state.temperature_c > 20.0),
    ?assertEqual(degraded, EpsStorm#eps_state.mode).

atmospheric_drag_surge_test() ->
    Tle0 = #tle{bstar = 0.0001},
    TleStorm = apogee_chaos:atmospheric_drag_surge(2.5, Tle0),
    ?assertEqual(0.00025, TleStorm#tle.bstar).

subsystem_failures_test() ->
    Adcs0 = #adcs_state{
        wheel_momentum = #vector3{x = 0.05, y = 0.04, z = 0.03},
        wheel_speed_rpm = #vector3{x = 3000.0, y = 2500.0, z = 2000.0},
        mode = sun_pointing
    },
    AdcsFailed = apogee_chaos:fail_reaction_wheel(y, Adcs0),
    ?assertEqual(0.0, (AdcsFailed#adcs_state.wheel_momentum)#vector3.y),
    ?assertEqual(0.0, (AdcsFailed#adcs_state.wheel_speed_rpm)#vector3.y),
    ?assertEqual(0.05, (AdcsFailed#adcs_state.wheel_momentum)#vector3.x),
    ?assertEqual(safe_hold, AdcsFailed#adcs_state.mode),

    Eps0 = #eps_state{
        battery_capacity_wh = 100.0,
        battery_soc = 0.9,
        bus_voltage = 28.0
    },
    EpsFailed = apogee_chaos:fail_battery_cell(20.0, Eps0),
    ?assertEqual(80.0, EpsFailed#eps_state.battery_capacity_wh),
    ?assert(EpsFailed#eps_state.battery_soc < 0.9),
    ?assert(EpsFailed#eps_state.bus_voltage =< 24.0).
