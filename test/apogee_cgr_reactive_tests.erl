%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for reactive CGR route deflection and link degradation.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cgr_reactive_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

reactive_deflection_and_restoration_test() ->
    {ok, Pid} = apogee_cgr_router:start_link(),
    Now = apogee_time:now_seconds(),

    % Direct link c1: sat-1 -> gs-1 (available now)
    % Alternate link c2: sat-1 -> sat-2 -> gs-1
    C1 = #contact{
        id = <<"c1">>,
        from_node = <<"sat-1">>,
        to_node = <<"gs-1">>,
        start_time = Now,
        end_time = Now + 1000.0,
        data_rate_bps = 5000000,
        range_delay_s = 0.05,
        confidence = 1.0,
        total_capacity_bytes = 10000000
    },
    C2 = #contact{
        id = <<"c2">>,
        from_node = <<"sat-1">>,
        to_node = <<"sat-2">>,
        start_time = Now,
        end_time = Now + 1000.0,
        data_rate_bps = 5000000,
        range_delay_s = 0.02,
        confidence = 1.0,
        total_capacity_bytes = 10000000
    },
    C3 = #contact{
        id = <<"c3">>,
        from_node = <<"sat-2">>,
        to_node = <<"gs-1">>,
        start_time = Now,
        end_time = Now + 1000.0,
        data_rate_bps = 5000000,
        range_delay_s = 0.03,
        confidence = 1.0,
        total_capacity_bytes = 10000000
    },
    ?assertEqual(ok, apogee_cgr_router:add_contact(Pid, C1)),
    ?assertEqual(ok, apogee_cgr_router:add_contact(Pid, C2)),
    ?assertEqual(ok, apogee_cgr_router:add_contact(Pid, C3)),

    Bundle = #bpv7_bundle{
        source = <<"dtn://sat-1/telemetry">>,
        destination = <<"dtn://gs-1/inbox">>,
        payload = <<"science data payload">>
    },

    % Initially routes direct via c1 to gs-1
    {ok, Next1, Route1} = apogee_cgr_router:route_bundle(Pid, Bundle),
    ?assertEqual(<<"gs-1">>, Next1),
    ?assertEqual(1, length(Route1#cgr_route.hops)),

    % Report failure on link c1: route should deflect to sat-2
    ?assertEqual(ok, apogee_cgr_router:report_link_failure(Pid, <<"c1">>)),
    {ok, Next2, Route2} = apogee_cgr_router:route_bundle(Pid, Bundle),
    ?assertEqual(<<"sat-2">>, Next2),
    ?assertEqual(2, length(Route2#cgr_route.hops)),

    % Degrade confidence of link c2
    ?assertEqual(ok, apogee_cgr_router:degrade_confidence(Pid, <<"c2">>, 0.5)),

    % Restore link c1
    ?assertEqual(ok, apogee_cgr_router:restore_contact(Pid, <<"c1">>)),
    {ok, Next3, Route3} = apogee_cgr_router:route_bundle(Pid, Bundle),
    ?assertEqual(<<"gs-1">>, Next3),
    ?assertEqual(1, length(Route3#cgr_route.hops)),

    apogee_cgr_router:stop(Pid).
