%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_time
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_time_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

j2000_epoch_test() ->
    JD = apogee_time:datetime_to_jd(2000, 1, 1, 12, 0, 0.0),
    ?assert(abs(JD - 2451545.0) < 1.0e-6),
    {{Y, M, D}, {H, Min, S}} = apogee_time:jd_to_datetime(JD),
    ?assertEqual(2000, Y),
    ?assertEqual(1, M),
    ?assertEqual(1, D),
    ?assertEqual(12, H),
    ?assertEqual(0, Min),
    ?assert(abs(S - 0.0) < 1.0e-3).

unix_epoch_roundtrip_test() ->
    UnixSec = 1700000000,
    JD = apogee_time:unix_to_jd(UnixSec),
    UnixRec = apogee_time:jd_to_unix(JD),
    ?assert(abs(UnixSec - UnixRec) < 1.0e-4).

gmst_range_test() ->
    JD = 2451545.0,
    GMST = apogee_time:gmst(JD),
    ?assert(GMST >= 0.0 andalso GMST < ?TWO_PI).
