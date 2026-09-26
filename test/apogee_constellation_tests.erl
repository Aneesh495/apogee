%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_constellation (Walker-Delta & ISL Mesh).
%%%-------------------------------------------------------------------
-module(apogee_constellation_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

walker_delta_generation_test() ->
    %% 12 satellites, 3 planes, phasing 1, 550 km altitude, 53 deg inclination
    Cfg = #walker_config{
        total_sats = 12,
        planes = 3,
        phasing = 1,
        altitude_km = 550.0,
        inclination_deg = 53.0
    },
    Sats = apogee_constellation:generate_walker_delta(Cfg),
    ?assertEqual(12, length(Sats)),

    %% Verify RAAN distribution across planes
    Plane1Sat1 = hd(Sats),
    ?assertEqual(<<"SAT-P01-S01">>, Plane1Sat1#tle.name),
    ?assertEqual(0.0, Plane1Sat1#tle.raan),
    ?assert(abs(Plane1Sat1#tle.inclination * ?RAD_TO_DEG - 53.0) < 1.0e-4),

    Plane2Sat1 = lists:nth(5, Sats), % plane 2, sat 1 (index 5)
    ?assertEqual(<<"SAT-P02-S01">>, Plane2Sat1#tle.name),
    ExpectedRaan2 = 2.0 * ?PI / 3.0,
    ?assert(abs(Plane2Sat1#tle.raan - ExpectedRaan2) < 1.0e-4).

propagate_constellation_test() ->
    Sats = apogee_constellation:generate_walker_delta(6, 2, 1, 600.0, 70.0),
    EpochJD = apogee_tle:epoch_to_jd(2026, 1.0),
    States = apogee_constellation:propagate_constellation(Sats, EpochJD),
    ?assertEqual(6, length(States)),
    {FirstId, FirstState} = hd(States),
    ?assertEqual(<<"SAT-P01-S01">>, FirstId),
    PosNorm = apogee_vec3:norm(FirstState#orbit_state.pos),
    ?assert(PosNorm > 6900.0 andalso PosNorm < 7050.0).

crosslinks_and_network_metrics_test() ->
    Sats = apogee_constellation:generate_walker_delta(8, 2, 1, 550.0, 53.0),
    EpochJD = apogee_tle:epoch_to_jd(2026, 1.0),
    States = apogee_constellation:propagate_constellation(Sats, EpochJD),
    
    %% Compute ISLs with generous range (e.g. 5000 km)
    Links = apogee_constellation:compute_crosslinks(States, 5000.0),
    ?assert(length(Links) > 0),

    NodeIds = [Id || {Id, _} <- States],
    Metrics = apogee_constellation:network_metrics(NodeIds, Links),
    ?assert(maps:get(avg_degree, Metrics) > 0.0),
    ?assert(maps:is_key(connected, Metrics)),
    ?assert(maps:is_key(diameter, Metrics)).

contact_plan_compilation_test() ->
    Sats = apogee_constellation:generate_walker_delta(12, 2, 1, 550.0, 53.0),
    StartJD = apogee_tle:epoch_to_jd(2026, 1.0),
    EndJD = StartJD + (60.0 / 86400.0), % 60 seconds
    CP = apogee_constellation:generate_contact_plan(Sats, StartJD, EndJD, 30.0, 8000.0),
    AllContacts = apogee_contact_plan:get_contacts(CP),
    ?assert(length(AllContacts) >= 2).
