%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_eid
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_eid_tests).
-include_lib("eunit/include/eunit.hrl").

ipn_scheme_test() ->
    Str = <<"ipn:42.1">>,
    {ok, Eid} = apogee_eid:parse(Str),
    ?assertEqual(Str, apogee_eid:format(Eid)),
    CborData = apogee_eid:encode_cbor(Eid),
    ?assertEqual([2, [42, 1]], CborData),
    {ok, Rec} = apogee_eid:decode_cbor(CborData),
    ?assertEqual(Eid, Rec).

dtn_scheme_test() ->
    Str = <<"dtn://iss/telemetry">>,
    {ok, Eid} = apogee_eid:parse(Str),
    ?assertEqual(Str, apogee_eid:format(Eid)),
    CborData = apogee_eid:encode_cbor(Eid),
    {ok, Rec} = apogee_eid:decode_cbor(CborData),
    ?assertEqual(Eid, Rec).

null_eid_test() ->
    Null = apogee_eid:null_eid(),
    ?assert(apogee_eid:is_null(Null)),
    ?assertEqual(<<"dtn:none">>, apogee_eid:format(Null)),
    {ok, Parsed} = apogee_eid:parse(<<"dtn:none">>),
    ?assertEqual(Null, Parsed).

eid_matching_test() ->
    E1 = apogee_eid:ipn(100, 1),
    E2 = apogee_eid:ipn(100, 1),
    E3 = apogee_eid:ipn(100, 2),
    E4 = apogee_eid:ipn(200, 1),
    ?assert(apogee_eid:matches(E1, E2)),
    ?assertNot(apogee_eid:matches(E1, E3)),
    ?assertNot(apogee_eid:matches(E1, E4)).
