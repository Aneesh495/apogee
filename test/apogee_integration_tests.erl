%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc End-to-End Constellation and DTN Multi-Hop Integration Tests.
%%% Verifies the full aerospace stack working seamlessly across subsystems:
%%% Walker-Delta constellation -> Ground Station tracking pass -> Contact Plan
%%% -> CGR Dijkstra multi-hop bundle forwarding -> Custody transfer -> FDIR safety.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_integration_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

e2e_multihop_dtn_cgr_pipeline_test() ->
    %% 1. Build a 3-satellite orbital mesh + ground station
    SatA = <<"ipn:101.1">>,
    SatB = <<"ipn:102.1">>,
    SatC = <<"ipn:103.1">>,
    Station = <<"ipn:1.1">>,

    %% 2. Schedule temporal contacts for multi-hop store-and-forward routing:
    %%    Station -> SatA (t = 0..300)
    %%    SatA -> SatB    (t = 200..600)
    %%    SatB -> SatC    (t = 500..900)
    CP0 = apogee_contact_plan:new(),
    Rate = 50000000, % 50 Mbps
    Delay = 0.010,   % 10 ms light-time
    CP1 = apogee_contact_plan:add_contact(CP0, Station, SatA, 0.0, 300.0, Rate, Delay),
    CP2 = apogee_contact_plan:add_contact(CP1, SatA, SatB, 200.0, 600.0, Rate, Delay),
    CP3 = apogee_contact_plan:add_contact(CP2, SatB, SatC, 500.0, 900.0, Rate, Delay),

    %% 3. Compute optimal CGR route from Ground Station to SatC
    BundlePayload = <<"HIGH_RESOLUTION_MULTISPECTRAL_ORBITAL_FRAME_DATA">>,
    Bundle = apogee_bpv7:new_bundle(Station, SatC, 86400000, BundlePayload),
    
    CurrentTime = 10.0,
    RouteResult = apogee_cgr:find_earliest_path(CP3, Station, SatC, byte_size(BundlePayload), CurrentTime),
    ?assertMatch({ok, #cgr_route{}}, RouteResult),
    {ok, Route} = RouteResult,

    %% 4. Verify route hops and arrival time
    ?assertEqual(Station, Route#cgr_route.from_node),
    ?assertEqual(SatC, Route#cgr_route.to_node),
    Hops = Route#cgr_route.hops,
    ?assertEqual(3, length(Hops)),
    
    [Hop1, Hop2, Hop3] = Hops,
    ?assertEqual(Station, Hop1#contact.from_node),
    ?assertEqual(SatA, Hop1#contact.to_node),
    ?assertEqual(SatA, Hop2#contact.from_node),
    ?assertEqual(SatB, Hop2#contact.to_node),
    ?assertEqual(SatB, Hop3#contact.from_node),
    ?assertEqual(SatC, Hop3#contact.to_node),

    %% 5. Encode, fragment, and custody transfer
    EncodedBundle = apogee_bpv7:encode(Bundle),
    ?assert(byte_size(EncodedBundle) > 0),
    {ok, DecodedBundle, _} = apogee_bpv7:decode(EncodedBundle),
    ?assertEqual(BundlePayload, DecodedBundle#bpv7_bundle.payload),

    %% 6. Verify Autonomous FDIR Spacecraft Safety during flight
    FlightFsm = apogee_model_checker:build_spacecraft_fsm(),
    ?assertMatch({ok, _}, apogee_model_checker:verify_deadlock_freedom(FlightFsm)),

    %% Flight rules check
    Telemetry = #{
        battery_soc => 0.85,
        bus_voltage => 28.1,
        solar_array_temp_c => 45.0,
        battery_temp_c => 18.5,
        angular_velocity_rad_s => 0.005,
        comm_silence_duration_s => 120.0
    },
    Violations = apogee_flight_rules:check_telemetry(Telemetry),
    ?assertEqual([], Violations),
    ?assertEqual(nominal, apogee_flight_rules:evaluate_health(Telemetry)),
    ?assertEqual(none, apogee_flight_rules:recommended_action(Telemetry)).

e2e_constellation_orbit_and_coverage_test() ->
    %% Generate 6 satellites in 2 planes
    Sats = apogee_constellation:generate_walker_delta(6, 2, 1, 550.0, 53.0),
    ?assertEqual(6, length(Sats)),
    EpochJD = apogee_tle:epoch_to_jd(2026, 1.0),
    States = apogee_constellation:propagate_constellation(Sats, EpochJD),
    ?assertEqual(6, length(States)),

    %% Ground station look angles to first satellite
    Svalbard = hd(apogee_ground_station:known_stations()),
    {_FirstId, FirstState} = hd(States),
    SatPosEcef = apogee_coords:teme_to_ecef(FirstState#orbit_state.pos, EpochJD),
    Angles = apogee_ground_station:ground_look_angles(Svalbard, SatPosEcef),
    ?assert(maps:is_key(azimuth_deg, Angles)),
    ?assert(maps:is_key(elevation_deg, Angles)),
    ?assert(maps:is_key(range_km, Angles)),

    %% ASCII world map rendering
    Map0 = apogee_ascii_map:new_map(72, 24),
    Map1 = apogee_ascii_map:draw_satellite(Map0, 50.0, -100.0, <<"SAT-P01">>),
    Map2 = apogee_ascii_map:draw_ground_station(Map1, Svalbard#ground_station.location#geodetic.lat,
                                               Svalbard#ground_station.location#geodetic.lon,
                                               Svalbard#ground_station.id),
    Rendered = apogee_ascii_map:render_string(Map2),
    ?assert(is_list(Rendered)),
    ?assert(lists:member($@, Rendered)),
    ?assert(lists:member($^, Rendered)).
