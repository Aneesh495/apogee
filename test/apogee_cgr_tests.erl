%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for Contact Graph Routing (CGR).
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_cgr_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

single_hop_routing_test() ->
    CP0 = apogee_contact_plan:new(),
    % sat-1 -> gs-1 from t=100 to t=200, 10 Mbps, delay 0.05s
    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"gs-1">>, 100.0, 200.0, 10000000, 0.05),
    
    % Route 100,000 bytes at t=50
    {ok, Route} = apogee_cgr:find_earliest_path(CP1, <<"sat-1">>, <<"gs-1">>, 100000, 50.0),
    ?assertEqual(<<"sat-1">>, Route#cgr_route.from_node),
    ?assertEqual(<<"gs-1">>, Route#cgr_route.to_node),
    ?assertEqual(1, length(Route#cgr_route.hops)),
    ?assertEqual(100.0, Route#cgr_route.tx_start_time),
    % Tx time: 100,000 * 8 / 10,000,000 = 0.08s
    % Arr time: 100.0 + 0.08 + 0.05 = 100.13s
    ?assert(abs(Route#cgr_route.arrival_time - 100.13) < 1.0e-4).

multi_hop_routing_test() ->
    CP0 = apogee_contact_plan:new(),
    % sat-1 -> sat-2: t=10 to t=50, 1 Mbps, delay 0.02s
    % sat-2 -> gs-1:  t=30 to t=80, 5 Mbps, delay 0.03s
    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"sat-2">>, 10.0, 50.0, 1000000, 0.02),
    CP2 = apogee_contact_plan:add_contact(CP1, <<"sat-2">>, <<"gs-1">>, 30.0, 80.0, 5000000, 0.03),

    % Route 12,500 bytes (0.1s tx at 1Mbps) at t=10
    {ok, Route} = apogee_cgr:find_earliest_path(CP2, <<"sat-1">>, <<"gs-1">>, 12500, 10.0),
    ?assertEqual(2, length(Route#cgr_route.hops)),
    % Hop 1: Tx = 10.0 -> Arr at sat-2 = 10.0 + 0.1 + 0.02 = 10.12s
    % Hop 2: Starts at max(10.12, 30.0) = 30.0s.
    % Tx = 12500*8 / 5000000 = 0.02s.
    % Arr at gs-1 = 30.0 + 0.02 + 0.03 = 30.05s.
    ?assert(abs(Route#cgr_route.arrival_time - 30.05) < 1.0e-4).

earliest_arrival_selection_test() ->
    CP0 = apogee_contact_plan:new(),
    % Fast path: available later (t=100) but fast
    % Slow path: available earlier (t=10) but delivers at t=25
    % Direct link 1: t=10..30, delay 1.0s, 100 kbps (12500 bytes -> tx 1.0s -> arr 12.0)
    % Direct link 2: t=5..20, delay 15.0s, 100 kbps (12500 bytes -> tx 1.0s -> arr 21.0)
    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"gs-1">>, 5.0, 20.0, 100000, 15.0),
    CP2 = apogee_contact_plan:add_contact(CP1, <<"sat-1">>, <<"gs-1">>, 10.0, 30.0, 100000, 1.0),

    {ok, Route} = apogee_cgr:find_earliest_path(CP2, <<"sat-1">>, <<"gs-1">>, 12500, 0.0),
    % Link 2 delivers at 10.0 + 1.0 + 1.0 = 12.0s, which is earlier than Link 1 at 5.0 + 1.0 + 15.0 = 21.0s
    ?assert(abs(Route#cgr_route.arrival_time - 12.0) < 1.0e-4).

multipath_and_deflection_test() ->
    CP0 = apogee_contact_plan:new(),
    % Two alternative paths: path A and path B
    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"sat-2">>, 10.0, 50.0, 1000000, 0.01),
    CP2 = apogee_contact_plan:add_contact(CP1, <<"sat-2">>, <<"gs-1">>, 20.0, 60.0, 1000000, 0.01),
    CP3 = apogee_contact_plan:add_contact(CP2, <<"sat-1">>, <<"sat-3">>, 12.0, 50.0, 1000000, 0.01),
    CP4 = apogee_contact_plan:add_contact(CP3, <<"sat-3">>, <<"gs-1">>, 25.0, 60.0, 1000000, 0.01),

    Paths = apogee_cgr:find_k_paths(CP4, <<"sat-1">>, <<"gs-1">>, 1000, 0.0, 2),
    ?assertEqual(2, length(Paths)),

    % Primary path uses sat-2
    [PrimaryRoute, SecondaryRoute] = Paths,
    ?assert(PrimaryRoute#cgr_route.arrival_time < SecondaryRoute#cgr_route.arrival_time),

    % Deflect away from primary contact
    [FirstHop | _] = PrimaryRoute#cgr_route.hops,
    {ok, Deflected} = apogee_cgr:deflect_route(CP4, [FirstHop#contact.id], <<"sat-1">>, <<"gs-1">>, 1000, 0.0),
    [DeflectedHop | _] = Deflected#cgr_route.hops,
    ?assertEqual(<<"sat-3">>, DeflectedHop#contact.to_node).

route_and_reserve_test() ->
    CP0 = apogee_contact_plan:new(),
    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"sat-2">>, 10.0, 20.0, 8000, 0.01),
    CP2 = apogee_contact_plan:add_contact(CP1, <<"sat-2">>, <<"gs-1">>, 15.0, 25.0, 8000, 0.01),

    % 5000 bytes reserved along path
    {ok, Route, UpdatedCP} = apogee_cgr:route_and_reserve(CP2, <<"sat-1">>, <<"gs-1">>, 5000, 10.0),
    ?assertEqual(2, length(Route#cgr_route.hops)),

    % Contacts in UpdatedCP should reflect 5000 bytes reserved
    All = apogee_contact_plan:get_contacts(UpdatedCP),
    lists:foreach(
        fun(C) ->
            ?assertEqual(5000, C#contact.reserved_bytes)
        end,
        All
    ),

    % Another 6000 bytes should fail because total capacity is 10s * 1000 bytes/s = 10,000 bytes
    ?assertEqual({error, no_route}, apogee_cgr:route_and_reserve(UpdatedCP, <<"sat-1">>, <<"gs-1">>, 6000, 10.0)).
