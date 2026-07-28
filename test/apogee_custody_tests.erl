%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc EUnit tests for apogee_custody
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_custody_tests).
-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

custody_lifecycle_test() ->
    {ok, Custody} = apogee_custody:start_link(#{node_id => "ipn:1.1", max_custody_bundles => 10}),
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.1", 3600000, <<"CUSTODY_DATA">>),

    %% Take custody: accepted
    {accepted, SignalBin} = apogee_custody:take_custody(Custody, Bundle, 1000),
    ?assert(is_binary(SignalBin)),

    %% Register transfer to next hop
    ok = apogee_custody:register_transfer(Custody, Bundle, "ipn:3.1", 5000),
    ?assertEqual(1, apogee_custody:get_custody_count(Custody)),

    %% Downstream node sends acceptance signal: release bundle
    {ok, released} = apogee_custody:process_signal(Custody, SignalBin),
    ?assertEqual(0, apogee_custody:get_custody_count(Custody)),

    ok = apogee_custody:stop(Custody).

custody_refusal_test() ->
    {ok, Custody} = apogee_custody:start_link(#{node_id => "ipn:1.1", max_custody_bundles => 10}),
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.1", 3600000, <<"DATA">>),

    %% When storage exceeds threshold (e.g. 150 MB > 100 MB limit)
    {refused, storage_limit_exceeded, _Signal} = apogee_custody:take_custody(Custody, Bundle, 150000000),

    ok = apogee_custody:stop(Custody).

custody_timeout_test() ->
    {ok, Custody} = apogee_custody:start_link(#{node_id => "ipn:1.1"}),
    Bundle = apogee_bpv7:new_bundle("ipn:1.1", "ipn:2.1", 3600000, <<"DATA">>),
    ok = apogee_custody:register_transfer(Custody, Bundle, "ipn:3.1", 1000),

    NowMs = apogee_time:now_unix_ms(),
    %% Check before timeout
    {ok, []} = apogee_custody:check_timeouts(Custody, NowMs),
    %% Check after timeout (simulate +2000 ms)
    {ok, [TimedOutBundle]} = apogee_custody:check_timeouts(Custody, NowMs + 2000),
    ?assertEqual(Bundle#bpv7_bundle.source, TimedOutBundle#bpv7_bundle.source),

    ok = apogee_custody:stop(Custody).
