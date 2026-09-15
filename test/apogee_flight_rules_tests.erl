%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for flight rules and FDIR safety engine.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_flight_rules_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

nominal_telemetry_test() ->
    Nominal = #{
        battery_soc => 0.85,
        bus_voltage => 28.2,
        temp_c => #{battery => 22.0, avionics => 25.0},
        angular_velocity => #vector3{x = 0.01, y = 0.01, z = 0.0},
        wheel_speed_rpm => #vector3{x = 1200.0, y = 800.0, z = 500.0},
        command_loss_s => 100
    },
    ?assertEqual([], apogee_flight_rules:check_telemetry(Nominal)),
    ?assertEqual(nominal, apogee_flight_rules:evaluate_health(Nominal)),
    ?assertEqual(none, apogee_flight_rules:recommended_action(Nominal)).

critical_battery_rule_test() ->
    LowBattery = #{
        battery_soc => 0.15,
        bus_voltage => 21.5,
        temp_c => #{battery => 20.0}
    },
    Violations = apogee_flight_rules:check_telemetry(LowBattery),
    ?assert(length(Violations) >= 1),
    ?assertEqual(critical, apogee_flight_rules:evaluate_health(LowBattery)),
    ?assertEqual(safe_hold, apogee_flight_rules:recommended_action(LowBattery)).

adcs_tumbling_and_wheel_saturation_test() ->
    Tumbling = #{
        angular_velocity => #vector3{x = 0.25, y = 0.0, z = 0.0}
    },
    ?assertEqual(warning, apogee_flight_rules:evaluate_health(Tumbling)),
    ?assertEqual(detumble, apogee_flight_rules:recommended_action(Tumbling)),

    Saturated = #{
        angular_velocity => #vector3{x = 0.0, y = 0.0, z = 0.0},
        wheel_speed_rpm => #vector3{x = 5800.0, y = 1000.0, z = 500.0}
    },
    ?assertEqual(warning, apogee_flight_rules:evaluate_health(Saturated)),
    ?assertEqual(desaturate, apogee_flight_rules:recommended_action(Saturated)).

thermal_overheat_rule_test() ->
    Overheat = #{
        temp_c => #{battery => 52.0}
    },
    ?assertEqual(critical, apogee_flight_rules:evaluate_health(Overheat)),
    ?assertEqual(shed_payload, apogee_flight_rules:recommended_action(Overheat)).
