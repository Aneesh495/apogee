%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for multi-priority bundle queue.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_bundle_queue_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

priority_ordering_test() ->
    % Queue with capacity for multiple bundles
    Q0 = apogee_bundle_queue:new(5000),
    ?assertEqual(0, apogee_bundle_queue:len(Q0)),
    ?assertEqual(empty, apogee_bundle_queue:pop(Q0)),

    B_bulk = #bpv7_bundle{payload = <<"bulk_data">>},
    B_std = #bpv7_bundle{payload = <<"standard_telemetry">>},
    B_exp = #bpv7_bundle{payload = <<"urgent_collision_avoidance">>},

    % Push in reverse priority order: bulk, standard, expedited
    {ok, Q1} = apogee_bundle_queue:push(Q0, bulk, B_bulk),
    {ok, Q2} = apogee_bundle_queue:push(Q1, standard, B_std),
    {ok, Q3} = apogee_bundle_queue:push(Q2, expedited, B_exp),
    ?assertEqual(3, apogee_bundle_queue:len(Q3)),

    % Peek should see expedited
    {ok, Peeked} = apogee_bundle_queue:peek(Q3),
    ?assertEqual(B_exp#bpv7_bundle.payload, Peeked#bpv7_bundle.payload),

    % Pop order should be: expedited, then standard, then bulk
    {ok, P1, Q4} = apogee_bundle_queue:pop(Q3),
    ?assertEqual(B_exp#bpv7_bundle.payload, P1#bpv7_bundle.payload),

    {ok, P2, Q5} = apogee_bundle_queue:pop(Q4),
    ?assertEqual(B_std#bpv7_bundle.payload, P2#bpv7_bundle.payload),

    {ok, P3, Q6} = apogee_bundle_queue:pop(Q5),
    ?assertEqual(B_bulk#bpv7_bundle.payload, P3#bpv7_bundle.payload),

    ?assertEqual(empty, apogee_bundle_queue:pop(Q6)).

quota_and_shedding_test() ->
    % Small quota: 300 bytes (each bundle is ~138 bytes)
    Q0 = apogee_bundle_queue:new(300),

    B1 = #bpv7_bundle{payload = <<"bulk1">>},
    B2 = #bpv7_bundle{payload = <<"bulk2">>},
    B3_exp = #bpv7_bundle{payload = <<"exp3">>},

    {ok, Q1} = apogee_bundle_queue:push(Q0, bulk, B1),
    {ok, Q2} = apogee_bundle_queue:push(Q1, bulk, B2),
    % Queue now nearly full (~270 bytes)

    % Standard push should fail due to quota
    ?assertEqual({error, quota_exceeded}, apogee_bundle_queue:push(Q2, standard, #bpv7_bundle{payload = <<"std_overflow">>})),

    % Expedited push should shed bulk to make room!
    {ok, Q3} = apogee_bundle_queue:push(Q2, expedited, B3_exp),
    {ok, PoppedExp, Q4} = apogee_bundle_queue:pop(Q3),
    ?assertEqual(B3_exp#bpv7_bundle.payload, PoppedExp#bpv7_bundle.payload),
    ?assertEqual(1, apogee_bundle_queue:len(Q4)).

ttl_eviction_test() ->
    Q0 = apogee_bundle_queue:new(10000),
    % Bundle expiring at t = 1000 + 500 = 1500
    B_expiring = #bpv7_bundle{creation_time = 1000, lifetime_ms = 500, payload = <<"short_lived">>},
    % Bundle expiring at t = 1000 + 5000 = 6000
    B_persisting = #bpv7_bundle{creation_time = 1000, lifetime_ms = 5000, payload = <<"long_lived">>},

    {ok, Q1} = apogee_bundle_queue:push(Q0, standard, B_expiring),
    {ok, Q2} = apogee_bundle_queue:push(Q1, standard, B_persisting),
    ?assertEqual(2, apogee_bundle_queue:len(Q2)),

    % Evict at t = 2000
    {Evicted, Q3} = apogee_bundle_queue:evict_expired(Q2, 2000),
    ?assertEqual(1, length(Evicted)),
    ?assertEqual(<<"short_lived">>, (hd(Evicted))#bpv7_bundle.payload),
    ?assertEqual(1, apogee_bundle_queue:len(Q3)),

    {ok, Popped, _} = apogee_bundle_queue:pop(Q3),
    ?assertEqual(<<"long_lived">>, Popped#bpv7_bundle.payload).
