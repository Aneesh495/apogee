%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_ground_station.
%%%-------------------------------------------------------------------
-module(apogee_ground_station_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

known_stations_test() ->
    Stations = apogee_ground_station:known_stations(),
    ?assert(length(Stations) >= 4),
    Svalbard = hd(Stations),
    ?assertEqual(<<"SGS-Svalbard">>, Svalbard#ground_station.id),
    ?assertEqual(5.0, Svalbard#ground_station.min_elevation_deg).

look_angles_test() ->
    Station = apogee_ground_station:new_station(
        <<"TEST-EQUATOR">>,
        #geodetic{lat = 0.0, lon = 0.0, alt = 0.0},
        10.0
    ),
    %% Satellite directly overhead at 500 km altitude: (R_earth + 500, 0, 0)
    SatOverheadEcef = #vector3{x = ?EARTH_RADIUS_KM + 500.0, y = 0.0, z = 0.0},
    Angles = apogee_ground_station:ground_look_angles(Station, SatOverheadEcef),
    ?assert(maps:get(elevation_deg, Angles) > 89.0),
    ?assert(maps:get(range_km, Angles) < 505.0),
    ?assert(apogee_ground_station:is_satellite_in_view(Station, SatOverheadEcef, 2451545.0)).

pass_prediction_test() ->
    L1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927",
    L2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    {ok, Tle} = apogee_tle:parse(L1, L2),

    Station = apogee_ground_station:new_station(
        <<"SGS">>,
        #geodetic{lat = 51.64, lon = 20.0, alt = 0.1},
        5.0,
        100000000.0
    ),
    
    %% Predict over 3 hours (about 2 orbits)
    StartJD = apogee_tle:epoch_to_jd(Tle#tle.epoch_year, Tle#tle.epoch_day),
    EndJD = StartJD + (3.0 / 24.0),
    Passes = apogee_ground_station:predict_passes(Station, Tle, StartJD, EndJD, 30.0),
    ?assert(length(Passes) >= 1),
    FirstPass = hd(Passes),
    ?assertEqual(<<"SGS">>, FirstPass#ground_pass.station_id),
    ?assert(FirstPass#ground_pass.max_elevation_deg >= 5.0),
    ?assert(FirstPass#ground_pass.capacity_bytes > 0).

gen_server_tracking_and_downlink_test() ->
    Station = apogee_ground_station:new_station(
        <<"WSS">>,
        #geodetic{lat = 32.5, lon = -106.6, alt = 1.45},
        5.0
    ),
    {ok, Pid} = apogee_ground_station:start_link(Station),
    ?assertEqual(Station, apogee_ground_station:get_station(Pid)),

    SatOverhead = #vector3{x = -1950.0, y = -6540.0, z = 3700.0},
    TrackRes = apogee_ground_station:track(Pid, SatOverhead, 2451545.0),
    ?assert(TrackRes =:= not_in_view orelse element(1, TrackRes) =:= in_view),

    ok = apogee_ground_station:ingest_downlink(Pid, <<"TelemetryFrame#1">>),
    ok = apogee_ground_station:ingest_downlink(Pid, <<"TelemetryFrame#2">>),
    Data = apogee_ground_station:get_downlinked_data(Pid),
    ?assertEqual([<<"TelemetryFrame#1">>, <<"TelemetryFrame#2">>], Data),

    Metrics = apogee_ground_station:get_metrics(Pid),
    ?assertEqual(32, maps:get(downlink_bytes, Metrics)),
    ?assertEqual(2, maps:get(packet_count, Metrics)),

    ok = apogee_ground_station:stop(Pid).
