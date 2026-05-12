%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_precession
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_precession_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

j2000_precession_test() ->
    JD = 2451545.0,
    P = apogee_precession:precession_matrix(JD),
    ?assert(abs(P#matrix3.r11 - 1.0) < 1.0e-9),
    ?assert(abs(P#matrix3.r22 - 1.0) < 1.0e-9),
    ?assert(abs(P#matrix3.r33 - 1.0) < 1.0e-9).

obliquity_test() ->
    JD = 2451545.0,
    Eps0Rad = apogee_precession:mean_obliquity(JD),
    Eps0Deg = Eps0Rad * ?RAD_TO_DEG,
    ?assert(abs(Eps0Deg - 23.43929) < 0.001).

nutation_bound_test() ->
    JD = 2451545.0,
    {DPsi, DEps} = apogee_precession:nutation_angles(JD),
    ?assert(abs(DPsi) < 1.0e-3),
    ?assert(abs(DEps) < 1.0e-3).
