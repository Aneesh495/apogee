%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for log-structured bundle vault.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bundle_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

bundle_store_crud_and_compaction_test() ->
    Dir = "/tmp/apogee_vault_test_" ++ integer_to_list(erlang:system_time(microsecond)),
    {ok, Pid} = apogee_bundle_store:start_link(Dir),

    B1 = #bpv7_bundle{
        source = <<"ipn:1.1">>,
        destination = <<"ipn:2.1">>,
        creation_time = 1000,
        sequence_number = 1,
        lifetime_ms = 5000,
        payload = <<"science data block 1">>
    },
    B2 = #bpv7_bundle{
        source = <<"ipn:1.1">>,
        destination = <<"ipn:3.1">>,
        creation_time = 1000,
        sequence_number = 2,
        lifetime_ms = 1000,
        payload = <<"science data block 2">>
    },

    {ok, Key1} = apogee_bundle_store:put_bundle(Pid, B1),
    {ok, Key2} = apogee_bundle_store:put_bundle(Pid, B2),

    % Read back
    {ok, Read1} = apogee_bundle_store:get_bundle(Pid, Key1),
    ?assertEqual(B1#bpv7_bundle.payload, Read1#bpv7_bundle.payload),

    % Query by destination
    For2 = apogee_bundle_store:find_by_destination(Pid, <<"2">>),
    ?assertEqual(1, length(For2)),
    ?assertEqual(B1#bpv7_bundle.payload, (hd(For2))#bpv7_bundle.payload),

    For3 = apogee_bundle_store:find_by_destination(Pid, <<"3">>),
    ?assertEqual(1, length(For3)),

    % Evict expired at t=2500 (B2 expires at 1000+1000=2000, B1 expires at 1000+5000=6000)
    {ok, 1} = apogee_bundle_store:evict_expired(Pid, 2500),
    ?assertEqual({error, not_found}, apogee_bundle_store:get_bundle(Pid, Key2)),
    {ok, _} = apogee_bundle_store:get_bundle(Pid, Key1),

    % Compaction should reclaim bytes of B2
    TotalBefore = apogee_bundle_store:total_stored_bytes(Pid),
    {ok, Reclaimed} = apogee_bundle_store:compact(Pid),
    ?assert(Reclaimed > 0),
    TotalAfter = apogee_bundle_store:total_stored_bytes(Pid),
    ?assertEqual(TotalBefore - Reclaimed, TotalAfter),

    % Close and recover
    ok = apogee_bundle_store:close(Pid),
    {ok, Pid2} = apogee_bundle_store:start_link(Dir),
    {ok, Recovered1} = apogee_bundle_store:get_bundle(Pid2, Key1),
    ?assertEqual(B1#bpv7_bundle.payload, Recovered1#bpv7_bundle.payload),
    ?assertEqual({error, not_found}, apogee_bundle_store:get_bundle(Pid2, Key2)),

    ok = apogee_bundle_store:close(Pid2),
    os:cmd("rm -rf " ++ Dir).
