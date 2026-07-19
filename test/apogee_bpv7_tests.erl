%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_bpv7 Bundle Protocol Version 7
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bpv7_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

bundle_roundtrip_test() ->
    Payload = <<"SCIENTIFIC_SURFACE_RADAR_DATA_CHUNK_77">>,
    Bundle = apogee_bpv7:new_bundle("ipn:100.1", "ipn:200.2", 86400000, Payload, 1700000000000, 1),
    Encoded = apogee_bpv7:encode(Bundle),
    ?assert(is_binary(Encoded)),
    {ok, Decoded, <<>>} = apogee_bpv7:decode(Encoded),
    ?assertEqual(<<"ipn:100.1">>, Decoded#bpv7_bundle.source),
    ?assertEqual(<<"ipn:200.2">>, Decoded#bpv7_bundle.destination),
    ?assertEqual(1700000000000, Decoded#bpv7_bundle.creation_time),
    ?assertEqual(86400000, Decoded#bpv7_bundle.lifetime_ms),
    ?assertEqual(Payload, Decoded#bpv7_bundle.payload).

bundle_extensions_test() ->
    Bundle0 = apogee_bpv7:new_bundle("dtn://sat1/cam", "dtn://ground/recv", 3600000, <<"IMAGE">>),
    Bundle1 = apogee_bpv7:add_previous_node(Bundle0, "dtn://router/hop"),
    {ok, Bundle2} = apogee_bpv7:increment_hop_count(Bundle1),
    Bundle3 = Bundle2#bpv7_bundle{bundle_age_ms = 45000},
    Encoded = apogee_bpv7:encode(Bundle3),
    {ok, Decoded, <<>>} = apogee_bpv7:decode(Encoded),
    ?assertEqual(<<"dtn://router/hop">>, Decoded#bpv7_bundle.previous_node),
    ?assertEqual({32, 1}, Decoded#bpv7_bundle.hop_count),
    ?assertEqual(45000, Decoded#bpv7_bundle.bundle_age_ms).

lifetime_expiry_test() ->
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.2", 5000, <<"EXP">>, 1000, 1),
    ?assertNot(apogee_bpv7:is_expired(Bundle, 5000)),
    ?assert(apogee_bpv7:is_expired(Bundle, 7000)),
    ?assertEqual(1000, apogee_bpv7:remaining_lifetime_ms(Bundle, 5000)).

report_flags_test() ->
    Bundle0 = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.2", 10000, <<"DATA">>),
    Bundle1 = apogee_bpv7:set_report_flags(Bundle0, [reception, delivery]),
    ?assert(apogee_bpv7:has_flag(Bundle1, ?BPV7_FLAG_REQ_RECEPTION_RPT)),
    ?assert(apogee_bpv7:has_flag(Bundle1, ?BPV7_FLAG_REQ_DELIVERY_RPT)),
    ?assertNot(apogee_bpv7:has_flag(Bundle1, ?BPV7_FLAG_REQ_FORWARD_RPT)).
