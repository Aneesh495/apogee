%%%-------------------------------------------------------------------
%%% @author Aneesh Krishna
%%% @doc Unit tests for Contact Plan manager and temporal index.
%%% @end
%%%-------------------------------------------------------------------
-module(apogee_contact_plan_tests).

-include_lib("eunit/include/eunit.hrl").
-include("apogee.hrl").

contact_plan_crud_test() ->
    CP0 = apogee_contact_plan:new(),
    ?assertEqual([], apogee_contact_plan:get_contacts(CP0)),

    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"gs-1">>, 100.0, 200.0, 10000000, 0.05),
    Contacts = apogee_contact_plan:get_contacts(CP1),
    ?assertEqual(1, length(Contacts)),
    [C1] = Contacts,
    ?assertEqual(<<"sat-1">>, C1#contact.from_node),
    ?assertEqual(<<"gs-1">>, C1#contact.to_node),
    ?assertEqual(100.0, C1#contact.start_time),
    ?assertEqual(200.0, C1#contact.end_time),
    % 100s * 10 Mbps / 8 = 125,000,000 bytes
    ?assertEqual(125000000, C1#contact.total_capacity_bytes),

    % Query between
    Between = apogee_contact_plan:get_contacts_between(CP1, <<"sat-1">>, <<"gs-1">>),
    ?assertEqual(1, length(Between)),
    ?assertEqual([], apogee_contact_plan:get_contacts_between(CP1, <<"sat-1">>, <<"gs-2">>)),

    % Query outbound contacts
    Out1 = apogee_contact_plan:get_outbound_contacts(CP1, <<"sat-1">>, 50.0),
    ?assertEqual(1, length(Out1)),
    Out2 = apogee_contact_plan:get_outbound_contacts(CP1, <<"sat-1">>, 250.0),
    ?assertEqual([], Out2),

    % Remove contact
    CP2 = apogee_contact_plan:remove_contact(CP1, C1#contact.id),
    ?assertEqual([], apogee_contact_plan:get_contacts(CP2)).

capacity_reservation_test() ->
    CP0 = apogee_contact_plan:new(),
    CP1 = apogee_contact_plan:add_contact(CP0, <<"sat-1">>, <<"sat-2">>, 10.0, 20.0, 8000, 0.01),
    [C] = apogee_contact_plan:get_contacts(CP1),
    % 10s * 8000 bps / 8 = 10,000 bytes
    ?assertEqual(10000, C#contact.total_capacity_bytes),

    % Reserve 6,000 bytes -> ok
    {ok, CP2} = apogee_contact_plan:reserve_capacity(CP1, C#contact.id, 6000),
    [C2] = apogee_contact_plan:get_contacts(CP2),
    ?assertEqual(6000, C2#contact.reserved_bytes),

    % Reserve another 5,000 bytes -> fails (overbooked)
    ?assertEqual({error, overbooked}, apogee_contact_plan:reserve_capacity(CP2, C#contact.id, 5000)),

    % Reserve remaining 4,000 bytes -> ok
    {ok, CP3} = apogee_contact_plan:reserve_capacity(CP2, C#contact.id, 4000),
    [C3] = apogee_contact_plan:get_contacts(CP3),
    ?assertEqual(10000, C3#contact.reserved_bytes),

    % Release 5,000 bytes
    CP4 = apogee_contact_plan:release_capacity(CP3, C#contact.id, 5000),
    [C4] = apogee_contact_plan:get_contacts(CP4),
    ?assertEqual(5000, C4#contact.reserved_bytes).
