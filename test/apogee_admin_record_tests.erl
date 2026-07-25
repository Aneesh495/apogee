%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_admin_record
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_admin_record_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

status_report_roundtrip_test() ->
    Subject = apogee_bpv7:new_bundle("ipn:10.1", "ipn:20.2", 3600000, <<"DATA">>, 1700000000000, 42),
    Report = apogee_admin_record:create_status_report(Subject, delivered, ?BPV7_REASON_NO_INFO, 1700000050000),
    Encoded = apogee_admin_record:encode(Report),
    {ok, Decoded} = apogee_admin_record:decode(Encoded),
    ?assertEqual(<<"ipn:10.1">>, element(5, Decoded)), % subject_source
    ?assertEqual(1700000000000, element(6, Decoded)), % subject_creation_time
    ?assertEqual(42, element(7, Decoded)),             % subject_seq_num
    Flags = element(2, Decoded),
    ?assert(maps:get(delivered, Flags)),
    ?assertNot(maps:get(received, Flags)).

status_report_bundle_test() ->
    Subject = apogee_bpv7:new_bundle("ipn:10.1", "ipn:20.2", 3600000, <<"DATA">>, 1700000000000, 1),
    Report = apogee_admin_record:create_status_report(Subject, deleted, ?BPV7_REASON_LIFETIME_EXPIRED, 1700000060000),
    ReportBundle = apogee_admin_record:status_report_to_bundle(Report, "ipn:30.3"),
    ?assertEqual(<<"ipn:30.3">>, ReportBundle#bpv7_bundle.source),
    ?assertEqual(<<"ipn:10.1">>, ReportBundle#bpv7_bundle.destination),
    ?assert(apogee_bpv7:has_flag(ReportBundle, ?BPV7_FLAG_ADMIN_RECORD)).
