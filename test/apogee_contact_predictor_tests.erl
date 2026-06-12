%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_contact_predictor
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_contact_predictor_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

ground_pass_prediction_test() ->
    L1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927",
    L2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    {ok, Tle} = apogee_tle:parse_lines("ISS (ZARYA)", L1, L2),
    
    %% Ground station at Houston (29.7604 N, 95.3698 W)
    Houston = #geodetic{lat = 29.7604, lon = -95.3698, alt = 0.03},
    StartJD = apogee_tle:epoch_to_jd(Tle#tle.epoch_year, Tle#tle.epoch_day),
    EndJD = StartJD + 1.0, % 24 hour window
    
    Passes = apogee_contact_predictor:predict_ground_passes(Tle, Houston, StartJD, EndJD, 10.0, 60.0),
    ?assert(is_list(Passes)),
    lists:foreach(fun(Pass) ->
        Dur = Pass#ground_pass.duration_s,
        ?assert(Dur > 60.0 andalso Dur < 900.0), % LEO passes typically 3-12 minutes
        ?assert(Pass#ground_pass.max_elevation_deg >= 10.0),
        ?assert(Pass#ground_pass.los_jd > Pass#ground_pass.aos_jd)
    end, Passes).
