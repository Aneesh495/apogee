%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_tle with real NASA orbital elements
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_tle_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

iss_tle_parse_test() ->
    L1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927",
    L2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    ?assert(apogee_tle:verify_checksum(L1)),
    ?assert(apogee_tle:verify_checksum(L2)),
    {ok, Tle} = apogee_tle:parse_lines("ISS (ZARYA)", L1, L2),
    ?assertEqual(25544, Tle#tle.sat_num),
    ?assertEqual($U, Tle#tle.classification),
    ?assertEqual(2008, Tle#tle.epoch_year),
    ?assert(abs(Tle#tle.inclination * ?RAD_TO_DEG - 51.6416) < 1.0e-4),
    ?assert(abs(Tle#tle.raan * ?RAD_TO_DEG - 247.4627) < 1.0e-4),
    ?assert(abs(Tle#tle.eccentricity - 0.0006703) < 1.0e-7),
    ?assert(abs(Tle#tle.bstar - (-0.11606e-4)) < 1.0e-9),
    SemiMajor = apogee_tle:semi_major_axis(Tle),
    ?assert(SemiMajor > 6700.0 andalso SemiMajor < 6850.0),
    PeriodS = apogee_tle:orbital_period_s(Tle),
    ?assert(PeriodS > 5400.0 andalso PeriodS < 5600.0),
    PerigeeAlt = apogee_tle:perigee_altitude_km(Tle),
    ApogeeAlt = apogee_tle:apogee_altitude_km(Tle),
    ?assert(PerigeeAlt > 330.0 andalso PerigeeAlt < 430.0),
    ?assert(ApogeeAlt > 340.0 andalso ApogeeAlt < 440.0).

invalid_checksum_test() ->
    %% Alter last character to corrupt checksum
    BadL1 = "1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2929",
    L2 = "2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537",
    ?assertEqual({error, line1_checksum_mismatch}, apogee_tle:parse_lines(BadL1, L2)).

epoch_conversion_test() ->
    JD = apogee_tle:epoch_to_jd(2008, 264.51782528),
    {Year, DayOfYear} = apogee_tle:jd_to_epoch(JD),
    ?assertEqual(2008, Year),
    ?assert(abs(DayOfYear - 264.51782528) < 1.0e-5).
