%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for apogee_cgr_router gen_server.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cgr_router_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

router_lifecycle_and_routing_test() ->
    {ok, Pid} = apogee_cgr_router:start_link(),
    
    Now = apogee_time:now_seconds(),
    C1 = #contact{
        id = <<"c1">>,
        from_node = <<"1">>,
        to_node = <<"2">>,
        start_time = Now,
        end_time = Now + 1000.0,
        data_rate_bps = 10000000,
        range_delay_s = 0.05,
        total_capacity_bytes = 10000000
    },
    C2 = #contact{
        id = <<"c2">>,
        from_node = <<"1">>,
        to_node = <<"3">>,
        start_time = Now + 10.0,
        end_time = Now + 1000.0,
        data_rate_bps = 10000000,
        range_delay_s = 0.05,
        total_capacity_bytes = 10000000
    },
    ?assertEqual(ok, apogee_cgr_router:add_contact(Pid, C1)),
    ?assertEqual(ok, apogee_cgr_router:add_contact(Pid, C2)),

    Bundle = #bpv7_bundle{
        source = <<"ipn:1.1">>,
        destination = <<"ipn:2.1">>,
        payload = <<"orbital telemetry payload">>
    },
    {ok, NextHop, Route} = apogee_cgr_router:route_bundle(Pid, Bundle),
    ?assertEqual(<<"2">>, NextHop),
    ?assertEqual(1, length(Route#cgr_route.hops)),

    % Report failure on link c1, bundle should deflect to node 3 if bundle goes to 3
    ?assertEqual(ok, apogee_cgr_router:report_link_failure(Pid, <<"c1">>)),
    Bundle2 = #bpv7_bundle{
        source = <<"ipn:1.1">>,
        destination = <<"ipn:3.1">>,
        payload = <<"telemetry for node 3">>
    },
    {ok, NextHop2, _Route2} = apogee_cgr_router:route_bundle(Pid, Bundle2),
    ?assertEqual(<<"3">>, NextHop2),

    apogee_cgr_router:stop(Pid).
