%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_tui (Mission Control Terminal Dashboard).
%%%-------------------------------------------------------------------
-module(apogee_tui_tests).

-include_lib("eunit/include/eunit.hrl").

progress_bar_test() ->
    Bar0 = apogee_tui:progress_bar(0.0, 10, "="),
    ?assertEqual("[          ]", Bar0),

    BarFull = apogee_tui:progress_bar(1.0, 10, "="),
    ?assertEqual("[==========]", BarFull),

    BarHalf = apogee_tui:progress_bar(0.5, 10, "="),
    ?assertEqual("[=====     ]", BarHalf),

    %% Test clamping
    BarOver = apogee_tui:progress_bar(1.5, 10, "="),
    ?assertEqual("[==========]", BarOver),
    BarUnder = apogee_tui:progress_bar(-0.5, 10, "="),
    ?assertEqual("[          ]", BarUnder).

status_badge_test() ->
    Nom = apogee_tui:status_badge(nominal),
    ?assert(is_list(Nom)),
    ?assert(string:find(Nom, "NOMINAL") =/= nomatch),

    Warn = apogee_tui:status_badge(warning),
    ?assert(string:find(Warn, "WARNING") =/= nomatch),

    Crit = apogee_tui:status_badge(critical),
    ?assert(string:find(Crit, "CRITICAL") =/= nomatch).

box_panel_test() ->
    Lines = ["First line", "Second line of text"],
    Boxed = apogee_tui:box_panel("TEST PANEL", Lines, 40),
    ?assert(length(Boxed) >= 4),
    Header = hd(Boxed),
    ?assert(string:find(Header, "+- TEST PANEL") =/= nomatch),
    ?assertEqual(40, length(Header)),
    Footer = lists:last(Boxed),
    ?assertEqual(40, length(Footer)).

dashboard_rendering_test() ->
    Telem = #{
        sat_name => "APOGEE-TEST",
        met_str => "+001:05:22:10.0",
        flight_mode => nominal,
        altitude_km => 520.5,
        velocity_km_s => 7.61,
        latitude_deg => -12.4,
        longitude_deg => 45.2,
        battery_soc => 0.95,
        bus_voltage => 28.2,
        solar_power_w => 155.0,
        battery_temp_c => 18.2,
        wheel_rpm_x => 2100,
        wheel_rpm_y => 1950,
        wheel_rpm_z => 2800,
        pointing_err_deg => 0.025,
        bundles_queued => 12,
        storage_used_mb => 34.5,
        active_contacts => 1,
        fdir_alarms => 0
    },

    Plain = apogee_tui:render_dashboard_plain(Telem),
    ?assert(is_list(Plain)),
    ?assert(string:find(Plain, "APOGEE-TEST") =/= nomatch),
    ?assert(string:find(Plain, "ORBIT & EPHEMERIS") =/= nomatch),
    ?assert(string:find(Plain, "ELECTRICAL POWER SYSTEM") =/= nomatch),
    ?assert(string:find(Plain, "ATTITUDE DETERMINATION") =/= nomatch),
    ?assert(string:find(Plain, "DELAY-TOLERANT NETWORKING") =/= nomatch),
    ?assert(string:find(Plain, "520.50 km") =/= nomatch),

    Ansi = apogee_tui:render_dashboard(Telem),
    ?assert(is_list(Ansi)),
    ?assert(length(Ansi) > length(Plain)).

gen_server_lifecycle_test() ->
    {ok, Pid} = apogee_tui:start_link(#{sat_name => "ORBITER-1"}),
    ok = apogee_tui:update_telemetry(Pid, #{altitude_km => 560.0}),
    ok = apogee_tui:stop(Pid).
